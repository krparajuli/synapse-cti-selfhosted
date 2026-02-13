#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="synapse"
AHA_POD="aha-0"
AHA_SERVICE="aha.synapse.svc.cluster.local:27272"

echo "Generating fresh AHA provisioning URLs..."

# Function to generate provisioning URL
gen_url () {
  SERVICE_NAME="$1"
  kubectl exec -n ${NAMESPACE} ${AHA_POD} -- \
    python -m synapse.tools.aha.provision.service ${SERVICE_NAME} 2>&1 \
    | grep "one-time use URL:" \
    | awk '{print $4}'
}

AXON_URL=$(gen_url 00.axon)
JSONSTOR_URL=$(gen_url 00.jsonstor)
CORTEX_URL=$(gen_url 00.cortex)
OPTIC_URL=$(gen_url 00.optic)

echo "AXON_URL=$AXON_URL"
echo "JSONSTOR_URL=$JSONSTOR_URL"
echo "CORTEX_URL=$CORTEX_URL"
echo "OPTIC_URL=$OPTIC_URL"

echo "Provisioning URLs generated."

echo "Creating/updating Kubernetes secrets..."

# Function to recreate secret safely
create_secret () {
  NAME="$1"
  KEY="$2"
  VALUE="$3"

  kubectl -n ${NAMESPACE} delete secret ${NAME} --ignore-not-found
  kubectl -n ${NAMESPACE} create secret generic ${NAME} \
    --from-literal="${KEY}=${VALUE}"
}

create_secret axon-provision     SYN_AXON_AHA_PROVISION $AXON_URL
create_secret jsonstor-provision SYN_JSONSTOR_AHA_PROVISION $JSONSTOR_URL
create_secret cortex-provision   SYN_CORTEX_AHA_PROVISION $CORTEX_URL
create_secret optic-provision    SYN_OPTIC_AHA_PROVISION $OPTIC_URL

echo "Secrets created."

echo "Force restarting service pods..."

kubectl -n ${NAMESPACE} delete pod \
  axon-0 jsonstor-0 cortex-0 optic-0 \
  --grace-period=0 --force

echo "Done. Pods restarting with fresh provisioning."

