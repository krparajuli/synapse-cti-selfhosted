#!/usr/bin/env bash
# deploy-from-host.sh — Synapse CTI deployment script
#
# Run this DIRECTLY on the Docker host after logging in via SSH.
# Place it in the same directory as docker-compose.yml, then:
#
#   sudo ./deploy-from-host.sh
#
# Options:
#   --version      <v2.x.x>   Synapse image tag         (default: v2.239.0)
#   --aha-network  <name>      AHA PKI network name      (default: synapse)
#                              WARNING: immutable after first boot
#   --domain       <domain>    External domain suffix    (default: sheingroup.com)
#   --host-ip      <ip>        Override auto-detected public IP
#
# What this script does:
#   1.  Verifies Docker is installed and running
#   2.  Applies LMDB kernel tuning (sysctl)
#   3.  Creates /srv/syn/ storage directories owned by UID 999
#   4.  Writes initial .env file
#   5.  Starts AHA (Phase 1) and waits for it to be healthy
#   6.  Generates one-time provisioning URLs for Axon, JSONStor, Cortex
#   7.  Writes provisioning URLs into .env
#   8.  Starts Axon + JSONStor (Phase 2) and waits for healthy
#   9.  Starts Cortex (Phase 3) and waits for healthy
#   10. Creates the 'admin' user in Cortex with full admin rights
#   11. Generates an AHA enrollment URL for the admin user
#       (rewrites internal 'aha' hostname to aha.<domain> for remote clients)
#   12. Prints DNS records, connection info, and client enrollment instructions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────
SYNAPSE_VERSION="v2.239.0"
AHA_NETWORK="synapse"
DOMAIN="sheingroup.com"
HOST_IP=""

AXON_DMON_PORT=27493
JSONSTOR_DMON_PORT=27494
CORTEX_DMON_PORT=27495
CORTEX_HTTPS_PORT=4443

