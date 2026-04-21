#!/usr/bin/env bash
# client-connect-verbose.sh — Set up a client machine and connect to Synapse Cortex
#
# Run this on the END USER'S machine (Linux or macOS).
# Place it alongside <username>-enroll-url.txt in the same directory, then:
#
#   chmod +x client-connect-verbose.sh
#   ./client-connect-verbose.sh --username alice --host-ip 203.0.113.10
#
# Or pass everything explicitly:
#   ./client-connect-verbose.sh \
#     --enroll-url "ssl://aha.example.com:27272/<guid>?certhash=<sha256>" \
#     --host-ip    203.0.113.10 \
#     --username   alice \
#     --aha-network synapse
#
# Options:
#   --enroll-url  <url>     AHA one-time enrollment URL (or auto-read from <username>-enroll-url.txt)
#   --host-ip     <ip>      Docker host public IP (required for /etc/hosts + Storm URL)
#   --username    <name>    Synapse username                      (default: admin)
#   --aha-network <name>    AHA PKI network name                  (default: synapse)
#   --cortex-port <port>    Cortex Telepath port                  (default: 27495)
#   --domain      <domain>  External domain suffix                (default: example.com)
#   --workdir     <path>    Where to create synapse-storm folder  (default: $HOME)
#
# What this script does:
#   1. Adds *.example.com DNS entries to /etc/hosts (requires sudo)
#   2. Creates ~/synapse-storm/ working directory
#   3. Installs Python 3.11 if not present (apt on Linux, brew on macOS)
#   4. Creates and activates a .venv inside synapse-storm/
#   5. Installs the synapse package into the venv
#   6. Runs aha.enroll with the one-time enrollment URL
#   7. Launches Storm CLI connected to Cortex

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────
ENROLL_URL=""
HOST_IP=""
USERNAME="admin"
AHA_NETWORK="synapse"
CORTEX_PORT="27495"
DOMAIN="example.com"
WORKDIR="${HOME}"

