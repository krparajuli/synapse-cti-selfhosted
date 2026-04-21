#!/usr/bin/env bash
# client-connect.sh — Set up your machine and connect to Synapse Cortex
#
# Usage:
#   ./client-connect.sh \
#     --enroll-url  "ssl://aha.example.com:27272/<guid>?certhash=<sha256>" \
#     --host-ip     203.0.113.10 \
#     --username    alice \
#     --aha-network synapse
#
# If enroll-url is omitted, the script reads it from <username>-enroll-url.txt
# in the same directory.
#
# Requires Python 3.11 to be installed before running.
#   macOS : brew install python@3.11
#   Ubuntu: sudo apt install python3.11 python3.11-venv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Arguments ───────────────────────────────────────────────────────────────
ENROLL_URL=""
HOST_IP=""
USERNAME="admin"
AHA_NETWORK="synapse"
CORTEX_PORT="27495"
DOMAIN="example.com"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enroll-url)   ENROLL_URL="$2";   shift 2 ;;
    --host-ip)      HOST_IP="$2";      shift 2 ;;
    --username)     USERNAME="$2";     shift 2 ;;
    --aha-network)  AHA_NETWORK="$2";  shift 2 ;;
    --cortex-port)  CORTEX_PORT="$2";  shift 2 ;;
    --domain)       DOMAIN="$2";       shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Read enrollment URL from file if not passed directly
if [[ -z "$ENROLL_URL" ]]; then
  ENROLL_FILE="${SCRIPT_DIR}/${USERNAME}-enroll-url.txt"
  [[ ! -f "$ENROLL_FILE" ]] && ENROLL_FILE="${SCRIPT_DIR}/admin-enroll-url.txt"
  [[ -f "$ENROLL_FILE" ]] || { echo "ERROR: pass --enroll-url or place ${USERNAME}-enroll-url.txt here"; exit 1; }
  ENROLL_URL="$(cat "${ENROLL_FILE}")"
fi

[[ -z "$HOST_IP" ]] && { echo "ERROR: --host-ip is required"; exit 1; }

STORM_URL="ssl://${USERNAME}@${HOST_IP}:${CORTEX_PORT}?hostname=00.cortex.${AHA_NETWORK}&ca=${AHA_NETWORK}"
SYNAPSE_DIR="${HOME}/synapse-storm"
VENV_DIR="${SYNAPSE_DIR}/.venv"

# ─── Helpers ─────────────────────────────────────────────────────────────────
banner() { echo -e "\n\033[1;37m▶ $*\033[0m"; }
ok()     { echo -e "  \033[1;32m✓\033[0m $*"; }

# ─── Step 1: /etc/hosts ──────────────────────────────────────────────────────
banner "Step 1 — Adding *.${DOMAIN} to /etc/hosts"

sudo bash -c "echo '${HOST_IP}  aha.${DOMAIN}' >> /etc/hosts"
sudo bash -c "echo '${HOST_IP}  cortex.${DOMAIN}' >> /etc/hosts"
sudo bash -c "echo '${HOST_IP}  axon.${DOMAIN}' >> /etc/hosts"
sudo bash -c "echo '${HOST_IP}  jsonstor.${DOMAIN}' >> /etc/hosts"

ok "DNS entries added"

# ─── Step 2: Working directory ───────────────────────────────────────────────
banner "Step 2 — Creating working directory: ${SYNAPSE_DIR}"

mkdir -p "${SYNAPSE_DIR}"
ok "${SYNAPSE_DIR} ready"

# ─── Step 3: Virtual environment ─────────────────────────────────────────────
banner "Step 3 — Creating Python 3.11 virtual environment"

python3.11 -m venv "${VENV_DIR}"
ok ".venv created at ${VENV_DIR}"

# ─── Step 4: Install Synapse ──────────────────────────────────────────────────
banner "Step 4 — Installing Synapse into the virtual environment"

source "${VENV_DIR}/bin/activate"
pip install --quiet synapse
ok "Synapse $(python -c 'import synapse; print(synapse.version)') installed"

# ─── Step 5: Enroll with AHA ─────────────────────────────────────────────────
banner "Step 5 — Enrolling with AHA (downloads CA cert + issues your user cert)"
echo "  URL: ${ENROLL_URL}"
echo ""

python -m synapse.tools.aha.enroll "${ENROLL_URL}"
ok "Enrollment complete — certificates stored in ~/.syn/"

# ─── Write reusable connect script ───────────────────────────────────────────
cat > "${SYNAPSE_DIR}/storm.sh" << STORMSCRIPT
#!/usr/bin/env bash
source "${VENV_DIR}/bin/activate"
exec python -m synapse.tools.storm "${STORM_URL}" "\$@"
STORMSCRIPT
chmod +x "${SYNAPSE_DIR}/storm.sh"
ok "Shortcut written: ${SYNAPSE_DIR}/storm.sh"

# ─── Step 6: Launch Storm ─────────────────────────────────────────────────────
banner "Step 6 — Connecting to Cortex"
echo "  ${STORM_URL}"
echo ""
echo "  To reconnect later:"
echo "    ${SYNAPSE_DIR}/storm.sh"
echo ""

exec python -m synapse.tools.storm "${STORM_URL}"
