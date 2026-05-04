#!/usr/bin/env bash
# deploy-2-docker.sh — Synapse CTI Docker deployment (Docker group access only)
#
# Run this AFTER deploy-1-system.sh (which requires sudo).
# Place it in the same directory as docker-compose-bridged.yml, then:
#
#   ./deploy-2-docker.sh
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
#   2.  Detects host public IP
#   3.  Writes initial .env file
#   4.  Starts AHA (Phase 1) and waits for it to be healthy
#   5.  Generates one-time provisioning URLs for Axon, JSONStor, Cortex
#   6.  Writes provisioning URLs into .env
#   7.  Starts Axon + JSONStor (Phase 2) and waits for healthy
#   8.  Starts Cortex (Phase 3) and waits for healthy
#   9.  Creates the 'admin' user in Cortex with full admin rights
#   10. Generates an AHA enrollment URL for the admin user
#       (rewrites internal 'aha' hostname to aha.<domain> for remote clients)
#   11. Prints DNS records, connection info, and client enrollment instructions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate docker-compose-bridged.yml: same dir as script, or one level up
if [[ -f "${SCRIPT_DIR}/docker-compose-bridged.yml" ]]; then
  COMPOSE_FILE="${SCRIPT_DIR}/docker-compose-bridged.yml"
elif [[ -f "${SCRIPT_DIR}/../docker-compose-bridged.yml" ]]; then
  COMPOSE_FILE="$(cd "${SCRIPT_DIR}/.." && pwd)/docker-compose-bridged.yml"
else
  COMPOSE_FILE="${SCRIPT_DIR}/docker-compose-bridged.yml"  # will fail pre-flight with a clear message
fi

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
die()  { local msg="$*"; echo -e "\033[1;31m[error ]\033[0m ${msg}"; echo -e "\033[1;31m[error ]\033[0m ${msg}" >&2; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
[[ -f "${COMPOSE_FILE}" ]] \
  || die "docker-compose-bridged.yml not found in ${SCRIPT_DIR} or $(dirname "${COMPOSE_FILE}")"

if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  die "Neither 'docker compose' nor 'docker-compose' found. Install Docker Engine first."
fi

docker info &>/dev/null || die "Docker daemon is not running or you lack Docker group access"
ok "Docker is available (${COMPOSE})"

# Verify system setup was run first
for svc in 00.aha 00.axon 00.jsonstor 00.cortex; do
  [[ -d "/synapse-data-vols/syn/${svc}/storage" ]] \
    || die "Storage directory /synapse-data-vols/syn/${svc}/storage not found. Run deploy-1-system.sh first."
done
ok "Storage directories verified"

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

# ─── Step 2: Write initial .env (provisioning URLs added later) ──────────────
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
    cid="$(${COMPOSE} -f "${COMPOSE_FILE}" ps -q "${service}" 2>/dev/null || true)"
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
  die "${service} did not become healthy in time.\nCheck logs: ${COMPOSE} -f ${COMPOSE_FILE} logs ${service}"
}

# ─── Helper: extract one-time provisioning URL from a captured string ────────
extract_prov_url() {
  echo "$1" | grep -oP '(?<=one-time use URL: )ssl://\S+' | head -1 || true
}

# ─── Step 3: Start AHA (Phase 1) ─────────────────────────────────────────────
log "Phase 1 — Starting AHA (Certificate Authority + Service Discovery) ..."
${COMPOSE} -f "${COMPOSE_FILE}" up -d aha-init aha

wait_healthy aha 36   # up to 3 minutes

AHA_CTR="$(${COMPOSE} -f "${COMPOSE_FILE}" ps -q aha)"
[[ -z "$AHA_CTR" ]] && die "Could not find AHA container ID"

# ─── Step 4: Generate one-time provisioning URLs inside AHA ──────────────────
log "Generating provisioning URLs ..."

log "  axon (dmon port ${AXON_DMON_PORT}) ..."
_raw="$(docker exec "${AHA_CTR}" python3 -m synapse.tools.aha.provision.service --dmon-port "${AXON_DMON_PORT}" 00.axon 2>&1 || true)"
AXON_PROV="$(extract_prov_url "${_raw}")"
[[ -z "$AXON_PROV" ]] && { warn "AHA output was:"; echo "${_raw}"; die "Failed to generate Axon provisioning URL"; }
ok "  Axon:     ${AXON_PROV}"

