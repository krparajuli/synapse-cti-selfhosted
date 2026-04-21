#!/usr/bin/env bash
# storm-commands.sh — Storm CLI reference for Synapse CTI (sheingroup.com deployment)
#
# Source this file to get helper functions:
#   source storm-commands.sh
#   syn_storm                    # open interactive Storm REPL
#   syn_run  '<query>'           # run a one-shot Storm query
#   syn_admin '<storm command>'  # run Storm as admin
#
# Or read it as a command reference and copy the examples you need.
#
# All commands use the ssl:// URL with explicit hostname and ca parameters —
# required because remote clients cannot use aha:// URLs across NAT.
# See section 8 of the deployment guide for the full explanation.

# ─── Configuration ────────────────────────────────────────────────────────────
# Override these with environment variables before sourcing, or edit defaults:
CORTEX_HOST="${CORTEX_HOST:-cortex.sheingroup.com}"
CORTEX_PORT="${CORTEX_PORT:-27495}"
CORTEX_HTTPS_PORT="${CORTEX_HTTPS_PORT:-4443}"
AHA_NETWORK="${AHA_NETWORK:-synapse}"
SYN_USER="${SYN_USER:-admin}"

# Constructed Storm URL
STORM_URL="ssl://${SYN_USER}@${CORTEX_HOST}:${CORTEX_PORT}?hostname=00.cortex.${AHA_NETWORK}&ca=${AHA_NETWORK}"

# ─── Helper functions ─────────────────────────────────────────────────────────

# Open interactive Storm REPL
syn_storm() {
  echo "Connecting to Cortex at ${CORTEX_HOST}:${CORTEX_PORT} as ${SYN_USER} ..."
  python3 -m synapse.tools.storm "${STORM_URL}" "$@"
}

# Run a single Storm query non-interactively
# Usage: syn_run '<storm query>'
syn_run() {
  local query="$1"
  python3 -m synapse.tools.storm "${STORM_URL}" <<< "${query}"
}

# Run Storm as a different user
# Usage: syn_as_user visi '<storm query>'
syn_as_user() {
  local user="$1"; local query="$2"
  local url="ssl://${user}@${CORTEX_HOST}:${CORTEX_PORT}?hostname=00.cortex.${AHA_NETWORK}&ca=${AHA_NETWORK}"
  python3 -m synapse.tools.storm "${url}" <<< "${query}"
}

echo "Storm helpers loaded. Cortex: ${STORM_URL}"
echo "Commands: syn_storm | syn_run '<query>' | syn_as_user <user> '<query>'"

# ─── ─────────────────────────────────────────────────────────────────────────
# STORM COMMAND REFERENCE
# All examples below can be pasted directly into the Storm REPL or passed
# to syn_run. Storm queries are executed server-side on the Cortex.
# ─── ─────────────────────────────────────────────────────────────────────────

: <<'STORM_REFERENCE'

══════════════════════════════════════════════════════════════
 CONNECTION
══════════════════════════════════════════════════════════════

# Interactive REPL (after client-setup.sh enrollment):
python3 -m synapse.tools.storm \
  "ssl://admin@cortex.sheingroup.com:27495?hostname=00.cortex.synapse&ca=synapse"

# One-shot query:
python3 -m synapse.tools.storm \
  "ssl://admin@cortex.sheingroup.com:27495?hostname=00.cortex.synapse&ca=synapse" \
  <<< '$lib.version'

# Cortex HTTPS REST API (browser or curl):
#   https://cortex.sheingroup.com:4443
#   curl -k -u admin:<password> https://cortex.sheingroup.com:4443/api/v1/auth/whoami


══════════════════════════════════════════════════════════════
 ADMIN — USER MANAGEMENT
══════════════════════════════════════════════════════════════

# List all users
auth.user.list

# Add a new standard user (non-admin)
auth.user.add analyst01

# Add a new admin user
auth.user.add analyst01
auth.user.mod analyst01 --admin true

# Set a password for a user (for HTTPS API login):
auth.user.mod analyst01 --passwd 'S3cur3Pass!'

# Revoke admin from a user:
auth.user.mod analyst01 --admin false

# Lock a user account:
auth.user.mod analyst01 --locked true

# Delete a user:
auth.user.del analyst01

# List roles:
auth.role.list

# Add a role:
auth.role.add readers

# Grant a rule to a role (e.g., read-only node access):
auth.role.mod readers --rule node.prop.get

# Add a user to a role:
auth.user.mod analyst01 --role readers


══════════════════════════════════════════════════════════════
 ADMIN — AHA USER ENROLLMENT (run from server)
══════════════════════════════════════════════════════════════

