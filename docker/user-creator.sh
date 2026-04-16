#!/bin/bash
# create_user.sh — Create a Synapse user with optional admin and AHA cert provisioning
# Usage: ./create_user.sh <username> [--admin]

set -e

CORTEX_CONTAINER="docker-cortex-1"
AHA_CONTAINER="docker-aha-1"
CORTEX_STORAGE="cell:///vertex/storage"

# --- Argument parsing ---
USERNAME="$1"
ADMIN=false

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username> [--admin]"
    exit 1
fi

if [[ "$2" == "--admin" ]]; then
    ADMIN=true
fi

# --- Prompt for password ---
read -s -p "Enter password for '$USERNAME': " PASSWORD
echo
read -s -p "Confirm password: " PASSWORD_CONFIRM
echo

if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo "ERROR: Passwords do not match."
    exit 1
fi

# --- Step 1: Create user on Cortex ---
echo ""
echo "[1/3] Creating user '$USERNAME' on Cortex..."
docker exec "$CORTEX_CONTAINER" python -m synapse.tools.storm "$CORTEX_STORAGE" \
    "\$user=\$lib.auth.users.byname(${USERNAME}) if (\$user = \$lib.null) { \$user=\$lib.auth.users.add(${USERNAME}) \$lib.print('created') } else { \$lib.print('already exists') } \$user.setPasswd(\"${PASSWORD}\")"

# --- Step 2: Grant admin if requested ---
if [[ "$ADMIN" == true ]]; then
    echo ""
    echo "[2/3] Granting admin privileges to '$USERNAME'..."
    docker exec "$CORTEX_CONTAINER" python -m synapse.tools.storm "$CORTEX_STORAGE" \
        "\$user=\$lib.auth.users.byname(${USERNAME}) \$user.setAdmin(\$lib.true) \$lib.print('admin granted')"
else
    echo "[2/3] Skipping admin (pass --admin to grant admin privileges)."
fi

# --- Step 3: Provision AHA cert ---
echo ""
echo "[3/3] Generating AHA telepath cert for '$USERNAME'..."
echo "      Share this one-time URL with the user to run: python -m synapse.tools.aha.enroll <url>"
echo ""
docker exec "$AHA_CONTAINER" python -m synapse.tools.aha.provision.user "$USERNAME"

echo ""
echo "Done! User '$USERNAME' created."
echo "  HTTPS login: https://localhost:4443/api/v1/login"
echo "  Telepath:    aha://${USERNAME}@cortex..."
echo "  Admin:       $ADMIN"