log "  jsonstor (dmon port ${JSONSTOR_DMON_PORT}) ..."
_raw="$(docker exec "${AHA_CTR}" python3 -m synapse.tools.aha.provision.service --dmon-port "${JSONSTOR_DMON_PORT}" 00.jsonstor 2>&1 || true)"
JSONSTOR_PROV="$(extract_prov_url "${_raw}")"
[[ -z "$JSONSTOR_PROV" ]] && { warn "AHA output was:"; echo "${_raw}"; die "Failed to generate JSONStor provisioning URL"; }
ok "  JSONStor: ${JSONSTOR_PROV}"

log "  cortex (dmon port ${CORTEX_DMON_PORT}) ..."
_raw="$(docker exec "${AHA_CTR}" python3 -m synapse.tools.aha.provision.service --dmon-port "${CORTEX_DMON_PORT}" 00.cortex 2>&1 || true)"
CORTEX_PROV="$(extract_prov_url "${_raw}")"
[[ -z "$CORTEX_PROV" ]] && { warn "AHA output was:"; echo "${_raw}"; die "Failed to generate Cortex provisioning URL"; }
ok "  Cortex:   ${CORTEX_PROV}"

# ─── Step 5: Write provisioning URLs into .env ───────────────────────────────
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

# ─── Step 6: Start Axon + JSONStor (Phase 2) ─────────────────────────────────
log "Phase 2 — Starting Axon + JSONStor (storage services) ..."
${COMPOSE} -f "${COMPOSE_FILE}" up -d axon-init axon jsonstor-init jsonstor

wait_healthy axon     36   # up to 3 minutes
wait_healthy jsonstor 36   # up to 3 minutes

# ─── Step 7: Start Cortex (Phase 3) ──────────────────────────────────────────
log "Phase 3 — Starting Cortex (hypergraph database + Storm engine) ..."
${COMPOSE} -f "${COMPOSE_FILE}" up -d cortex-init cortex

wait_healthy cortex 60   # up to 5 minutes

CORTEX_CTR="$(${COMPOSE} -f "${COMPOSE_FILE}" ps -q cortex)"
[[ -z "$CORTEX_CTR" ]] && die "Could not find Cortex container ID"

# ─── Step 8: Create admin user in Cortex ─────────────────────────────────────
log "Creating 'admin' user in Cortex ..."
docker exec "${CORTEX_CTR}" \
  python3 -m synapse.tools.service.moduser --add --admin true admin \
  && ok "admin user created" \
  || warn "admin user may already exist — safe to ignore on re-runs"

# ─── Step 9: Generate admin enrollment URL from AHA ──────────────────────────
log "Generating AHA enrollment URL for admin ..."
_enroll_raw="$(docker exec "${AHA_CTR}" \
  python3 -m synapse.tools.aha.provision.user admin 2>&1 || true)"

ADMIN_ENROLL_URL="$(extract_prov_url "${_enroll_raw}")"

if [[ -z "$ADMIN_ENROLL_URL" ]]; then
  warn "AHA returned no enrollment URL. Raw output from the container:"
  echo "────────────────────────────────────────"
  echo "${_enroll_raw}"
  echo "────────────────────────────────────────"
  die "Failed to generate admin enrollment URL. Check AHA logs: ${COMPOSE} -f ${COMPOSE_FILE} logs aha"
fi

# AHA uses SYN_AHA_DNS_NAME="aha" (Docker internal service name) when building
# provisioning URLs. Remote clients cannot resolve "aha" — rewrite it to the
# public FQDN so the enrollment URL works from outside the Docker network.
ADMIN_ENROLL_URL="${ADMIN_ENROLL_URL//ssl:\/\/aha:/ssl:\/\/${AHA_DNS}:}"
ok "Enrollment URL hostname rewritten to ${AHA_DNS} for remote client use"

ENROLL_FILE="${SCRIPT_DIR}/admin-enroll-url.txt"
echo "${ADMIN_ENROLL_URL}" > "${ENROLL_FILE}"
chmod 600 "${ENROLL_FILE}"
ok "Enrollment URL saved to ${ENROLL_FILE}"

# ─── Step 10: Summary ────────────────────────────────────────────────────────
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
    ${COMPOSE} -f ${COMPOSE_FILE} ps
    ${COMPOSE} -f ${COMPOSE_FILE} logs -f cortex
    ${COMPOSE} -f ${COMPOSE_FILE} restart cortex
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY