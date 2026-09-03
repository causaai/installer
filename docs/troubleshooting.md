# Troubleshooting

Common issues and status checks for the Causa RCA stack.
For installation steps, see the [Installation Guide](installation.md).

## Check overall status

```bash
# List all pods
kubectl get pods -n causa-rca

# Watch pod status in real time
kubectl get pods -n causa-rca -w
```

## Component-specific checks

### Kubernetes MCP Server

```bash
kubectl get pods -n causa-rca -l app=kubernetes-mcp-server
kubectl logs -n causa-rca -l app=kubernetes-mcp-server
```

### Causa Backend

```bash
kubectl get pods -n causa-rca -l app=causa-backend
kubectl logs -n causa-rca -l app=causa-backend

# Verify MCP env vars were stamped correctly
kubectl set env deployment/causa-backend -n causa-rca --list | grep CAUSA_MCP

# Health check (Kind — NodePort)
curl http://localhost:30001/q/health/ready

# Health check (OpenShift — via Route)
curl https://$(oc get route causa-backend -n causa-rca -o jsonpath='{.spec.host}')/q/health/ready
```

### Quarkus MCP Server

```bash
kubectl get pods -n causa-rca -l app=mcp-metrics
kubectl logs -n causa-rca -l app=mcp-metrics
```

### Causa MCP Server

```bash
kubectl get pods -n causa-rca -l app=causa-mcp
kubectl logs -n causa-rca -l app=causa-mcp
```

### PostgreSQL

```bash
# Kind
kubectl get pods -n causa-rca -l app=postgres
kubectl logs -n causa-rca -l app=postgres

# Verify secrets exist
kubectl get secret causa-db-secrets -n causa-rca
kubectl get secret postgres-credentials -n causa-rca

# OpenShift (CloudNativePG)
oc get cluster.postgresql.cnpg.io iri-db -n causa-rca
oc get pods -n causa-rca -l cnpg.io/cluster=iri-db
oc get secret causa-db-secrets -n causa-rca
```

### Jafra Ecosystem (Kind only)

```bash
# Controller
kubectl get pods -n causa-rca -l app=jafra-controller
kubectl logs -n causa-rca -l app=jafra-controller

# Analyzer
kubectl get pods -n causa-rca -l app=jafra-analyzer
kubectl logs -n causa-rca -l app=jafra-analyzer

# Agent (DaemonSet)
kubectl get pods -n causa-rca -l app=jafra-agent
kubectl logs -n causa-rca -l app=jafra-agent
```

### Jafra MCP Server (Kind only)

```bash
kubectl get pods -n causa-rca -l app=jafra-mcp
kubectl logs -n causa-rca -l app=jafra-mcp
```

### Kind cluster

```bash
kind get clusters
kubectl cluster-info --context kind-causa-rca
kubectl get nodes
```

### OpenShift monitoring

```bash
# Check User Workload Monitoring is enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml

# Check UWM Prometheus is running
oc get pods -n openshift-user-workload-monitoring

# Check which Alertmanager topology is present
oc get statefulset alertmanager-user-workload -n openshift-user-workload-monitoring 2>/dev/null \
  && echo "Topology A: UWM Alertmanager" || echo "Topology B: platform Alertmanager only"

# Verify causa-webhook is configured (Topology A)
oc get secret alertmanager-user-workload -n openshift-user-workload-monitoring \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep causa-webhook

# Verify causa-webhook is configured (Topology B)
oc get secret alertmanager-main -n openshift-monitoring \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep causa-webhook

# Check PrometheusRule
oc get prometheusrule -n causa-rca
```

## Common errors

### Prerequisites missing

The installer checks for required CLI tools before doing anything. Install any missing tools and rerun. OpenShift Alertmanager Topology B additionally requires `python3` with the `yaml` module — the installer does not check for this and will fail mid-run if it is absent; install it before running.

**Kind:** `kubectl`, `docker`/`podman`, `kind`, `helm`, `curl`, `grep`, `sed`, `awk`

**OpenShift:** `oc` (or `kubectl`), `curl`, `grep`, `sed`, `awk`, `python3`

```bash
# kind — macOS
brew install kind
# or see https://kind.sigs.k8s.io/docs/user/quick-start/#installation

# helm
brew install helm
# or see https://helm.sh/docs/intro/install/

# PyYAML (required for OpenShift Alertmanager merge)
pip3 install pyyaml
```

### Container runtime not running (Kind only)

```bash
# Docker — macOS: start Docker Desktop from the menu bar
# Docker — Linux
sudo systemctl start docker

# Podman — start the machine
podman machine start
```

### Podman rootless mode (Kind only)

Kind requires rootful Podman. Recreate the machine with rootful mode:

```bash
podman machine stop
podman machine rm
podman machine init --rootful --cpus 4 --memory 4096
podman machine start
```

