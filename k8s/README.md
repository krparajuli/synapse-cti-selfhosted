 Structure

  k8s/base/
  ├── kustomization.yaml          # Root — image tags, namespace, labels
  ├── namespace.yaml              # synapse namespace
  ├── aha/                        # Phase 1 — Service Discovery (no deps)
  │   ├── configmap.yaml
  │   ├── service.yaml
  │   └── statefulset.yaml
  ├── axon/                       # Phase 2 — Binary Storage (waits for AHA)
  │   ├── configmap.yaml
  │   ├── service.yaml
  │   └── statefulset.yaml
  ├── jsonstor/                   # Phase 2 — JSON Storage (waits for AHA)
  │   ├── configmap.yaml
  │   ├── service.yaml
  │   └── statefulset.yaml
  ├── cortex/                     # Phase 3 — Core Hypergraph (waits for AHA + Axon + JSONStor)
  │   ├── configmap.yaml
  │   ├── service.yaml
  │   └── statefulset.yaml
  └── optic/                      # Phase 4 — Web UI (waits for AHA + Cortex + Axon)
      ├── configmap.yaml
      ├── service.yaml
      └── statefulset.yaml

  Startup Order (enforced via init containers)
  ┌───────┬──────────┬────────────────────────┐
  │ Phase │ Service  │       Waits For        │
  ├───────┼──────────┼────────────────────────┤
  │ 1     │ AHA      │ Nothing — starts first │
  ├───────┼──────────┼────────────────────────┤
  │ 2     │ Axon     │ AHA                    │
  ├───────┼──────────┼────────────────────────┤
  │ 2     │ JSONStor │ AHA                    │
  ├───────┼──────────┼────────────────────────┤
  │ 3     │ Cortex   │ AHA, Axon, JSONStor    │
  ├───────┼──────────┼────────────────────────┤
  │ 4     │ Optic    │ AHA, Cortex, Axon      │
  └───────┴──────────┴────────────────────────┘
  Provisioning Workflow

  After deploying, you need to generate one-time provisioning URLs from AHA and store them as Secrets:

  # 1. Apply the base manifests (AHA will start first, others will wait)
  kubectl kustomize base/ | kubectl apply -f -

  # 2. Wait for AHA to be ready
  kubectl -n synapse wait --for=condition=ready pod/aha-0

  # 3. Generate provisioning URLs and create secrets
  for svc in axon jsonstor cortex optic; do
    URL=$(kubectl -n synapse exec aha-0 -- python -m synapse.tools.aha.provision.service "00.${svc}")
    KEY="SYN_$(echo $svc | tr 'a-z' 'A-Z')_AHA_PROVISION"
    kubectl -n synapse create secret generic "${svc}-provision" --from-literal="${KEY}=${URL}"
  done

  # 4. Restart the waiting pods to pick up the provisioning secrets
  kubectl -n synapse rollout restart statefulset axon jsonstor cortex optic

  Customization

  - Image tags: Change v2.x.x in kustomization.yaml to your desired version (e.g., v2.233.0)
  - Storage sizes: Override PVC sizes in an overlay
  - Optic hostname: Set SYN_OPTIC_NETLOC in optic/configmap.yaml to your public domain
  - Resource limits: Adjust per-service in each StatefulSet


# Discussion
Each service has two K8s Services because they serve different purposes:

  ClusterIP Service (e.g., aha) — provides a stable DNS name (aha.synapse.svc.cluster.local) with load balancing. This is what other services use to connect (e.g., the init containers' nc -z checks, and AHA URLs like aha://axon...).

  Headless Service (e.g., aha-headless, clusterIP: None) — required by StatefulSets. It gives each pod a unique, stable DNS identity like
  aha-0.aha-headless.synapse.svc.cluster.local. StatefulSets won't work without a headless service specified in serviceName.

  That said, for single-replica StatefulSets like these, you could simplify by using only the headless service for both purposes — the pod DNS
  name would still resolve.
