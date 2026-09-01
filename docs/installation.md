# Installation Guide

Full installation reference for the Causa RCA Installer.
For a quick start, see the [README](../README.md).

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| `docker` or `podman` | Container runtime for Kind | [docker](https://docs.docker.com/get-docker/) / [podman](https://podman.io/getting-started/installation) |
| `kind` | Local Kubernetes cluster | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| `kubectl` | Kubernetes CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Prometheus Stack install | [helm.sh](https://helm.sh/docs/intro/install/) |
| `curl`, `grep`, `sed`, `awk` | Script utilities | Pre-installed on macOS and most Linux distributions |

> **Podman users:** Kind requires rootful mode. Initialise the machine with:
> ```bash
> podman machine init --rootful --cpus 4 --memory 4096
> podman machine start
> ```

## Default installation

Provisions a Kind cluster and deploys all components into the `causa-rca` namespace.

```bash
git clone https://github.com/causaai/installer.git
cd installer
./install.sh
```

## Custom namespace

```bash
./install.sh -n my-namespace
```

## Setting the target Quarkus app URL

The Causa Backend connects to the Quarkus application under analysis via
`CAUSA_MCP_QUARKUS_METRICS_BASE_URL`. Set this before running the installer when
you have a known target:

```bash
export CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
./install.sh
```

If you leave it unset, the installer stamps an empty value that can be updated at any time:

```bash
# Replace causa-rca with your installation namespace if you used -n
kubectl set env deployment/causa-backend -n causa-rca \
  CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
```

## Dry run

Validates prerequisites and configuration without making any cluster changes:

```bash
./install.sh --dry-run
```

## View all flags

```bash
./install.sh --help
```

See [Configuration](configuration.md) for the full reference.

## Installation order

Components are deployed in this sequence:

1. Kind cluster + local registry
2. Prometheus Stack (kube-prometheus-stack, `monitoring` namespace)
3. cert-manager (installed from official release manifest via `kubectl apply -f`, required by Jafra Controller webhook TLS)
4. Kubernetes MCP Server
5. Jafra Ecosystem (Controller → Analyzer → Agent) _(skipped if images not set)_
6. Jafra MCP Server _(skipped if image not set)_
7. Quarkus MCP Server _(skipped if image not set)_
8. PostgreSQL + pgvector
9. Causa Backend _(stamps MCP env vars + waits for rollout)_
10. Causa MCP Server

## Uninstallation

Removes all components in reverse order. The Kind cluster is preserved by default.

```bash
# Remove all components, keep cluster
./install.sh --terminate

# Remove all components and delete the cluster
./install.sh --terminate --delete-cluster
```

> Always pass the same `-n` and `--cluster-name` flags during uninstallation that you used during installation.

## Re-installation

Uninstall first, then install again:

```bash
./install.sh --terminate
./install.sh
```

## Logs

Installation activity is written to `install.log` in the same directory as the script.

```bash
cat install.log
```
