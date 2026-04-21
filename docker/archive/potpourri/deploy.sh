#!/usr/bin/env bash
# deploy.sh — Synapse CTI full deployment orchestrator
#
# Run this from your LOCAL machine. It SSHes into the Docker host and:
#   1. Applies kernel tuning (sysctl) and creates storage directories
#   2. Copies docker-compose.yml to the host
#   3. Starts AHA, waits for it to become healthy
#   4. Generates one-time provisioning URLs for Axon, JSONStor, Cortex
#   5. Starts Axon + JSONStor, then Cortex (in correct dependency order)
#   6. Creates the 'admin' user in Cortex with full admin rights
#   7. Generates an AHA enrollment URL for the admin user
#   8. Adds *.example.com DNS entries to /etc/hosts on THIS machine
#   9. Prints enrollment and Storm connection instructions
#
# Usage:
#   ./deploy.sh --host <HOST_IP_OR_FQDN> --ssh-user <USER> \
#               [--ssh-key <PATH_TO_KEY>] [--ssh-password <PASSWORD>] \
#               [--version <SYNAPSE_VERSION>] [--aha-network <NETWORK>]
#
# Examples:
#   ./deploy.sh --host 203.0.113.10 --ssh-user ubuntu --ssh-key ~/.ssh/id_rsa
#   ./deploy.sh --host 203.0.113.10 --ssh-user admin  --ssh-password s3cr3t
#
# Requirements (local machine):
#   - ssh, scp  (always present)
#   - sshpass   (only if using --ssh-password; brew install sshpass / apt install sshpass)
#
# Requirements (Docker host):
#   - Linux (Ubuntu 22.04+ recommended) — network_mode: host does NOT work on Mac/Windows
#   - Docker Engine 24+ installed
#   - Internet access to pull Docker images from Docker Hub

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SSH_HOST=""
SSH_USER="ubuntu"
SSH_KEY=""
SSH_PASS=""
SYNAPSE_VERSION="v2.239.0"
AHA_NETWORK="synapse"
DOMAIN="example.com"
REMOTE_DIR="/opt/synapse"
COMPOSE_FILE="$(dirname "$0")/docker-compose.yml"

AXON_DMON_PORT=27493
JSONSTOR_DMON_PORT=27494
CORTEX_DMON_PORT=27495
CORTEX_HTTPS_PORT=4443

# ─── Argument parsing ────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)          SSH_HOST="$2";        shift 2 ;;
    --ssh-user)      SSH_USER="$2";        shift 2 ;;
    --ssh-key)       SSH_KEY="$2";         shift 2 ;;
    --ssh-password)  SSH_PASS="$2";        shift 2 ;;
    --version)       SYNAPSE_VERSION="$2"; shift 2 ;;
    --aha-network)   AHA_NETWORK="$2";     shift 2 ;;
    --domain)        DOMAIN="$2";          shift 2 ;;
    --help|-h)       usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$SSH_HOST" ]] && { echo "ERROR: --host is required"; usage; }
[[ -z "$SSH_KEY" && -z "$SSH_PASS" ]] && { echo "ERROR: one of --ssh-key or --ssh-password is required"; usage; }
[[ ! -f "$COMPOSE_FILE" ]] && { echo "ERROR: docker-compose.yml not found at $COMPOSE_FILE"; exit 1; }

# ─── SSH/SCP helpers ─────────────────────────────────────────────────────────
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=no)

_ssh() {
  if [[ -n "$SSH_KEY" ]]; then
    ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "${SSH_USER}@${SSH_HOST}" "$@"
  else
    sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
  fi
}

_scp() {
  if [[ -n "$SSH_KEY" ]]; then
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" "$@"
  else
    sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" "$@"
  fi
}

