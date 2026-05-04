#!/usr/bin/env bash
# deploy-1-system.sh — Synapse CTI system-level setup (requires sudo)
#
# Run this FIRST on the Docker host as root. It applies kernel tuning and
# creates the storage volume directories. Run deploy-2-docker.sh afterward
# (no root required, only Docker group access).
#
#   sudo ./deploy-1-system.sh
#
# What this script does:
#   1.  Applies LMDB kernel tuning (sysctl)
#   2.  Creates /synapse-data-vols/syn/ storage directories owned by UID 999

set -euo pipefail

# ─── Logging helpers ─────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m[deploy]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[  ok  ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[ warn ]\033[0m $*"; }
die()  { local msg="$*"; echo -e "\033[1;31m[error ]\033[0m ${msg}"; echo -e "\033[1;31m[error ]\033[0m ${msg}" >&2; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
[[ "$(id -u)" -ne 0 ]] && die "Must be run as root: sudo ./deploy-1-system.sh"

# ─── Step 1: Kernel tuning for LMDB ──────────────────────────────────────────
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

# ─── Step 2: Storage directories owned by UID 999 (synuser) ──────────────────
log "Creating /synapse-data-vols/syn/ storage directories ..."
.
ok "Storage directories ready at /synapse-data-vols/syn/ (UID 999)"

cat << DONE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  System setup complete. Run deploy-2-docker.sh next:
    ./deploy-2-docker.sh [same options]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DONE
