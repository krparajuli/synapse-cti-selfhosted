#!/usr/bin/env bash
# create-user.sh — Create a Synapse user and generate their AHA enrollment URL
#
# Run on the Docker host (same directory as docker-compose.yml):
#
#   sudo ./create-user.sh --username alice
#   sudo ./create-user.sh --username alice --admin
#
# Options:
#   --username <name>   Username to create (required)
#   --admin             Grant the user full admin rights in Cortex (default: off)
#   --domain  <domain>  External domain suffix (default: read from .env, else example.com)
#
# Output:
#   Prints the enrollment URL to stdout and saves it to ./<username>-enroll-url.txt
#   Share that file securely with the user — it is ONE-TIME USE only.
#   The user runs client-connect.sh with it to set up their machine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────
USERNAME=""
IS_ADMIN="false"
DOMAIN=""

# ─── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) USERNAME="$2"; shift 2 ;;
    --admin)    IS_ADMIN="true"; shift ;;
    --domain)   DOMAIN="$2"; shift 2 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$USERNAME" ]] && { echo "ERROR: --username is required"; exit 1; }
[[ "$(id -u)" -ne 0 ]] && { echo "ERROR: must be run as root: sudo ./create-user.sh --username ${USERNAME}"; exit 1; }

# ─── Logging helpers ─────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m[create-user]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[ warn ]\033[0m $*"; }
die()  { local m="$*"; echo -e "\033[1;31m[error ]\033[0m ${m}"; echo -e "\033[1;31m[error ]\033[0m ${m}" >&2; exit 1; }

# ─── Read config from .env ───────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || warn ".env not found — using defaults"

AHA_NETWORK="${AHA_NETWORK:-synapse}"
HOST_IP="${HOST_IP:-$(curl -fsSL --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')}"
HOST_IP="${HOST_IP//[[:space:]]/}"

# Domain: CLI flag > .env AHA_DNS_NAME > default
if [[ -n "$DOMAIN" ]]; then
  AHA_DNS="aha.${DOMAIN}"
elif [[ -n "${AHA_DNS_NAME:-}" ]]; then
  AHA_DNS="${AHA_DNS_NAME}"
  DOMAIN="${AHA_DNS_NAME#aha.}"
else
  DOMAIN="sheingroup.com"
  AHA_DNS="aha.${DOMAIN}"
fi

CORTEX_DMON_PORT="${CORTEX_DMON_PORT:-27495}"
SYNAPSE_VERSION="${SYNAPSE_VERSION:-v2.239.0}"

# ─── Locate Docker Compose ───────────────────────────────────────────────────
[[ -f "${SCRIPT_DIR}/docker-compose.yml" ]] \
  || die "docker-compose.yml not found in ${SCRIPT_DIR}"

if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  die "Docker Compose not found"
fi

# ─── Find running containers ─────────────────────────────────────────────────
log "Locating Cortex and AHA containers ..."

CORTEX_CTR="$(${COMPOSE} -f "${SCRIPT_DIR}/docker-compose.yml" ps -q cortex 2>/dev/null || true)"
AHA_CTR="$(${COMPOSE}    -f "${SCRIPT_DIR}/docker-compose.yml" ps -q aha    2>/dev/null || true)"

[[ -z "$CORTEX_CTR" ]] && die "Cortex container is not running. Deploy first: sudo ./deploy-from-host-bridged.sh"
[[ -z "$AHA_CTR"    ]] && die "AHA container is not running. Deploy first: sudo ./deploy-from-host-bridged.sh"

CORTEX_STATUS="$(docker inspect --format='{{.State.Health.Status}}' "${CORTEX_CTR}" 2>/dev/null || echo 'unknown')"
AHA_STATUS="$(docker inspect    --format='{{.State.Health.Status}}' "${AHA_CTR}"    2>/dev/null || echo 'unknown')"

[[ "$CORTEX_STATUS" != "healthy" ]] && die "Cortex is not healthy (status: ${CORTEX_STATUS})"
[[ "$AHA_STATUS"    != "healthy" ]] && die "AHA is not healthy (status: ${AHA_STATUS})"
ok "Cortex: healthy | AHA: healthy"

# ─── Create user in Cortex ───────────────────────────────────────────────────
log "Creating user '${USERNAME}' in Cortex (admin: ${IS_ADMIN}) ..."

if [[ "$IS_ADMIN" == "true" ]]; then
  docker exec "${CORTEX_CTR}" \
    python3 -m synapse.tools.service.moduser --add --admin true "${USERNAME}" \
    && ok "User '${USERNAME}' created with admin rights" \
    || warn "User '${USERNAME}' may already exist — updating admin flag"

  # Ensure admin flag is set even if user existed
  docker exec "${CORTEX_CTR}" \
    python3 -m synapse.tools.service.moduser --admin true "${USERNAME}" 2>/dev/null || true
