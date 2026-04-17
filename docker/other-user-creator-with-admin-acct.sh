#!/bin/bash
# create_user.sh — Create a Synapse user via HTTPS API
#
# Usage:
#   ./create_user.sh [options]
#
# Options:
#   -H, --host        Cortex host URL     (default: https://localhost:4443)
#   -u, --admin-user  Admin username      (default: prompted)
#   -p, --admin-pass  Admin password      (default: prompted)
#   -n, --new-user    New username        (default: prompted)
#   -w, --new-pass    New user password   (default: prompted)
#   -a, --admin       Grant admin to new user
#   -h, --help        Show this help

set -e

# ---------- Defaults ----------
HOST="https://localhost:4443"
ADMIN_USER=""
ADMIN_PASS=""
NEW_USER=""
NEW_PASS=""
GRANT_ADMIN=false
COOKIE_FILE="/tmp/syn_$(date +%s).cookies"

# ---------- Usage ----------
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//'
    exit 0
}

# ---------- Argument parsing ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)        HOST="$2";        shift 2 ;;
        -u|--admin-user)  ADMIN_USER="$2";  shift 2 ;;
        -p|--admin-pass)  ADMIN_PASS="$2";  shift 2 ;;
        -n|--new-user)    NEW_USER="$2";    shift 2 ;;
        -w|--new-pass)    NEW_PASS="$2";    shift 2 ;;
        -a|--admin)       GRANT_ADMIN=true; shift ;;
        -h|--help)        usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# ---------- Prompt for missing values ----------
if [[ -z "$ADMIN_USER" ]]; then
    read -r -p "Admin username: " ADMIN_USER
fi

if [[ -z "$ADMIN_PASS" ]]; then
    read -s -p "Admin password: " ADMIN_PASS
    echo
fi

if [[ -z "$NEW_USER" ]]; then
    read -r -p "New username: " NEW_USER
fi

if [[ -z "$NEW_PASS" ]]; then
    read -s -p "Password for '$NEW_USER': " NEW_PASS
    echo
    read -s -p "Confirm password: " NEW_PASS_CONFIRM
    echo
    if [[ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]]; then
        echo "ERROR: Passwords do not match."
        exit 1
    fi
fi

# ---------- Helper ----------
check_status() {
    local response="$1"
    local step="$2"
    local status
    status=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    if [[ "$status" != "ok" ]]; then
        echo "ERROR at step '$step':"
        echo "$response"
        rm -f "$COOKIE_FILE"
        exit 1
    fi
}

# ---------- Step 1: Login ----------
echo ""
echo "[1/4] Logging in as '$ADMIN_USER' at $HOST..."
LOGIN_RESP=$(curl -k -s -c "$COOKIE_FILE" -X POST "${HOST}/api/v1/login" \
    -H "Content-Type: application/json" \
    -d "{\"user\":\"${ADMIN_USER}\",\"passwd\":\"${ADMIN_PASS}\"}")
check_status "$LOGIN_RESP" "login"
echo "      OK"

# ---------- Step 2: Create user ----------
echo "[2/4] Creating user '$NEW_USER'..."
CREATE_RESP=$(curl -k -s -b "$COOKIE_FILE" -X POST "${HOST}/api/v1/auth/adduser" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${NEW_USER}\"}")
check_status "$CREATE_RESP" "adduser"

IDEN=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['iden'])")
echo "      OK (iden: $IDEN)"

# ---------- Step 3: Set password ----------
echo "[3/4] Setting password..."
PASS_RESP=$(curl -k -s -b "$COOKIE_FILE" -X POST "${HOST}/api/v1/auth/password/${IDEN}" \
    -H "Content-Type: application/json" \
    -d "{\"passwd\":\"${NEW_PASS}\"}")
check_status "$PASS_RESP" "set password"
echo "      OK"

# ---------- Step 4: Grant admin (optional) ----------
if [[ "$GRANT_ADMIN" == true ]]; then
    echo "[4/4] Granting admin privileges..."
    ADMIN_RESP=$(curl -k -s -b "$COOKIE_FILE" -X POST "${HOST}/api/v1/auth/user/${IDEN}" \
        -H "Content-Type: application/json" \
        -d '{"admin":true}')
    check_status "$ADMIN_RESP" "grant admin"
    echo "      OK"
else
    echo "[4/4] Skipping admin (use -a / --admin to grant)."
fi

# ---------- Cleanup ----------
rm -f "$COOKIE_FILE"

echo ""
echo "Done! User '$NEW_USER' created successfully."
echo "  Host:  $HOST"
echo "  Admin: $GRANT_ADMIN"
echo ""
echo "Test login:"
echo "  curl -k -s -X POST ${HOST}/api/v1/login \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"user\":\"${NEW_USER}\",\"passwd\":\"<password>\"}'"