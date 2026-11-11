# Adding a new component

How to add a deployable component to the installer. A component is a **module**: one entry in [`modules.json`](../modules.json) and one library in `lib/`. `install.sh` and `lib/validator.sh` are not edited.

For how modules are ordered and run, see [Module registry](architecture.md#module-registry-modulesjson) and [Wave architecture](architecture.md#wave-architecture).

## What to change

### Always

| # | File | Change |
|---|---|---|
| 1 | `manifests/<name>/` | Add the manifests. Use `PLACEHOLDER_NAMESPACE` for the namespace |
| 2 | `lib/install_<name>.sh` | Add the install and uninstall functions, plus an optional `<id>_health` |
| 3 | `modules.json` | Add one registry entry |
| 4 | `lib/images.env` | Add one image entry, only if the component has an image |

Waves, parallel install, the target filter, reverse-order uninstall, health checks, the install summary and the `--<name>-image` flag are all derived from these files.

### Only when it applies

| Situation | What to change |
|---|---|
| **Causa should call the new MCP server** | Add an entry to `manifests/causa/mcp.json`, and to `manifests/openshift/causa/mcp.json` if the module runs on OpenShift. Nothing generates these files from `modules.json`. See [Register with Causa MCP](#step-5-register-with-causa-mcp-mcp-servers-only) |
| **It needs a Kind host port (NodePort)** | Pick a port that is not already used, and edit the port lists in `lib/install_kind_cluster.sh` if it must be reachable from the host |
| **It needs setup before any module runs** | Cluster-level setup stays in `install.sh`: the Kind cluster, cert-manager and OpenShift monitoring. A module library cannot do this |
| **Its dependency differs by target** | `depends_on` is one flat list. Give the dependency the right `targets`, and the runner ignores it where it does not apply. See [Dependencies and waves](#dependencies-and-waves) |

## Example: a module called `demo`

The steps below add `demo`, which deploys a single Deployment. Replace `demo` and `Demo` with your component's name.

### Step 1: Add the manifest

Create `manifests/demo/deployment.yaml`. `apply_manifest` replaces `PLACEHOLDER_NAMESPACE` with `INSTALL_NAMESPACE` and `PLACEHOLDER_CLUSTER_TYPE` with the target (`kind` or `openshift`).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
  namespace: PLACEHOLDER_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo
  template:
    metadata:
      labels:
        app: demo
    spec:
      containers:
        - name: demo
          image: quay.io/example/demo:0.0.1   # replaced by DEMO_IMAGE
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
```

### Step 2: Add the library

Create `lib/install_demo.sh`. It follows the same layout as [`lib/install_k8s_mcp.sh`](../lib/install_k8s_mcp.sh).

```bash
#!/usr/bin/env bash

################################################################################
# Demo — Installation Functions
################################################################################

# Source guard
if [[ -n "${INSTALL_DEMO_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_DEMO_LIB_LOADED=1

# Safe defaults so the library can be sourced standalone
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-causa-rca}"
KUBE_CLI="${KUBE_CLI:-kubectl}"
DRY_RUN="${DRY_RUN:-false}"
DEMO_IMAGE="${DEMO_IMAGE:-}"
export SCRIPT_DIR INSTALL_NAMESPACE KUBE_CLI DRY_RUN DEMO_IMAGE

_demo_manifest() {
    echo "${SCRIPT_DIR}/manifests/demo/deployment.yaml"
}

install_demo() {
    log_section_silent "Installing Demo"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    # Optional: deploy nothing on purpose without failing the install.
    # Exit status 2 marks the module "skipped", so its dependents are skipped too.
    if [[ -z "${DEMO_IMAGE}" ]]; then
        write_to_log_file "WARN" "DEMO_IMAGE not set — skipping Demo"
        return 2
    fi

    if ! apply_manifest "$(_demo_manifest)" "${INSTALL_NAMESPACE}" \
        "image: .*demo.*" "${DEMO_IMAGE}"; then
        log_error "Failed to apply Demo manifest"
        return 1
    fi

    wait_for_deployment "demo" "${INSTALL_NAMESPACE}" 300 || return 1

    write_to_log_file "SUCCESS" "Demo installed"
    return 0
}

uninstall_demo() {
    log_section_silent "Uninstalling Demo"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    delete_manifest "$(_demo_manifest)" "${INSTALL_NAMESPACE}"
    write_to_log_file "SUCCESS" "Demo uninstalled"
    return 0
}

# Optional. Found by naming convention: <module id>_health.
# Exit 0 = healthy. Anything printed to stdout is shown as the failure detail.
demo_health() {
    check_deployment_healthy "demo"
}

export -f install_demo
export -f uninstall_demo
export -f demo_health
```

Rules the runner enforces:

- `install_fn` and `uninstall_fn` must be **defined in this module's own `source_lib`**. Functions defined in any other file are rejected when the registry loads.
- `install_fn` runs in a **subshell**. Variables it sets are not visible to later modules. Share state through the cluster.
- Return `0` for success, `2` for "skipped on purpose", and any other non-zero value for failure.
- Honour `DRY_RUN=true`: return `0` without touching the cluster.
- Write detail to the log with `write_to_log_file`. Use `log_error` for errors.
- Do not rely on a module in the same wave having run first. Declare the need with `depends_on`.

### Step 3: Add the image (if the component has one)

Add one entry to [`lib/images.env`](../lib/images.env). Put a comment on the line directly above it, because the comment becomes the `--help` text.

```bash
# Demo
DEMO_IMAGE=${DEMO_IMAGE:-quay.io/example/demo:0.0.1}
```

The CLI flag `--demo-image`, the `--help` line, the `DEMO_IMAGE_OVERRIDDEN` marker and the image-format validation are all derived from this entry. See [Image resolution](architecture.md#image-resolution).

### Step 4: Register the module

Add an entry to the `modules` array in [`modules.json`](../modules.json).

```json
{
  "id": "demo",
  "name": "Demo",
  "source_lib": "lib/install_demo.sh",
  "install_fn": "install_demo",
  "uninstall_fn": "uninstall_demo",
  "targets": ["*"],
  "required": false,
  "depends_on": ["postgres"]
}
```

| Field | Choose |
|---|---|
| `id` | Lowercase letters, digits and `_` only (`^[a-z0-9_]+$`). It must be unique, and it is the prefix of `<id>_health` |
| `name` | Display name shown in progress output and the summary |
| `source_lib` | Relative path, no `..` and no leading `/` |
| `targets` | `["*"]` for all targets, or a list of `"kind"` / `"openshift"` |
| `required` | `true` aborts the installer if this module fails. `false` warns and continues |
| `depends_on` | Ids of modules that must be installed first. An empty list `[]` puts the module in wave 1 |

### Step 5: Register with Causa MCP (MCP servers only)

Skip this step unless the new component is an MCP server that Causa should call.

Causa reads its MCP servers from a ConfigMap named `causa-mcp-config`. [`lib/install_causa.sh`](../lib/install_causa.sh) builds it from one of two files, chosen by `INSTALL_TARGET`:

| Target | File |
|---|---|
| `kind` | `manifests/causa/mcp.json` |
| `openshift` | `manifests/openshift/causa/mcp.json` |

Add an entry under `mcpServers` in each file where the module runs. The OpenShift file leaves out the Kind-only servers (`async-profiler` and `prometheus`) because those modules do not run there. Do the same for a Kind-only module.

```json
"demo": {
  "type": "streamable-http",
  "url": "http://demo:8080/mcp",
  "headers": {},
  "optional": true,
  "alwaysAllow": ["get_status"],
  "healthCheck": { "url": "http://demo:8080/q/health", "timeoutMs": 5000 },
  "timeoutMs": 5000,
  "description": "Demo MCP — what this server gives Causa",
  "tools": [
    {
      "name": "get_status",
      "contextKey": "DEMO_STATUS",
      "description": "What the tool returns.",
      "arguments": { "pod_name": "${podName}", "namespace": "${namespace}" }
    }
  ]
}
```

| Field | Notes |
|---|---|
| `url`, `healthCheck.url` | `http://<service-name>:<port>/...`. The host is the Service name in your manifest, so the two must match |
| `optional` | The `kubernetes`, `quarkus` and `async-profiler` entries use `false`. The `prometheus` entry uses `true` |
| `alwaysAllow` | The tool names Causa may call without asking |
| `tools[].contextKey` | The name the result is stored under |
| `tools[].arguments` | Placeholders used by the existing entries: `${podName}`, `${namespace}`, `${containerName}`, `${alertTimestamp}`, `${alertTimestampMinus15m}`, `${recordingId}`, `${metadata.metricsBaseUrl}` |

`install_causa` applies the ConfigMap when `causa_backend` installs. The ConfigMap is not regenerated on its own, so re-run the installer after you change either file.

### Step 6: Verify

```bash
# 1. Syntax checks
bash -n lib/install_demo.sh
jq . modules.json > /dev/null
jq . manifests/causa/mcp.json manifests/openshift/causa/mcp.json > /dev/null   # if you edited them

# 2. Registry validation and wave walk-through, no cluster changes
./install.sh --dry-run --target kind
./install.sh --dry-run --target openshift

# 3. The image flag was picked up
./install.sh --help | grep demo-image

# 4. Registry tests, including the real modules.json
bash tests/test_parallel_waves.sh

# 5. Real install, then check the log
./install.sh
grep -n "Demo" install.log

# 6. Causa sees the server (MCP servers only)
kubectl get configmap causa-mcp-config -n causa-rca -o jsonpath='{.data.mcp\.json}' | jq '.mcpServers | keys'

# 7. Uninstall
./install.sh --terminate
```

Look for these results:

- `Demo ✓` appears in the dry-run output.
- A registry mistake is reported before any cluster work. Examples: `depends on unknown module`, `dependency cycle involving`, `function 'install_demo' ... is not defined by lib/install_demo.sh`.
- The health report lists `Demo` after the install.

## Dependencies and waves

You never set a wave number. The runner computes it from `depends_on`: **wave = 1 + the highest wave among the dependencies that apply to the target**. A module with `"depends_on": []` is in wave 1.

| Goal | `depends_on` |
|---|---|
| Install in parallel with the other wave 1 modules | `[]` |
| Install after `first` has finished | `["first"]` |

Dependencies on a module that does not apply to the selected target are ignored. They neither block the dependent nor delay its wave. That is how you handle a dependency that exists on only one target: set `targets` on the dependency.

| `comp1` targets | `comp2` targets | `comp2` depends on `comp1` | Kind | OpenShift |
|---|---|---|---|---|
| `kind` | `*` | yes | comp1 wave 1, comp2 wave 2 | comp2 wave 1 (comp1 is filtered out) |
| `openshift` | `*` | yes | comp2 wave 1 | comp1 wave 1, comp2 wave 2 |
| `*` | `*` | yes | comp1 wave 1, comp2 wave 2 | comp1 wave 1, comp2 wave 2 |
| `*` | `*` | no | both wave 1 | both wave 1 |

Limits:

- `comp2` still installs when `comp1` does not apply. The dependency is ignored, not enforced. If `comp2` needs `comp1`'s output, `comp2`'s library must check for it. `install_quarkus_mcp.sh` does this with `validate_prometheus_available`.
- You cannot say "depends on `comp1` on Kind but on `comp3` on OpenShift". The schema has no per-target dependency lists.
- A cycle is rejected on every target, even when part of it is filtered out on the current one.

## Checklist

- [ ] `manifests/<name>/` uses `PLACEHOLDER_NAMESPACE` and has no hard-coded namespace
- [ ] `lib/install_<name>.sh` has a source guard, an install function, an uninstall function and, optionally, `<id>_health`
- [ ] Both functions return `0` on a dry run
- [ ] `modules.json` has an entry with valid `targets`, `required` and `depends_on`
- [ ] `lib/images.env` has an entry with a comment on the line above it (if there is an image)
- [ ] The new MCP server is in `manifests/causa/mcp.json`, and in `manifests/openshift/causa/mcp.json` if it runs on OpenShift (if Causa should call it)
- [ ] The NodePort is unused, and `lib/install_kind_cluster.sh` is updated if it must be host-visible (if it needs one)
- [ ] `./install.sh --dry-run` passes for both `kind` and `openshift`
- [ ] `bash tests/test_parallel_waves.sh` passes
- [ ] `install.sh` and `lib/validator.sh` are unchanged