else
  docker exec "${CORTEX_CTR}" \
    python3 -m synapse.tools.service.moduser --add "${USERNAME}" \
    && ok "User '${USERNAME}' created" \
    || warn "User '${USERNAME}' may already exist — continuing"
fi

# ─── Generate AHA enrollment URL ─────────────────────────────────────────────
log "Generating AHA enrollment URL for '${USERNAME}' ..."

_enroll_raw="$(docker exec "${AHA_CTR}" \
  python3 -m synapse.tools.aha.provision.user "${USERNAME}" 2>&1 || true)"

ENROLL_URL="$(echo "${_enroll_raw}" \
  | grep -oP '(?<=one-time use URL: )ssl://\S+' | head -1 || true)"

if [[ -z "$ENROLL_URL" ]]; then
  warn "AHA returned no enrollment URL. Raw output:"
  echo "────────────────────────────────────────"
  echo "${_enroll_raw}"
  echo "────────────────────────────────────────"
  die "Failed to generate enrollment URL. Check: ${COMPOSE} -f ${SCRIPT_DIR}/docker-compose.yml logs aha"
fi

# Rewrite Docker-internal "aha" hostname to the public FQDN
ENROLL_URL="${ENROLL_URL//ssl:\/\/aha:/ssl:\/\/${AHA_DNS}:}"
ok "Enrollment URL generated"

# ─── Save enrollment URL ─────────────────────────────────────────────────────
ENROLL_FILE="${SCRIPT_DIR}/${USERNAME}-enroll-url.txt"
echo "${ENROLL_URL}" > "${ENROLL_FILE}"
chmod 600 "${ENROLL_FILE}"
ok "Saved to ${ENROLL_FILE}"

# ─── Print instructions ───────────────────────────────────────────────────────
STORM_URL="ssl://${USERNAME}@${HOST_IP}:${CORTEX_DMON_PORT}?hostname=00.cortex.${AHA_NETWORK}&ca=${AHA_NETWORK}"

cat << INSTRUCTIONS

┌─────────────────────────────────────────────────────────────────────────────┐
│  User '${USERNAME}' is ready. Send these two files securely:
│    • ${ENROLL_FILE}
│    • client-connect.sh
└─────────────────────────────────────────────────────────────────────────────┘

  The enrollment URL below is ONE-TIME USE — it expires after the first
  successful connection. Do not share it over plaintext channels.

  ENROLLMENT URL:
  ${ENROLL_URL}

══════════════════════════════════════════════════════════════════════════════
  INSTRUCTIONS FOR ${USERNAME} — run these commands on your machine
══════════════════════════════════════════════════════════════════════════════

  Step 1 — Add the server to your DNS (requires sudo password):

    sudo bash -c 'echo "${HOST_IP}  aha.${DOMAIN}" >> /etc/hosts'
    sudo bash -c 'echo "${HOST_IP}  cortex.${DOMAIN}" >> /etc/hosts'
    sudo bash -c 'echo "${HOST_IP}  axon.${DOMAIN}" >> /etc/hosts'
    sudo bash -c 'echo "${HOST_IP}  jsonstor.${DOMAIN}" >> /etc/hosts'

  Step 2 — Create your working directory and move into it:

    mkdir -p ~/synapse-storm
    cd ~/synapse-storm

  Step 3 — Create a Python 3.11 virtual environment:

    python3.11 -m venv .venv

  Step 4 — Activate the environment and install Synapse:

    source .venv/bin/activate
    pip install synapse

  Step 5 — Enroll your machine with the Synapse certificate authority.
            This downloads your CA certificate and issues your user
            certificate. It will only work once:

    python -m synapse.tools.aha.enroll \\
      "${ENROLL_URL}"

  Step 6 — Connect to Cortex and start a Storm session:

    python -m synapse.tools.storm \\
      "${STORM_URL}"

  ── OR run client-connect.sh which does all of the above automatically: ──

    chmod +x client-connect.sh
    ./client-connect.sh \\
      --enroll-url  "${ENROLL_URL}" \\
      --host-ip     "${HOST_IP}" \\
      --username    "${USERNAME}" \\
      --aha-network "${AHA_NETWORK}"

══════════════════════════════════════════════════════════════════════════════
  After enrollment, reconnect any time with:

    cd ~/synapse-storm
    source .venv/bin/activate
    python -m synapse.tools.storm \\
      "${STORM_URL}"
══════════════════════════════════════════════════════════════════════════════
INSTRUCTIONS