# Generate enrollment URL for a new user (run inside AHA container):
#   docker exec <aha-container> python -m synapse.tools.aha.provision.user <username>

# Client-side enrollment (run on client machine):
#   python3 -m synapse.tools.aha.enroll "ssl://aha.sheingroup.com:27272/<guid>?certhash=<sha256>"


══════════════════════════════════════════════════════════════
 CORTEX INFO + VERSION
══════════════════════════════════════════════════════════════

# Synapse version string
$lib.version

# Cell / Cortex info
$lib.cell.info()

# Current authenticated user
$lib.auth.whoami()

# List all layers (data partitions)
cortex.layer.list

# Cortex disk and memory stats
$lib.cell.statinfo()


══════════════════════════════════════════════════════════════
 NODE CREATION
══════════════════════════════════════════════════════════════

# Add a domain indicator
[ inet:fqdn=malicious.example.com ]

# Add an IP address
[ inet:ipv4=203.0.113.99 ]

# Add a URL
[ inet:url=http://malicious.example.com/payload.exe ]

# Add a file hash (sha256)
[ hash:sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]

# Add a DNS A record linking FQDN to IP
[ inet:dns:a=(malicious.example.com, 203.0.113.99) ]

# Tag a node with a threat label
inet:fqdn=malicious.example.com [ +#threat.apt.cobalt ]

# Add a node with secondary properties
[ inet:ipv4=203.0.113.99 :asn=64496 :loc=us ]


══════════════════════════════════════════════════════════════
 NODE QUERY + PIVOTING
══════════════════════════════════════════════════════════════

# Find a domain
inet:fqdn=malicious.example.com

# Find all IPs associated with a domain (pivot through DNS A records)
inet:fqdn=malicious.example.com -> inet:dns:a -> inet:ipv4

# Find all domains that resolve to a given IP
inet:ipv4=203.0.113.99 <- inet:dns:a -> inet:fqdn

# Find all nodes tagged with a threat actor
#threat.apt.cobalt

# Find all threat-tagged IPs
inet:ipv4 +#threat

# Count results
inet:fqdn | count

# Limit results
inet:fqdn | limit 10

# Sort by property
inet:ipv4 | sort :asn


══════════════════════════════════════════════════════════════
 TAGS
══════════════════════════════════════════════════════════════

# Tag nodes matching a query
inet:fqdn:zone=example.com [ +#threat.phishing ]

# Remove a tag
inet:fqdn=malicious.example.com [ -#threat.phishing ]

# List all tag trees
syn:tag | limit 50

# Find all nodes with a specific tag
#threat.apt | limit 20

# Find nodes tagged in a date range (tag timestamps)
#threat.apt@(2024-01-01, 2025-01-01)


══════════════════════════════════════════════════════════════
 LIGHT EDGES
══════════════════════════════════════════════════════════════

# Link two nodes with a light edge (non-typed relationship)
inet:fqdn=malicious.example.com -(refs)> inet:ipv4=203.0.113.99

# Traverse a light edge
inet:fqdn=malicious.example.com -(refs)> *

# Reverse light edge traversal
inet:ipv4=203.0.113.99 <(refs)- *


══════════════════════════════════════════════════════════════
 BULK IMPORT
══════════════════════════════════════════════════════════════

# Import a list of IPs from a variable
$ips = (("203.0.113.1", "203.0.113.2", "203.0.113.3"))
for $ip in $ips {
  [ inet:ipv4=$ip +#threat.bulk ]
}

# Import from a CSV file (using $lib.csv.rows):
// file: iocs.csv — columns: fqdn,tag
$rows = $lib.csv.rows($lib.bytes.get("axon://sha256:<hash>"))
for ($fqdn, $tag) in $rows {
  [ inet:fqdn=$fqdn +#$tag ]
}


══════════════════════════════════════════════════════════════
 EXPORT
══════════════════════════════════════════════════════════════

# Export all threat-tagged domains to JSON (via HTTPS API):
#   curl -k -u admin:<password> \
#     "https://cortex.sheingroup.com:4443/api/v1/storm" \
#     -X POST -H "Content-Type: application/json" \
#     -d '{"query": "inet:fqdn +#threat", "opts": {"repr": true}}'

# Print node values and tags
inet:fqdn +#threat { -> syn:tag | spin } | -> { $lib.print($node.repr()) }


══════════════════════════════════════════════════════════════
 CORTEX MAINTENANCE
══════════════════════════════════════════════════════════════

# Trim the Nexus log (run before backups — standalone Cortex, no mirrors):
$lib.cell.trimNexsLog()

# Check free disk space:
$lib.cell.statinfo() | -> { $lib.print($node) }

# Run a live backup to Axon:
$lib.backup.run()

STORM_REFERENCE