# ─── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     SYNAPSE_VERSION="$2"; shift 2 ;;
    --aha-network) AHA_NETWORK="$2";     shift 2 ;;
    --domain)      DOMAIN="$2";          shift 2 ;;
    --host-ip)     HOST_IP="$2";         shift 2 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Logging helpers ─────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m[deploy]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[ warn ]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error ]\033[0m $*" >&2; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
[[ "$(id -u)" -ne 0 ]] && die "Must be run as root: sudo ./deploy-from-host.sh"

[[ -f "${SCRIPT_DIR}/docker-compose.yml" ]] \
  || die "docker-compose.yml not found in ${SCRIPT_DIR}"

if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  die "Neither 'docker compose' nor 'docker-compose' found. Install Docker Engine first."
fi

docker info &>/dev/null || die "Docker daemon is not running: systemctl start docker"
ok "Docker is available (${COMPOSE})"

# ─── Step 1: Detect host public IP ───────────────────────────────────────────
if [[ -z "$HOST_IP" ]]; then
  HOST_IP="$(curl -fsSL --max-time 5 ifconfig.me 2>/dev/null \
    || curl -fsSL --max-time 5 api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')"
  HOST_IP="${HOST_IP//[[:space:]]/}"
fi
[[ -z "$HOST_IP" ]] && die "Could not detect host IP. Pass --host-ip <ip>"
log "Host IP: ${HOST_IP}"

AHA_DNS="aha.${DOMAIN}"

# ─── Step 2: Kernel tuning for LMDB ──────────────────────────────────────────
log "Applying LMDB kernel tuning ..."
if grep -qF "Synapse / LMDB tuning" /etc/sysctl.conf 2>/dev/null; then
  warn "sysctl tuning already present — skipping"
else
  cat >> /etc/sysctl.conf << 'EOF'
# Synapse / LMDB tuning
vm.swappiness=10
vm.dirty_expire_centisecs=20
vm.dirty_writeback_centisecs=20
vm.dirty_background_ratio=2
vm.dirty_ratio=4
EOF
  sysctl -p >/dev/null 2>&1 || true
  ok "sysctl tuning applied"
fi

# ─── Step 3: Storage directories owned by UID 999 (synuser) ──────────────────
log "Creating /srv/syn/ storage directories ..."
for svc in 00.aha 00.axon 00.jsonstor 00.cortex; do
  mkdir -p "/srv/syn/${svc}/storage"
  chown -R 999:999 "/srv/syn/${svc}/storage"
done
ok "Storage directories ready (UID 999)"

# ─── Step 4: Write initial .env (provisioning URLs added later) ──────────────
# Note: no /etc/hosts entry needed for AHA. With bridge networking, Docker's
# internal DNS resolves the service name "aha" inside every container automatically.
log "Writing .env ..."
cat > "${SCRIPT_DIR}/.env" << EOF
SYNAPSE_VERSION=${SYNAPSE_VERSION}
AHA_NETWORK=${AHA_NETWORK}
AHA_DNS_NAME=${AHA_DNS}
HOST_IP=${HOST_IP}
SYN_AXON_AHA_PROVISION=
SYN_JSONSTOR_AHA_PROVISION=
SYN_CORTEX_AHA_PROVISION=
EOF
ok ".env written"

# ─── Helper: wait for a service healthcheck to report healthy ─────────────────
wait_healthy() {
  local service="$1"
  local max_attempts="$2"
  local interval=5

  log "Waiting for ${service} to become healthy (timeout: $((max_attempts * interval))s) ..."
  for i in $(seq 1 "$max_attempts"); do
    local cid
    cid="$(${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" ps -q "${service}" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      local status
      status="$(docker inspect --format='{{.State.Health.Status}}' "${cid}" 2>/dev/null || echo 'unknown')"
      if [[ "$status" == "healthy" ]]; then
        ok "${service} is healthy"
        return 0
      fi
      echo "  [${i}/${max_attempts}] ${service}: ${status}"
    else
      echo "  [${i}/${max_attempts}] ${service}: container not found yet"
    fi
    sleep "$interval"
  done
  die "${service} did not become healthy in time.\nCheck logs: ${COMPOSE} -f ${SCRIPT_DIR}/docker-compose.yml logs ${service}"
}

# ─── Helper: extract one-time provisioning URL from AHA output ───────────────
extract_prov_url() {
  grep -oP '(?<=one-time use URL: )ssl://\S+' || true
}

# ─── Step 6: Start AHA (Phase 1) ─────────────────────────────────────────────
log "Phase 1 — Starting AHA (Certificate Authority + Service Discovery) ..."
${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" up -d aha-init aha

wait_healthy aha 36   # up to 3 minutes

AHA_CTR="$(${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" ps -q aha)"
[[ -z "$AHA_CTR" ]] && die "Could not find AHA container ID"

# ─── Step 7: Generate one-time provisioning URLs inside AHA ──────────────────
log "Generating provisioning URLs ..."

log "  axon (dmon port ${AXON_DMON_PORT}) ..."
AXON_PROV="$(docker exec "${AHA_CTR}" \
  python3 -m synapse.tools.aha.provision.service --dmon-port "${AXON_DMON_PORT}" 00.axon 2>&1 \
  | extract_prov_url)"
[[ -z "$AXON_PROV" ]] && die "Failed to generate Axon provisioning URL"
ok "  Axon:     ${AXON_PROV}"

log "  jsonstor (dmon port ${JSONSTOR_DMON_PORT}) ..."
JSONSTOR_PROV="$(docker exec "${AHA_CTR}" \
  python3 -m synapse.tools.aha.provision.service --dmon-port "${JSONSTOR_DMON_PORT}" 00.jsonstor 2>&1 \
  | extract_prov_url)"
[[ -z "$JSONSTOR_PROV" ]] && die "Failed to generate JSONStor provisioning URL"
ok "  JSONStor: ${JSONSTOR_PROV}"

log "  cortex (dmon port ${CORTEX_DMON_PORT}) ..."
CORTEX_PROV="$(docker exec "${AHA_CTR}" \
  python3 -m synapse.tools.aha.provision.service --dmon-port "${CORTEX_DMON_PORT}" 00.cortex 2>&1 \
  | extract_prov_url)"
[[ -z "$CORTEX_PROV" ]] && die "Failed to generate Cortex provisioning URL"
ok "  Cortex:   ${CORTEX_PROV}"

# ─── Step 8: Write provisioning URLs into .env ───────────────────────────────
log "Writing provisioning URLs to .env ..."
cat > "${SCRIPT_DIR}/.env" << EOF
SYNAPSE_VERSION=${SYNAPSE_VERSION}
AHA_NETWORK=${AHA_NETWORK}
AHA_DNS_NAME=${AHA_DNS}
HOST_IP=${HOST_IP}
SYN_AXON_AHA_PROVISION=${AXON_PROV}
SYN_JSONSTOR_AHA_PROVISION=${JSONSTOR_PROV}
SYN_CORTEX_AHA_PROVISION=${CORTEX_PROV}
EOF
ok ".env updated with provisioning URLs"

# ─── Step 9: Start Axon + JSONStor (Phase 2) ─────────────────────────────────
log "Phase 2 — Starting Axon + JSONStor (storage services) ..."
${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" up -d axon-init axon jsonstor-init jsonstor

wait_healthy axon     36   # up to 3 minutes
wait_healthy jsonstor 36   # up to 3 minutes

# ─── Step 10: Start Cortex (Phase 3) ─────────────────────────────────────────
log "Phase 3 — Starting Cortex (hypergraph database + Storm engine) ..."
${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" up -d cortex-init cortex

wait_healthy cortex 60   # up to 5 minutes

CORTEX_CTR="$(${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" ps -q cortex)"
[[ -z "$CORTEX_CTR" ]] && die "Could not find Cortex container ID"

# ─── Step 11: Create admin user in Cortex ────────────────────────────────────
log "Creating 'admin' user in Cortex ..."
docker exec "${CORTEX_CTR}" \
  python3 -m synapse.tools.service.moduser --add --admin true admin \
  && ok "admin user created" \
  || warn "admin user may already exist — safe to ignore on re-runs"

# ─── Step 11: Generate admin enrollment URL from AHA ─────────────────────────
log "Generating AHA enrollment URL for admin ..."
ADMIN_ENROLL_URL="$(docker exec "${AHA_CTR}" \
  python3 -m synapse.tools.aha.provision.user admin 2>&1 \
  | extract_prov_url)"
[[ -z "$ADMIN_ENROLL_URL" ]] && die "Failed to generate admin enrollment URL"

# AHA uses SYN_AHA_DNS_NAME="aha" (Docker internal service name) when building
# provisioning URLs. Remote clients cannot resolve "aha" — rewrite it to the
# public FQDN so the enrollment URL works from outside the Docker network.
ADMIN_ENROLL_URL="${ADMIN_ENROLL_URL//ssl:\/\/aha:/ssl:\/\/${AHA_DNS}:}"
ok "Enrollment URL hostname rewritten to ${AHA_DNS} for remote client use"

ENROLL_FILE="${SCRIPT_DIR}/admin-enroll-url.txt"
echo "${ADMIN_ENROLL_URL}" > "${ENROLL_FILE}"
chmod 600 "${ENROLL_FILE}"
ok "Enrollment URL saved to ${ENROLL_FILE}"

# ─── Step 12: Summary ────────────────────────────────────────────────────────
cat << SUMMARY

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DNS Records — Add at your DNS provider
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  aha.${DOMAIN}.       IN  A  ${HOST_IP}
  cortex.${DOMAIN}.    IN  A  ${HOST_IP}
  axon.${DOMAIN}.      IN  A  ${HOST_IP}
  jsonstor.${DOMAIN}.  IN  A  ${HOST_IP}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Deployment Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  AHA Network (immutable) : ${AHA_NETWORK}
  Cortex HTTPS API        : https://cortex.${DOMAIN}:${CORTEX_HTTPS_PORT}
  Cortex Storm (Telepath) : ${HOST_IP}:${CORTEX_DMON_PORT}
  Axon Telepath           : ${HOST_IP}:${AXON_DMON_PORT}
  JSONStor Telepath       : ${HOST_IP}:${JSONSTOR_DMON_PORT}

  Admin enrollment URL    : ${ENROLL_FILE}
  Send this securely to each client — it is ONE-TIME USE only.

  On each client machine:
    pip install synapse
    python3 -m synapse.tools.aha.enroll "${ADMIN_ENROLL_URL}"
    python3 -m synapse.tools.storm \\
      "ssl://admin@${HOST_IP}:${CORTEX_DMON_PORT}?hostname=00.cortex.${AHA_NETWORK}&ca=${AHA_NETWORK}"

  Service management:
    ${COMPOSE} -f ${SCRIPT_DIR}/docker-compose.yml ps
    ${COMPOSE} -f ${SCRIPT_DIR}/docker-compose.yml logs -f cortex
    ${COMPOSE} -f ${SCRIPT_DIR}/docker-compose.yml restart cortex
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
