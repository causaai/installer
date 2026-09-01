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

# Health check (requires NodePort access)
curl http://localhost:30001/q/health/ready
```

### Jafra Ecosystem

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

### Jafra MCP Server

```bash
kubectl get pods -n causa-rca -l app=jafra-mcp
kubectl logs -n causa-rca -l app=jafra-mcp
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
kubectl get pods -n causa-rca -l app=postgres
kubectl logs -n causa-rca -l app=postgres

# Verify secrets exist
kubectl get secret causa-db-secrets -n causa-rca
kubectl get secret postgres-credentials -n causa-rca
```

### Kind cluster

```bash
kind get clusters
kubectl cluster-info --context kind-causa-rca
kubectl get nodes
```

## Common errors

### Prerequisites missing

The installer checks for `kubectl`, `docker`/`podman`, `kind`, `helm`, `curl`, `grep`, `sed`, and `awk` before doing anything. Install any missing tools and rerun.

```bash
# kind — macOS
brew install kind
# or see https://kind.sigs.k8s.io/docs/user/quick-start/#installation

# helm
brew install helm
# or see https://helm.sh/docs/intro/install/
```

### Container runtime not running

```bash
# Docker — macOS: start Docker Desktop from the menu bar
# Docker — Linux
sudo systemctl start docker

# Podman — start the machine
podman machine start
```

### Podman rootless mode

Kind requires rootful Podman. Recreate the machine with rootful mode:

```bash
podman machine stop
podman machine rm
podman machine init --rootful --cpus 4 --memory 4096
podman machine start
```

### Cluster not reachable

```bash
# Verify the cluster exists
kind get clusters

# Switch to the correct context
kubectl config use-context kind-causa-rca

# Recreate if needed
kind delete cluster --name causa-rca
./install.sh
```

### Ports already in use — 30000, 30001, 30004, 30005

After deleting a Kind cluster, gvproxy (Podman/Docker network proxy) may still hold the host port bindings.
These are the four ports mapped to `localhost` in the Kind cluster config. Port 30003 (Jafra MCP) is a
NodePort inside the cluster only and is not bound on the host.

```bash
# Option 1 — restart the container runtime
podman machine stop && podman machine start
# or restart Docker Desktop

# Option 2 — reuse the existing cluster (installer is idempotent)
./install.sh
```

### Pod stuck in `Pending`

Usually a resource or scheduling issue on the Kind node.

```bash
kubectl describe pod -n causa-rca <pod-name>
kubectl get events -n causa-rca --sort-by='.lastTimestamp'
```

### PostgreSQL not ready

The Causa Backend waits for PostgreSQL before starting. Check:

```bash
kubectl get pods -n causa-rca -l app=postgres
kubectl describe pod -n causa-rca -l app=postgres

# Ensure the secret was created
kubectl get secret postgres-credentials -n causa-rca
```

### Causa Backend env vars not set

After install, verify the three MCP endpoint env vars were stamped:

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

### Jafra cert-manager not ready

The Jafra Controller requires cert-manager. If it fails:

```bash
kubectl get pods -n cert-manager
kubectl rollout status deployment/cert-manager -n cert-manager
kubectl rollout status deployment/cert-manager-webhook -n cert-manager
```

## Logs

The full installation log is written to `install.log` in the same directory as the script.

```bash
cat install.log
```
