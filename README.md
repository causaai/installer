# Causa RCA Installer

Deploys the full Causa RCA infrastructure stack onto a local [Kind](https://kind.sigs.k8s.io/) cluster in a single command.

## What gets installed

| Component | Service type | Host access |
|---|---|---|
| Kubernetes MCP Server | NodePort | `localhost:30000` |
| Causa Backend | ClusterIP | `kubectl port-forward svc/causa-backend 30001:8080` |
| Jafra MCP Server | NodePort | Kind node only — not mapped to localhost (30003) |
| Quarkus MCP Server | NodePort | `localhost:30004` |
| Causa MCP Server | ClusterIP | `kubectl port-forward svc/causa-mcp 30005:8081` |
| PostgreSQL (pgvector) | ClusterIP | — (internal) |
| Jafra Ecosystem (Controller + Analyzer + Agent) | ClusterIP | — (internal) |

> **Causa Backend & Causa MCP Server** are exposed as `ClusterIP` services (not NodePorts).
> Reach them from the host with `kubectl port-forward` in the target namespace, e.g.:
>
> ```bash
> # Replace causa-rca with your installation namespace if you used -n
> kubectl port-forward svc/causa-backend 30001:8080 -n causa-rca
> kubectl port-forward svc/causa-mcp 30005:8081 -n causa-rca
> ```

## Prerequisites

- [`docker`](https://docs.docker.com/get-docker/) **or** [`podman`](https://podman.io/getting-started/installation) (rootful mode)
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- [`helm`](https://helm.sh/docs/intro/install/) — required only for the Prometheus Stack; cert-manager is installed from the official release manifest with `kubectl apply -f`
- `curl`, `grep`, `sed`, `awk` — pre-installed on macOS and most Linux distributions

> **Podman users:** the Podman machine must be started in rootful mode (`podman machine init --rootful`).

## Quickstart

```bash
git clone https://github.com/causaai/installer.git
cd installer

# Full install — provisions Kind cluster and all components
./install.sh

# Dry run — validate prerequisites without making changes
./install.sh --dry-run

# Uninstall everything
./install.sh --terminate

# View all CLI flags
./install.sh --help
```

## Target Quarkus app (Quarkus MCP metrics)

The Causa Backend needs to know the URL of the Quarkus application being profiled.
Set this before running the installer if you have a known target app:

```bash
export CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
./install.sh
```

If not set, the installer leaves this value empty — it can be updated later via:

```bash
# Replace causa-rca with your installation namespace if you used -n
kubectl set env deployment/causa-backend -n causa-rca \
  CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
```

## Repo layout

```
install.sh          # Entry point — orchestrates all components
lib/
  images.env                  # Default image tags (single source of truth)
  logging.sh                  # Logging helpers and spinner
  install_utils.sh            # Shared helpers, manifest apply/delete, exit codes
  validator.sh                # Pre-flight checks: CLI tools, container runtime, cluster
  install_kind_cluster.sh     # Kind cluster + local registry (kind only)
  install_prometheus.sh       # Prometheus Stack via Helm (kind only)
  install_cert_manager.sh     # cert-manager via official release manifest (kind only, required by Jafra)
  install_k8s_mcp.sh          # Kubernetes MCP Server
  install_jafra.sh            # Jafra Ecosystem (Controller + Analyzer + Agent)
  install_jafra_mcp.sh        # Jafra MCP Server
  install_quarkus_mcp.sh      # Quarkus MCP Server
  install_postgres.sh         # PostgreSQL + pgvector + secrets
  install_causa.sh            # Causa Backend
  install_causa_mcp.sh        # Causa MCP Server
manifests/
  k8s_mcp_server.yaml         # Kubernetes MCP Server (NodePort 30000)
  causa/                      # Causa Backend (ClusterIP, port-forward 30001:8080)
  jafra/                      # Jafra Ecosystem (Controller, Analyzer, Agent)
  jafra_mcp/                  # Jafra MCP Server (NodePort 30003, Kind node only)
  quarkus_mcp/                # Quarkus MCP Server (NodePort 30004)
  causa_mcp/                  # Causa MCP Server (ClusterIP, port-forward 30005:8081)
  postgres/                   # PostgreSQL + pgvector (ClusterIP)
```

## Documentation

| Doc | What's in it |
|---|---|
| [Installation Guide](docs/installation.md) | Full install steps, prerequisites, uninstall, reinstall |
| [Configuration](docs/configuration.md) | All CLI flags, env vars, image overrides, and defaults |
| [Architecture](docs/architecture.md) | How the installer works internally, component wiring |
| [Troubleshooting](docs/troubleshooting.md) | Status checks, log locations, common errors |

## Support

Open an issue or raise a PR against the `mvp_demo` branch.
