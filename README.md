# Causa RCA Installer

Deploys the full Causa RCA infrastructure stack onto a local [Kind](https://kind.sigs.k8s.io/) cluster **or an existing OpenShift cluster** in a single command.

## What gets installed

### Kind target

| Component | NodePort |
|---|---|
| Kubernetes MCP Server | 30000 |
| Causa Backend | 30001 |
| Jafra MCP Server | 30003 (Kind node only — not mapped to localhost) |
| Quarkus MCP Server | 30004 |
| Causa MCP Server | 30005 |
| PostgreSQL (pgvector) | — (ClusterIP) |
| Jafra Ecosystem (Controller + Analyzer + Agent) | — (internal) |

### OpenShift target

| Component | Access |
|---|---|
| Kubernetes MCP Server | OpenShift Route |
| Causa Backend | OpenShift Route |
| Jafra MCP Server | OpenShift Route |
| Quarkus MCP Server | OpenShift Route |
| Causa MCP Server | OpenShift Route |
| PostgreSQL (CNPG) | — (ClusterIP via CloudNativePG operator) |
| Jafra Ecosystem (Controller + Analyzer + Agent) | — (internal) |

## Prerequisites

### Kind

- [`docker`](https://docs.docker.com/get-docker/) **or** [`podman`](https://podman.io/getting-started/installation) (rootful mode)
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- [`helm`](https://helm.sh/docs/intro/install/)
- `curl`, `grep`, `sed`, `awk` — pre-installed on macOS and most Linux distributions

> **Podman users:** the Podman machine must be started in rootful mode (`podman machine init --rootful`).

### OpenShift

- [`oc`](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) (preferred) or `kubectl`
- [`helm`](https://helm.sh/docs/intro/install/)
- `curl`, `grep`, `sed`, `awk`
- An active `oc login` session against the target cluster

## Quickstart

```bash
git clone https://github.com/causaai/installer.git
cd installer

# Full install — provisions Kind cluster and all components
./install.sh

# Install onto an existing OpenShift cluster
./install.sh --target openshift

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
  enable_monitoring.sh        # OpenShift User Workload Monitoring (openshift only)
  install_cert_manager.sh     # cert-manager via Helm (kind only, required by Jafra)
  install_k8s_mcp.sh          # Kubernetes MCP Server
  install_jafra.sh            # Jafra Ecosystem (Controller + Analyzer + Agent)
  install_jafra_mcp.sh        # Jafra MCP Server
  install_quarkus_mcp.sh      # Quarkus MCP Server
  install_postgres.sh         # PostgreSQL + pgvector + secrets
  install_causa.sh            # Causa Backend
  install_causa_mcp.sh        # Causa MCP Server
manifests/
  k8s_mcp_server.yaml         # Kubernetes MCP Server (NodePort 30000)
  causa/                      # Causa Backend — kind (NodePort 30001)
  jafra/                      # Jafra Ecosystem (Controller, Analyzer, Agent)
  jafra_mcp/                  # Jafra MCP Server (NodePort 30003, Kind node only)
  quarkus_mcp/                # Quarkus MCP Server (NodePort 30004)
  causa_mcp/                  # Causa MCP Server (NodePort 30005)
  postgres/                   # PostgreSQL + pgvector (ClusterIP) / CNPG operator
  openshift/                  # OpenShift-specific manifests (Routes, CNPG, UWM, SCC)
```

## Documentation

| Doc | What's in it |
|---|---|
| [Installation Guide](docs/installation.md) | Full install steps, prerequisites, uninstall, reinstall |
| [Configuration](docs/configuration.md) | All CLI flags, env vars, image overrides, and defaults |
| [Architecture](docs/architecture.md) | How the installer works internally, component wiring |
| [Troubleshooting](docs/troubleshooting.md) | Status checks, log locations, common errors |

## Support

Open an issue or raise a PR against the `main` branch.