### Cluster not reachable

```bash
# Kind — verify the cluster exists
kind get clusters

# Kind — switch to the correct context
kubectl config use-context kind-causa-rca

# Kind — recreate if needed
kind delete cluster --name causa-rca
./install.sh

# OpenShift — verify you are logged in
oc whoami
oc login <api-url> --token=<token>
```

### cert-manager not installed

**Kind:** cert-manager is installed automatically by the installer in step 3 (required by the Jafra Controller webhook). If it fails to become ready, check its pods:

```bash
# Check cert-manager pod status
kubectl get pods -n cert-manager

# Check for events indicating why it's not ready
kubectl describe pods -n cert-manager
kubectl get events -n cert-manager --sort-by='.lastTimestamp'

# Check rollout status
kubectl rollout status deployment/cert-manager -n cert-manager
kubectl rollout status deployment/cert-manager-webhook -n cert-manager
```

If the webhook pod is stuck, delete it to force a restart:

```bash
kubectl delete pod -n cert-manager -l app=cert-manager-webhook
```

**OpenShift:** cert-manager must be pre-installed before running the installer. If the pre-flight check fails:

```bash
# Verify cert-manager pods
oc get pods -A | grep cert-manager

# Install if missing
oc apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for it to be ready
oc rollout status deployment/cert-manager -n cert-manager
oc rollout status deployment/cert-manager-webhook -n cert-manager
```

### Insufficient permissions for Alertmanager (OpenShift Topology B)

Patching `alertmanager-main` in `openshift-monitoring` requires cluster-admin.

```bash
# Re-run after logging in with a cluster-admin account
oc login --username=<admin-user> --server=<api-url>
./install.sh --target openshift
```

### Ports already in use — 30000, 30001, 30004, 30005 (Kind only)

The pre-flight check verifies the required host ports are free before installing. Which ports
are checked depends on the port's role:

**Which ports are checked, and when**

| Port  | Service        | Role                           | When it's checked    |
|-------|----------------|-------------------------------|----------------------|
| 30000 | Kubernetes MCP | NodePort mapped to `localhost` | New cluster only     |
| 30001 | Causa Backend  | NodePort mapped to `localhost` | New cluster only     |
| 30004 | Quarkus MCP    | NodePort mapped to `localhost` | New cluster only     |
| 30005 | Causa MCP      | NodePort mapped to `localhost` | New cluster only     |
| 30003 | Jafra MCP      | NodePort, in-cluster only      | Never                |

After deleting a Kind cluster, gvproxy (Podman/Docker network proxy) may still hold the host port bindings.

```bash
# Option 1 — restart the container runtime
podman machine stop && podman machine start
# or restart Docker Desktop

# Option 2 — reuse the existing cluster (installer is idempotent)
./install.sh
```

### Pod stuck in `Pending`

Usually a resource or scheduling issue on the node.

```bash
kubectl describe pod -n causa-rca <pod-name>
kubectl get events -n causa-rca --sort-by='.lastTimestamp'
```

### PostgreSQL not ready

**Kind:**
```bash
kubectl get pods -n causa-rca -l app=postgres
kubectl describe pod -n causa-rca -l app=postgres
kubectl get secret postgres-credentials -n causa-rca
```

**OpenShift (CloudNativePG):**
```bash
# Check cluster phase
oc get cluster.postgresql.cnpg.io iri-db -n causa-rca -o jsonpath='{.status.phase}'

# Check CNPG operator is running
oc get pods -A | grep cnpg

# Check the CNPG subscription
oc get subscription cloudnative-pg -n causa-rca
```

### Causa Backend env vars not set

After install, verify the MCP endpoint env vars were stamped:

```bash
kubectl set env deployment/causa-backend -n causa-rca --list | grep CAUSA_MCP
```

Expected output:
```
CAUSA_MCP_QUARKUS_ENDPOINT=http://mcp-metrics.causa-rca.svc.cluster.local:8080
CAUSA_MCP_QUARKUS_METRICS_BASE_URL=<your value or empty>
CAUSA_MCP_ASYNC_PROFILER_ENDPOINT=http://jafra-mcp.causa-rca.svc.cluster.local:8083
```

To update `CAUSA_MCP_QUARKUS_METRICS_BASE_URL` after install:

```bash
kubectl set env deployment/causa-backend -n causa-rca \
  CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"

# Wait for rollout
kubectl rollout status deployment/causa-backend -n causa-rca --timeout=180s
```

### Causa Backend rollout stuck after env var update

```bash
# Check pod events
kubectl describe pods -n causa-rca -l app=causa-backend

# Check readiness/liveness probe failures
kubectl logs -n causa-rca -l app=causa-backend --previous
```

## Logs

The full installation log is written to `install.log` in the same directory as the script.

```bash
cat install.log
```