# ─── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enroll-url)   ENROLL_URL="$2";   shift 2 ;;
    --host-ip)      HOST_IP="$2";      shift 2 ;;
    --username)     USERNAME="$2";     shift 2 ;;
    --aha-network)  AHA_NETWORK="$2";  shift 2 ;;
    --cortex-port)  CORTEX_PORT="$2";  shift 2 ;;
    --domain)       DOMAIN="$2";       shift 2 ;;
    --workdir)      WORKDIR="$2";      shift 2 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Logging helpers ─────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m[connect]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[  ok   ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[ warn  ]\033[0m $*"; }
die()  { local m="$*"; echo -e "\033[1;31m[ error ]\033[0m ${m}"; exit 1; }
step() { echo -e "\n\033[1;37m━━━ $* ━━━\033[0m"; }

# ─── Resolve enrollment URL ──────────────────────────────────────────────────
if [[ -z "$ENROLL_URL" ]]; then
  ENROLL_FILE="${SCRIPT_DIR}/${USERNAME}-enroll-url.txt"
  [[ ! -f "$ENROLL_FILE" ]] && ENROLL_FILE="${SCRIPT_DIR}/admin-enroll-url.txt"
  [[ -f "$ENROLL_FILE" ]] \
    && ENROLL_URL="$(cat "${ENROLL_FILE}")" \
    || die "No enrollment URL provided. Pass --enroll-url <url> or place ${USERNAME}-enroll-url.txt alongside this script."
  log "Read enrollment URL from ${ENROLL_FILE}"
fi

[[ -z "$HOST_IP" ]] && die "--host-ip is required (the Docker host's public IP address)"

SYNAPSE_DIR="${WORKDIR}/synapse-storm"
VENV_DIR="${SYNAPSE_DIR}/.venv"
STORM_URL="ssl://${USERNAME}@${HOST_IP}:${CORTEX_PORT}?hostname=00.cortex.${AHA_NETWORK}&ca=${AHA_NETWORK}"

# ─── Step 1: Add DNS entries to /etc/hosts ────────────────────────────────────
step "Step 1: DNS — /etc/hosts"
log "Adding *.${DOMAIN} entries pointing to ${HOST_IP} (requires sudo) ..."

add_host() {
  local fqdn="$1" ip="$2"
  if grep -qP "^\s*[0-9].*\b${fqdn}\b" /etc/hosts 2>/dev/null; then
    warn "  ${fqdn} already in /etc/hosts — skipping"
  else
    echo "${ip}  ${fqdn}" | sudo tee -a /etc/hosts >/dev/null
    ok "  Added: ${ip}  ${fqdn}"
  fi
}

add_host "aha.${DOMAIN}"      "${HOST_IP}"
add_host "cortex.${DOMAIN}"   "${HOST_IP}"
add_host "axon.${DOMAIN}"     "${HOST_IP}"
add_host "jsonstor.${DOMAIN}" "${HOST_IP}"

# ─── Step 2: Create synapse-storm directory ───────────────────────────────────
step "Step 2: Working directory — ${SYNAPSE_DIR}"
mkdir -p "${SYNAPSE_DIR}"
ok "Directory ready: ${SYNAPSE_DIR}"

# ─── Step 3: Install Python 3.11 ─────────────────────────────────────────────
step "Step 3: Python 3.11"

find_python311() {
  for cmd in python3.11 python3 python; do
    if command -v "${cmd}" &>/dev/null; then
      local ver
      ver="$("${cmd}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
      if [[ "$ver" == "3.11" ]]; then
        echo "${cmd}"
        return 0
      fi
    fi
  done
  return 1
}

PYTHON=""
if PYTHON="$(find_python311)"; then
  ok "Python 3.11 found: $(command -v "${PYTHON}") ($(${PYTHON} --version 2>&1))"
else
  log "Python 3.11 not found — installing ..."
  OS="$(uname -s)"

  if [[ "$OS" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew install python@3.11
      PYTHON="$(brew --prefix python@3.11)/bin/python3.11"
      ok "Python 3.11 installed via Homebrew"
    else
      die "Homebrew not found. Install it from https://brew.sh then re-run this script."
    fi

  elif [[ "$OS" == "Linux" ]]; then
    if command -v apt-get &>/dev/null; then
      sudo apt-get update -qq
      sudo apt-get install -y python3.11 python3.11-venv python3.11-dev
      PYTHON="python3.11"
      ok "Python 3.11 installed via apt"
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y python3.11 python3.11-venv
      PYTHON="python3.11"
      ok "Python 3.11 installed via dnf"
    else
      die "Unsupported Linux distro — install Python 3.11 manually then re-run."
    fi

  else
    die "Unsupported OS: ${OS}. Install Python 3.11 manually then re-run."
  fi
fi

"${PYTHON}" --version &>/dev/null || die "Python 3.11 installation failed"
log "Using: $(command -v "${PYTHON}") — $("${PYTHON}" --version 2>&1)"

# ─── Step 4: Create virtual environment ──────────────────────────────────────
step "Step 4: Virtual environment — ${VENV_DIR}"

if [[ -d "${VENV_DIR}" && -f "${VENV_DIR}/bin/python" ]]; then
  warn ".venv already exists — skipping creation"
else
  log "Creating .venv with Python 3.11 ..."
  "${PYTHON}" -m venv "${VENV_DIR}"
  ok ".venv created"
fi

source "${VENV_DIR}/bin/activate"
ok "Activated: ${VENV_DIR}"
log "Python in use: $(command -v python) — $(python --version 2>&1)"

# ─── Step 5: Install Synapse ──────────────────────────────────────────────────
step "Step 5: Install Synapse"

if python -c "import synapse" &>/dev/null 2>&1; then
  SYN_VER="$(python -c "import synapse; print(synapse.version)" 2>/dev/null || echo 'unknown')"
  warn "Synapse already installed (version: ${SYN_VER}) — upgrading if needed"
  pip install --upgrade --quiet synapse
else
  log "Installing Synapse ..."
  pip install --quiet synapse
fi

SYN_VER="$(python -c "import synapse; print(synapse.version)" 2>/dev/null || echo 'unknown')"
ok "Synapse installed (version: ${SYN_VER})"

# ─── Step 6: AHA enrollment ───────────────────────────────────────────────────
step "Step 6: AHA Enrollment"
log "Enrolling with AHA ..."
log "  URL: ${ENROLL_URL}"
log "  This downloads your CA certificate and issues your user certificate."
log "  Certificates stored in: ~/.syn/"

python -m synapse.tools.aha.enroll "${ENROLL_URL}" \
  && ok "Enrollment complete" \
  || die "Enrollment failed. This URL may already be used (one-time only). Ask your admin to run: sudo ./create-user.sh --username ${USERNAME}"

CA_FILE="${HOME}/.syn/certs/cas/${AHA_NETWORK}.crt"
USER_CERT="${HOME}/.syn/certs/users/${USERNAME}@${AHA_NETWORK}.crt"
[[ -f "$CA_FILE" ]]   && ok "CA cert:   ${CA_FILE}"   || warn "CA cert not found at expected path: ${CA_FILE}"
[[ -f "$USER_CERT" ]] && ok "User cert: ${USER_CERT}" || warn "User cert not found at expected path: ${USER_CERT}"

# ─── Write a convenience connect script ──────────────────────────────────────
CONNECT_SH="${SYNAPSE_DIR}/storm.sh"
cat > "${CONNECT_SH}" << STORMSCRIPT
#!/usr/bin/env bash
# Start a Storm session for ${USERNAME} on ${DOMAIN}
# Run: ./storm.sh
set -euo pipefail
source "${VENV_DIR}/bin/activate"
exec python -m synapse.tools.storm "${STORM_URL}" "\$@"
STORMSCRIPT
chmod +x "${CONNECT_SH}"
ok "Convenience script written: ${CONNECT_SH}"

# ─── Step 7: Launch Storm ─────────────────────────────────────────────────────
step "Step 7: Connecting to Cortex via Storm"

cat << INFO

  User        : ${USERNAME}
  Cortex      : ${HOST_IP}:${CORTEX_PORT}
  AHA Network : ${AHA_NETWORK}
  Storm URL   : ${STORM_URL}

  Future sessions: cd ${SYNAPSE_DIR} && ./storm.sh

INFO

log "Launching Storm — type 'help' for available commands, Ctrl-D to exit."
echo ""

exec python -m synapse.tools.storm "${STORM_URL}"
