# Architecture

How the Causa RCA Installer works internally.
For installation steps, see the [Installation Guide](installation.md).

## Overview

The installer is a modular Bash project. A single entry point orchestrates the deployment by delegating each component to its own dedicated script. No component script is aware of the others — all coordination happens in the main orchestrator.

```
install.sh                              ← entry point, orchestrates everything
lib/
  images.env                            ← default image tags, sourced at startup
  logging.sh                            ← logging utilities and spinner
  install_utils.sh                      ← shared helpers, exit codes, error handling
  validator.sh                          ← pre-flight checks (tools, container runtime, cluster)
  install_kind_cluster.sh               ← Kind cluster + local registry (kind only)
  install_prometheus.sh                 ← Prometheus Stack via Helm (kind only)
  enable_monitoring.sh                  ← OpenShift User Workload Monitoring (openshift only)
  install_cert_manager.sh               ← cert-manager via Helm (kind only, required by Jafra)
  install_k8s_mcp.sh                    ← Kubernetes MCP Server
  install_jafra.sh                      ← Jafra Ecosystem (Controller + Analyzer + Agent)
  install_jafra_mcp.sh                  ← Jafra MCP Server
  install_quarkus_mcp.sh                ← Quarkus MCP Server
  install_postgres.sh                   ← PostgreSQL + pgvector + Kubernetes secrets
  install_causa.sh                      ← Causa Backend
  install_causa_mcp.sh                  ← Causa MCP Server
manifests/
  k8s_mcp_server.yaml                   ← Kubernetes MCP Server (NodePort 30000)
  causa/deployment.yaml                 ← Causa Backend — kind (NodePort 30001)
  jafra/                                ← Jafra Controller, Analyzer, Agent
  jafra_mcp/deployment.yaml             ← Jafra MCP Server (NodePort 30003, Kind node only)
  quarkus_mcp/deployment.yaml           ← Quarkus MCP Server (NodePort 30004)
  causa_mcp/deployment.yaml             ← Causa MCP Server (NodePort 30005)
  postgres/                             ← PostgreSQL + pgvector (ClusterIP) / CNPG operator
  openshift/                            ← OpenShift-specific manifests (Routes, CNPG, UWM, SCC)
    causa-backend/                      ← Causa Backend for OpenShift (configmap, deployment, service, route, SA)
    jafra/                              ← Jafra Agent DaemonSet + SCC for OpenShift
    causa-mcp-route.yaml
    jafra-mcp-route.yaml
    kubernetes-mcp-server-route.yaml
    quarkus-mcp-route.yaml
    cluster-monitoring-config.yaml
```

## Startup sequence

When `install.sh` is run:

1. Loads default images from `lib/images.env`
2. Parses CLI arguments — flags override env vars which override `lib/images.env`
3. Initialises the log file
4. Runs pre-flight validation (container runtime, tools, cluster access)
5. Deploys components in sequence (see [Installation order](installation.md#installation-order))
6. Runs post-installation health check and prints the access summary

## Target platforms

### Kind

The installer provisions a local Kind cluster and local registry, installs Prometheus
(kube-prometheus-stack via Helm) and cert-manager, then deploys all application components.
Components are exposed via NodePort services, with selected ports mapped to `localhost` in the
Kind cluster config.

### OpenShift

The installer connects to an existing OpenShift cluster (using the current `oc`/`kubectl` context),
enables User Workload Monitoring, and deploys all application components.
No cluster provisioning, no Prometheus install (OpenShift provides UWM), no cert-manager install.
Components are exposed via OpenShift Routes instead of NodePorts.

## Image resolution

Every component image is resolved in this priority order:

```
CLI flag  >  exported env var  >  lib/images.env
```

`lib/images.env` uses `${VAR:-value}` syntax, so any value already exported in the environment before the script runs is preserved. There are no hardcoded image fallbacks in the component scripts — `lib/images.env` is the single source of truth.

## Container runtime detection (kind only)

The validator detects the available container runtime automatically:

1. Prefers **Podman** if `podman` is available and responding
2. Falls back to **Docker**, with a check to detect if `docker` is actually a Podman shim
3. Exports `CONTAINER_RUNTIME` (`docker` or `podman`) for use by the Kind cluster script

> Podman must run in **rootful mode** — rootless Podman is incompatible with Kind.

## PostgreSQL setup

### Kind

`install_postgres.sh` deploys two Kubernetes Secrets before starting the workload:

| Secret | Keys |
|---|---|
| `postgres-credentials` | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (used by the Pod) |
| `causa-db-secrets` | `CAUSA_DB_USERNAME`, `CAUSA_DB_PASSWORD`, `CAUSA_DB_URL` (read by Causa Backend) |

The pgvector extension is initialised at startup via a ConfigMap-mounted SQL script.

### OpenShift

`install_postgres.sh` installs the [CloudNativePG](https://cloudnative-pg.io/) operator via OLM
(OperatorHub subscription) then creates a `Cluster` CR (`iri-db`) with pgvector enabled.
Causa Backend reads credentials from the `causa-db-secrets` Secret created by CNPG.

## Causa Backend — MCP endpoint configuration

After the Causa Backend deployment becomes ready, `install_causa.sh` stamps three env vars
onto the running deployment using `kubectl set env` (idempotent — safe on every re-run):

| Env var | Value | Source |
|---|---|---|
| `CAUSA_MCP_QUARKUS_ENDPOINT` | `http://mcp-metrics.<ns>.svc.cluster.local:8080` | Derived from `INSTALL_NAMESPACE` |
| `CAUSA_MCP_QUARKUS_METRICS_BASE_URL` | user-supplied URL | `CAUSA_MCP_QUARKUS_METRICS_BASE_URL` env var (default: `""`) |
| `CAUSA_MCP_ASYNC_PROFILER_ENDPOINT` | `http://jafra-mcp.<ns>.svc.cluster.local:8083` | Derived from `INSTALL_NAMESPACE` |

`kubectl set env` triggers a new rollout. The installer then waits up to 180 s for
`kubectl rollout status deployment/causa-backend` to confirm the pods are running the
new configuration before proceeding.

## Manifest substitution

Each manifest contains placeholder tokens that are substituted at apply time using `sed`:

| Placeholder | Replaced with |
|---|---|
| `PLACEHOLDER_NAMESPACE` | `INSTALL_NAMESPACE` |
| `PLACEHOLDER_CLUSTER_TYPE` | `INSTALL_TARGET` (`kind` or `openshift`) |
| `PLACEHOLDER_QUARKUS_METRICS_BASE_URL` | `CAUSA_MCP_QUARKUS_METRICS_BASE_URL` (may be empty) |

The standard `apply_manifest` helper in `lib/install_utils.sh` handles `PLACEHOLDER_NAMESPACE`
and `PLACEHOLDER_CLUSTER_TYPE`. Manifests that also require `PLACEHOLDER_QUARKUS_METRICS_BASE_URL`
(the Causa Backend manifests) use an inline `sed` + temp-file approach in `install_causa.sh`
before calling `kubectl apply`.

## Optional components

The Jafra Ecosystem, Jafra MCP Server, and Quarkus MCP Server are deployed only when their
images are set in `lib/images.env`. If any required image variable is empty, the installer
skips that component with a warning rather than failing.
