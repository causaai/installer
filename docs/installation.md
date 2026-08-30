# Installation Guide

Full installation reference for the Causa RCA Installer.
For a quick start, see the [README](../README.md).

## Prerequisites

### Kind

| Tool | Purpose | Install |
|---|---|---|
| `docker` or `podman` | Container runtime for Kind | [docker](https://docs.docker.com/get-docker/) / [podman](https://podman.io/getting-started/installation) |
| `kind` | Local Kubernetes cluster | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| `kubectl` | Kubernetes CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Prometheus Stack and cert-manager install | [helm.sh](https://helm.sh/docs/intro/install/) |
| `curl`, `grep`, `sed`, `awk` | Script utilities | Pre-installed on macOS and most Linux distributions |

> **Podman users:** Kind requires rootful mode. Initialise the machine with:
> ```bash
> podman machine init --rootful --cpus 4 --memory 4096
> podman machine start
> ```

### OpenShift

| Tool | Purpose | Install |
|---|---|---|
| `oc` (preferred) or `kubectl` | OpenShift / Kubernetes CLI | [openshift docs](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) / [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Kubernetes MCP Server install | [helm.sh](https://helm.sh/docs/intro/install/) |
| `curl`, `grep`, `sed`, `awk` | Script utilities | Pre-installed on macOS and most Linux distributions |

You must be logged in before running the installer:

```bash
oc login <api-url> --token=<token>
# or
oc login <api-url> -u <user> -p <password>
```

## Default installation (Kind)

Provisions a Kind cluster and deploys all components into the `causa-rca` namespace.

```bash
git clone https://github.com/causaai/installer.git
cd installer
./install.sh
```

## OpenShift installation

Deploys all components into the `causa-rca` namespace on an existing OpenShift cluster.
No cluster provisioning, no Prometheus install, no cert-manager install — OpenShift provides these out of the box.

```bash
./install.sh --target openshift
```

## Custom namespace

```bash
# Kind
./install.sh -n my-namespace

# OpenShift
./install.sh --target openshift -n my-namespace
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
kubectl set env deployment/causa-backend -n causa-rca \
  CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
```

## Dry run

Validates prerequisites and configuration without making any cluster changes:

```bash
./install.sh --dry-run
./install.sh --target openshift --dry-run
```

## View all flags

```bash
./install.sh --help
```

See [Configuration](configuration.md) for the full reference.

## Installation order

### Kind

Components are deployed in this sequence:

1. Kind cluster + local registry
2. Prometheus Stack (kube-prometheus-stack, `monitoring` namespace)
3. cert-manager (required by Jafra Controller webhook TLS)
4. Kubernetes MCP Server
5. Jafra Ecosystem (Controller → Analyzer → Agent) _(skipped if images not set)_
6. Jafra MCP Server _(skipped if image not set)_
7. Quarkus MCP Server _(skipped if image not set)_
8. PostgreSQL + pgvector
9. Causa Backend _(stamps MCP env vars + waits for rollout)_
10. Causa MCP Server

### OpenShift

Components are deployed in this sequence:

1. User Workload Monitoring enabled (Prometheus alerts wired to Causa)
2. Kubernetes MCP Server
3. Jafra Ecosystem (Controller → Analyzer → Agent) _(skipped if images not set)_
4. Jafra MCP Server _(skipped if image not set)_
5. Quarkus MCP Server _(skipped if image not set)_
6. PostgreSQL (CloudNativePG operator + Cluster)
7. Causa Backend _(stamps MCP env vars + waits for rollout)_
8. Causa MCP Server

> On OpenShift, cert-manager is not installed — Jafra Controller uses a pre-existing cluster CA or a self-signed cert managed via OpenShift's built-in certificate infrastructure.

## Uninstallation

Removes all components in reverse order. The Kind cluster is preserved by default.

```bash
# Remove all components, keep cluster (Kind)
./install.sh --terminate

# Remove all components and delete the cluster (Kind)
./install.sh --terminate --delete-cluster

# Remove all components from OpenShift
./install.sh --target openshift --terminate
```

> Always pass the same `--target` and `-n` flags during uninstallation that you used during installation.

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