log()  { echo -e "\033[1;34m[deploy]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[ warn ]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error ]\033[0m $*" >&2; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
if [[ -n "$SSH_PASS" ]] && ! command -v sshpass &>/dev/null; then
  die "sshpass not found. Install it: brew install sshpass (Mac) or apt install sshpass (Linux)"
fi

log "Testing SSH connection to ${SSH_USER}@${SSH_HOST} ..."
_ssh "echo 'SSH OK'" || die "SSH connection failed"
ok "SSH connection verified"

# ─── Step 1: Host setup ──────────────────────────────────────────────────────
log "Applying kernel tuning and creating directory structure on host ..."

_ssh bash -s << 'HOSTSETUP'
set -euo pipefail

# Kernel tuning for LMDB performance
cat >> /etc/sysctl.conf << 'SYSCTL'
# Synapse / LMDB tuning
vm.swappiness=10
vm.dirty_expire_centisecs=20
vm.dirty_writeback_centisecs=20
vm.dirty_background_ratio=2
vm.dirty_ratio=4
SYSCTL
sysctl -p >/dev/null 2>&1 || true

# Storage directories — must be pre-owned by UID 999 (synuser)
for svc in 00.aha 00.axon 00.jsonstor 00.cortex; do
  mkdir -p /srv/syn/${svc}/storage
  chown -R 999:999 /srv/syn/${svc}/storage
done

# Deployment directory
mkdir -p /opt/synapse
chmod 750 /opt/synapse

# Verify Docker is available
docker version >/dev/null 2>&1 || { echo "Docker not found — install Docker Engine first"; exit 1; }
echo "Host setup complete"
HOSTSETUP
ok "Host kernel tuning and directory setup done"

# ─── Step 2: Copy files ──────────────────────────────────────────────────────
log "Copying docker-compose.yml to host ..."
_scp "$COMPOSE_FILE" "${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/docker-compose.yml"
ok "Files copied"

# ─── Step 3: Detect public IP of host ───────────────────────────────────────
log "Detecting host public IP ..."
HOST_IP="$(_ssh "curl -fsSL ifconfig.me 2>/dev/null || curl -fsSL api.ipify.org 2>/dev/null || hostname -I | awk '{print \$1}'")"
HOST_IP="${HOST_IP//[[:space:]]/}"
log "Host IP: ${HOST_IP}"

AHA_DNS="aha.${DOMAIN}"

# ─── Step 4: Write initial .env (without provisioning URLs yet) ──────────────
log "Writing .env on host ..."
_ssh bash -s << EOF
cat > ${REMOTE_DIR}/.env << 'ENVEOF'
SYNAPSE_VERSION=${SYNAPSE_VERSION}
AHA_NETWORK=${AHA_NETWORK}
AHA_DNS_NAME=${AHA_DNS}
HOST_IP=${HOST_IP}
SYN_AXON_AHA_PROVISION=
SYN_JSONSTOR_AHA_PROVISION=
SYN_CORTEX_AHA_PROVISION=
ENVEOF
EOF

# ─── Step 5: Ensure AHA_DNS_NAME resolves on the Docker host ────────────────
log "Adding /etc/hosts entry on Docker host for ${AHA_DNS} -> 127.0.0.1 ..."
_ssh "grep -qF '${AHA_DNS}' /etc/hosts || echo '127.0.0.1  ${AHA_DNS}' >> /etc/hosts"
ok "Host DNS entry set"

# ─── Step 6: Start AHA only (Phase 1) ───────────────────────────────────────
log "Starting AHA service (Phase 1: Certificate Authority + Service Discovery) ..."
_ssh "cd ${REMOTE_DIR} && docker compose up -d aha-init aha"

log "Waiting for AHA to become healthy (up to 3 minutes) ..."
AHA_HEALTHY=false
for i in $(seq 1 36); do
  STATUS="$(_ssh "docker inspect --format='{{.State.Health.Status}}' \$(docker compose -f ${REMOTE_DIR}/docker-compose.yml ps -q aha 2>/dev/null) 2>/dev/null || echo 'missing'")"
  STATUS="${STATUS//[[:space:]]/}"
  if [[ "$STATUS" == "healthy" ]]; then
    AHA_HEALTHY=true
    break
  fi
  echo -n "  attempt $i/36 (status: ${STATUS}) ..."
  sleep 5
  echo ""
done

$AHA_HEALTHY || die "AHA failed to become healthy after 3 minutes. Check logs: ssh ${SSH_USER}@${SSH_HOST} 'docker compose -f ${REMOTE_DIR}/docker-compose.yml logs aha'"
ok "AHA is healthy"

# ─── Step 7: Generate provisioning URLs inside AHA container ─────────────────
log "Generating provisioning URLs for Axon, JSONStor, Cortex ..."

AHA_CONTAINER="$(_ssh "docker compose -f ${REMOTE_DIR}/docker-compose.yml ps -q aha")"
AHA_CONTAINER="${AHA_CONTAINER//[[:space:]]/}"
[[ -z "$AHA_CONTAINER" ]] && die "Could not find AHA container ID"

extract_url() {
  # Parse "one-time use URL: ssl://..." from provision output
  grep -oP '(?<=one-time use URL: )ssl://\S+' || true
}

log "  Provisioning axon (dmon port: ${AXON_DMON_PORT}) ..."
AXON_PROV="$(_ssh "docker exec ${AHA_CONTAINER} python -m synapse.tools.aha.provision.service --dmon-port ${AXON_DMON_PORT} 00.axon 2>&1" | extract_url)"
[[ -z "$AXON_PROV" ]] && die "Failed to generate Axon provisioning URL"
ok "  Axon URL: ${AXON_PROV}"

log "  Provisioning jsonstor (dmon port: ${JSONSTOR_DMON_PORT}) ..."
JSONSTOR_PROV="$(_ssh "docker exec ${AHA_CONTAINER} python -m synapse.tools.aha.provision.service --dmon-port ${JSONSTOR_DMON_PORT} 00.jsonstor 2>&1" | extract_url)"
[[ -z "$JSONSTOR_PROV" ]] && die "Failed to generate JSONStor provisioning URL"
ok "  JSONStor URL: ${JSONSTOR_PROV}"

log "  Provisioning cortex (dmon port: ${CORTEX_DMON_PORT}) ..."
CORTEX_PROV="$(_ssh "docker exec ${AHA_CONTAINER} python -m synapse.tools.aha.provision.service --dmon-port ${CORTEX_DMON_PORT} 00.cortex 2>&1" | extract_url)"
[[ -z "$CORTEX_PROV" ]] && die "Failed to generate Cortex provisioning URL"
ok "  Cortex URL: ${CORTEX_PROV}"

# ─── Step 8: Write provisioning URLs into .env ───────────────────────────────
log "Writing provisioning URLs to .env ..."
_ssh bash -s << EOF
cat > ${REMOTE_DIR}/.env << ENVEOF
SYNAPSE_VERSION=${SYNAPSE_VERSION}
AHA_NETWORK=${AHA_NETWORK}
AHA_DNS_NAME=${AHA_DNS}
HOST_IP=${HOST_IP}
SYN_AXON_AHA_PROVISION=${AXON_PROV}
SYN_JSONSTOR_AHA_PROVISION=${JSONSTOR_PROV}
SYN_CORTEX_AHA_PROVISION=${CORTEX_PROV}
ENVEOF
EOF
ok ".env written with provisioning URLs"

# ─── Step 9: Start Axon + JSONStor (Phase 2) ────────────────────────────────
log "Starting Axon + JSONStor (Phase 2: storage services) ..."
_ssh "cd ${REMOTE_DIR} && docker compose up -d axon-init axon jsonstor-init jsonstor"

log "Waiting for Axon to become healthy (up to 3 minutes) ..."
for i in $(seq 1 36); do
  STATUS="$(_ssh "docker inspect --format='{{.State.Health.Status}}' \$(docker compose -f ${REMOTE_DIR}/docker-compose.yml ps -q axon 2>/dev/null) 2>/dev/null || echo 'missing'")"
  STATUS="${STATUS//[[:space:]]/}"
  [[ "$STATUS" == "healthy" ]] && { ok "Axon healthy"; break; }
  echo "  attempt $i/36 (axon: ${STATUS})"
  sleep 5
done

log "Waiting for JSONStor to become healthy (up to 3 minutes) ..."
for i in $(seq 1 36); do
  STATUS="$(_ssh "docker inspect --format='{{.State.Health.Status}}' \$(docker compose -f ${REMOTE_DIR}/docker-compose.yml ps -q jsonstor 2>/dev/null) 2>/dev/null || echo 'missing'")"
  STATUS="${STATUS//[[:space:]]/}"
  [[ "$STATUS" == "healthy" ]] && { ok "JSONStor healthy"; break; }
  echo "  attempt $i/36 (jsonstor: ${STATUS})"
  sleep 5
done

# ─── Step 10: Start Cortex (Phase 3) ─────────────────────────────────────────
log "Starting Cortex (Phase 3: hypergraph database + Storm engine) ..."
_ssh "cd ${REMOTE_DIR} && docker compose up -d cortex-init cortex"

log "Waiting for Cortex to become healthy (up to 5 minutes) ..."
CORTEX_HEALTHY=false
for i in $(seq 1 60); do
  STATUS="$(_ssh "docker inspect --format='{{.State.Health.Status}}' \$(docker compose -f ${REMOTE_DIR}/docker-compose.yml ps -q cortex 2>/dev/null) 2>/dev/null || echo 'missing'")"
  STATUS="${STATUS//[[:space:]]/}"
  if [[ "$STATUS" == "healthy" ]]; then
    CORTEX_HEALTHY=true
    break
  fi
  echo "  attempt $i/60 (cortex: ${STATUS})"
  sleep 5
done

$CORTEX_HEALTHY || die "Cortex failed to become healthy after 5 minutes. Check: ssh ${SSH_USER}@${SSH_HOST} 'docker compose -f ${REMOTE_DIR}/docker-compose.yml logs cortex'"
ok "Cortex is healthy"

# ─── Step 11: Create admin user in Cortex ────────────────────────────────────
log "Creating admin user in Cortex ..."
CORTEX_CONTAINER="$(_ssh "docker compose -f ${REMOTE_DIR}/docker-compose.yml ps -q cortex")"
CORTEX_CONTAINER="${CORTEX_CONTAINER//[[:space:]]/}"

_ssh "docker exec ${CORTEX_CONTAINER} python -m synapse.tools.service.moduser --add --admin true admin" \
  && ok "Admin user created in Cortex" \
  || warn "Admin user may already exist (safe to ignore if reprovisioning)"

# ─── Step 12: Generate AHA enrollment URL for admin ──────────────────────────
log "Generating AHA enrollment URL for admin user ..."
ADMIN_ENROLL_URL="$(_ssh "docker exec ${AHA_CONTAINER} python -m synapse.tools.aha.provision.user admin 2>&1" | extract_url)"
[[ -z "$ADMIN_ENROLL_URL" ]] && die "Failed to generate admin enrollment URL"
ok "Admin enrollment URL generated"

# Save URL to file on host and locally
_ssh "echo '${ADMIN_ENROLL_URL}' > ${REMOTE_DIR}/admin-enroll-url.txt && chmod 600 ${REMOTE_DIR}/admin-enroll-url.txt"
echo "${ADMIN_ENROLL_URL}" > "$(dirname "$0")/admin-enroll-url.txt"
chmod 600 "$(dirname "$0")/admin-enroll-url.txt"
log "Enrollment URL saved to ./admin-enroll-url.txt (keep this secret — one-time use)"

# ─── Step 13: Update /etc/hosts on LOCAL machine ─────────────────────────────
log "Updating /etc/hosts on local machine with *.${DOMAIN} entries ..."

update_hosts() {
  local fqdn="$1"
  local ip="$2"
  if grep -qF "${fqdn}" /etc/hosts 2>/dev/null; then
    # Update existing entry
    sudo sed -i.bak "s/.*${fqdn}.*/${ip}  ${fqdn}/" /etc/hosts
  else
    echo "${ip}  ${fqdn}" | sudo tee -a /etc/hosts >/dev/null
  fi
}

update_hosts "aha.${DOMAIN}"      "${HOST_IP}"
update_hosts "cortex.${DOMAIN}"   "${HOST_IP}"
update_hosts "axon.${DOMAIN}"     "${HOST_IP}"
update_hosts "jsonstor.${DOMAIN}" "${HOST_IP}"
ok "Local /etc/hosts updated"

# ─── Step 14: Print DNS records to add to your DNS provider ──────────────────
cat << DNSEOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DNS Records to Add at Your DNS Provider (e.g. Route53)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  aha.${DOMAIN}.       IN  A  ${HOST_IP}   ; AHA — CA + discovery
  cortex.${DOMAIN}.    IN  A  ${HOST_IP}   ; Cortex HTTPS + Storm
  axon.${DOMAIN}.      IN  A  ${HOST_IP}   ; Axon blob storage
  jsonstor.${DOMAIN}.  IN  A  ${HOST_IP}   ; JSONStor JSON storage
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DNSEOF

# ─── Step 15: Print connection summary ───────────────────────────────────────
cat << SUMMARY

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Deployment Complete!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  AHA Network Name : ${AHA_NETWORK}        (immutable — baked into all certs)
  AHA DNS          : aha.${DOMAIN}
  Cortex HTTPS API : https://cortex.${DOMAIN}:${CORTEX_HTTPS_PORT}
  Cortex Telepath  : cortex.${DOMAIN}:${CORTEX_DMON_PORT}  (Storm CLI)
  Axon Telepath    : axon.${DOMAIN}:${AXON_DMON_PORT}
  JSONStor Telepath: jsonstor.${DOMAIN}:${JSONSTOR_DMON_PORT}

  Admin enrollment URL saved to: ./admin-enroll-url.txt
  Share it securely — it is one-time-use only.

  Next steps for each client machine:
    1. Install Synapse:
         pip install synapse
    2. Enroll using the admin URL:
         python -m synapse.tools.aha.enroll "${ADMIN_ENROLL_URL}"
    3. Connect to Cortex via Storm:
         python -m synapse.tools.storm \\
           "ssl://admin@${HOST_IP}:${CORTEX_DMON_PORT}?hostname=00.cortex.${AHA_NETWORK}&ca=${AHA_NETWORK}"
    4. OR run client-setup.sh with the enrollment URL:
         ./client-setup.sh --enroll-url "\$(cat admin-enroll-url.txt)" \\
                           --cortex-host "${HOST_IP}" \\
                           --cortex-port "${CORTEX_DMON_PORT}" \\
                           --aha-network "${AHA_NETWORK}"

  Manage services on the host:
    ssh ${SSH_USER}@${SSH_HOST} 'docker compose -f ${REMOTE_DIR}/docker-compose.yml ps'
    ssh ${SSH_USER}@${SSH_HOST} 'docker compose -f ${REMOTE_DIR}/docker-compose.yml logs -f cortex'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
