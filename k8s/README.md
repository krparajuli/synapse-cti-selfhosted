# Synapse K8s
**Synapse Optic will not work unless you have a subscription**


  After deploying, you need to generate one-time provisioning URLs from AHA and store them as Secrets:

  # 1. Apply the base manifests (AHA will start first, others will wait)
  kubectl kustomize base/ | kubectl apply -f -

  # 2. Wait for AHA to be ready
  kubectl -n synapse wait --for=condition=ready pod/aha-0

  # 3. Generate provisioning URLs and create secrets
  ```bash
  for svc in axon jsonstor cortex optic; do
    URL=$(kubectl -n synapse exec aha-0 -- python -m synapse.tools.aha.provision.service "00.${svc}")
    KEY="SYN_$(echo $svc | tr 'a-z' 'A-Z')_AHA_PROVISION"
    kubectl -n synapse create secret generic "${svc}-provision" --from-literal="${KEY}=${URL}"
  done
```
  # 4. Restart the waiting pods to pick up the provisioning secrets
  kubectl -n synapse rollout restart statefulset axon jsonstor cortex optic

  Customization

  - Image tags: Change v2.x.x in kustomization.yaml to your desired version (e.g., v2.233.0)
  - Storage sizes: Override PVC sizes in an overlay
  - Optic hostname: Set SYN_OPTIC_NETLOC in optic/configmap.yaml to your public domain
  - Resource limits: Adjust per-service in each StatefulSet

