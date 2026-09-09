#!/usr/bin/env bash
# =============================================================================
# apply-causa-memory-alert.sh
#
# Applies the causa-memory-alert-template.yaml for a specific application.
# Handles both Kind and OpenShift clusters:
#
#   Kind:       Applies PrometheusRule to INSTALL_NAMESPACE (picked up by
#               kube-prometheus-stack which watches all namespaces).
#               Applies NetworkPolicy to APP_NAMESPACE.
#               Alertmanager is already wired by the installer via Helm values.
#
#   OpenShift:  Applies PrometheusRule to the topology-appropriate namespace
#               (openshift-monitoring for Topology B, openshift-user-workload-
#               monitoring for Topology A).
#               Applies NetworkPolicy to APP_NAMESPACE.
#               Merges the causa-critical receiver into the existing Alertmanager
#               config (alertmanager-main or alertmanager-user-workload depending
#               on topology) — existing receivers and routes are preserved.
#
# Usage:
#   ./templates/apply-causa-memory-alert.sh \
#     --app-name <name> \
#     --namespace <app-namespace> \
#     --threshold <0.0-1.0> \
#     --target <kind|openshift>
#
# Example:
#   ./templates/apply-causa-memory-alert.sh \
#     --app-name liberty-perf \
#     --namespace causa-rca \
#     --threshold 0.80 \
#     --target openshift
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/causa-memory-alert-template.yaml"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
APP_NAME=""
APP_NAMESPACE=""
MEMORY_THRESHOLD=""
CLUSTER_TARGET=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-name)       APP_NAME="$2";         shift 2 ;;
        --namespace)      APP_NAMESPACE="$2";    shift 2 ;;
        --threshold)      MEMORY_THRESHOLD="$2"; shift 2 ;;
        --target)         CLUSTER_TARGET="$2";   shift 2 ;;
        *) echo "ERROR: Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
[[ -z "${APP_NAME}"         ]] && { echo "ERROR: --app-name is required";                        exit 1; }
[[ -z "${APP_NAMESPACE}"    ]] && { echo "ERROR: --namespace is required";                       exit 1; }
[[ -z "${MEMORY_THRESHOLD}" ]] && { echo "ERROR: --threshold is required";                       exit 1; }
[[ -z "${CLUSTER_TARGET}"   ]] && { echo "ERROR: --target is required (kind|openshift)";         exit 1; }

[[ ! "${MEMORY_THRESHOLD}" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]] && \
    { echo "ERROR: --threshold must be a decimal between 0.0 and 1.0 (e.g. 0.80)"; exit 1; }

[[ "${CLUSTER_TARGET}" != "kind" && "${CLUSTER_TARGET}" != "openshift" ]] && \
    { echo "ERROR: --target must be 'kind' or 'openshift'"; exit 1; }

CLI=$( [[ "${CLUSTER_TARGET}" == "kind" ]] && echo "kubectl" || echo "oc" )

echo "Applying Causa memory alert for app '${APP_NAME}' in namespace '${APP_NAMESPACE}' (threshold: ${MEMORY_THRESHOLD}, target: ${CLUSTER_TARGET})"

# ---------------------------------------------------------------------------
# Step 1: Determine RULE_NAMESPACE
#   Kind:        PrometheusRule goes in APP_NAMESPACE — kube-prometheus-stack
#                is configured with ruleNamespaceSelector: {} so it watches all
#                namespaces; co-locating the rule with the app keeps cleanup tidy.
#   OpenShift:   Must go in the monitoring namespace the platform Prometheus
#                watches — openshift-monitoring (Topology B, default) or
#                openshift-user-workload-monitoring (Topology A).
# ---------------------------------------------------------------------------
OCP_MONITORING_NS="openshift-monitoring"
OCP_UWM_NS="openshift-user-workload-monitoring"

if [[ "${CLUSTER_TARGET}" == "kind" ]]; then
    RULE_NAMESPACE="${APP_NAMESPACE}"
else
    # Detect topology: UWM Alertmanager (Topology A) vs platform (Topology B).
    TOPOLOGY_CHECK=$(oc get statefulset alertmanager-user-workload \
        -n "${OCP_UWM_NS}" 2>&1) && TOPOLOGY_RC=0 || TOPOLOGY_RC=$?
    if [[ ${TOPOLOGY_RC} -eq 0 ]]; then
        RULE_NAMESPACE="${OCP_UWM_NS}"
        AM_SECRET="alertmanager-user-workload"
        AM_NS="${OCP_UWM_NS}"
        echo "Topology A detected: PrometheusRule → ${RULE_NAMESPACE}, Alertmanager → ${AM_SECRET}"
    elif echo "${TOPOLOGY_CHECK}" | grep -qi "not found\|notfound"; then
        RULE_NAMESPACE="${OCP_MONITORING_NS}"
        AM_SECRET="alertmanager-main"
        AM_NS="${OCP_MONITORING_NS}"
        echo "Topology B detected: PrometheusRule → ${RULE_NAMESPACE}, Alertmanager → ${AM_SECRET}"
    else
        echo "ERROR: Failed to detect Alertmanager topology: ${TOPOLOGY_CHECK}" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Render the template (explicit variable list protects Prometheus
#         template variables like $labels and $value from being substituted)
# ---------------------------------------------------------------------------
export APP_NAME APP_NAMESPACE MEMORY_THRESHOLD RULE_NAMESPACE
RENDERED=$(envsubst '${APP_NAME},${APP_NAMESPACE},${MEMORY_THRESHOLD},${RULE_NAMESPACE}' < "${TEMPLATE}")

# ---------------------------------------------------------------------------
# Step 3: Apply PrometheusRule and NetworkPolicy
# ---------------------------------------------------------------------------
echo "${RENDERED}" | ${CLI} apply -f -

# ---------------------------------------------------------------------------
# Step 4: On OpenShift — merge causa-critical into the existing Alertmanager.
#         Skipped on Kind — Alertmanager is wired by the installer via Helm.
# ---------------------------------------------------------------------------
if [[ "${CLUSTER_TARGET}" == "openshift" ]]; then
    WEBHOOK_URL="http://causa-backend.${APP_NAMESPACE}.svc.cluster.local:8080/api/v1/webhooks/alerts"

    # Read the existing Alertmanager config
    EXISTING=$(oc get secret "${AM_SECRET}" -n "${AM_NS}" \
        -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    if [[ -z "${EXISTING}" ]]; then
        echo "ERROR: Could not read existing Alertmanager config from secret '${AM_SECRET}' in '${AM_NS}'"
        exit 1
    fi

    # Idempotency check — skip if our webhook URL is already present
    WEBHOOK_URL_ESCAPED="${WEBHOOK_URL//\//\\/}"
    if echo "${EXISTING}" | grep -q "${WEBHOOK_URL_ESCAPED}"; then
        echo "causa-critical receiver already present in ${AM_SECRET} — skipping Alertmanager merge"
    else
        echo "Merging causa-critical receiver and route into ${AM_SECRET}..."

        # Write existing config to a temp file — cannot mix pipe and heredoc
        # to the same python3 process (heredoc wins, pipe is ignored).
        TMP_IN=$(mktemp /tmp/causa-am-in-XXXXXX.yaml)
        TMP_OUT=$(mktemp /tmp/causa-am-out-XXXXXX.yaml)
        echo "${EXISTING}" > "${TMP_IN}"

        python3 << PYEOF
import yaml

in_path   = "${TMP_IN}"
out_path  = "${TMP_OUT}"
webhook   = "${WEBHOOK_URL}"

with open(in_path) as f:
    cfg = yaml.safe_load(f.read()) or {}

# --- Reconcile receiver ---
# Guard: skip if a receiver named causa-critical already exists (different URL
# would have been caught by the idempotency check above, so this is a no-op
# safety guard against duplicate appends on concurrent runs).
existing_names = {r.get("name") for r in cfg.get("receivers", [])}
if "causa-critical" not in existing_names:
    cfg.setdefault("receivers", [])
    cfg["receivers"].append({
        "name": "causa-critical",
        "webhook_configs": [{
            "url": webhook,
            "send_resolved": False,
            "http_config": {"follow_redirects": True}
        }]
    })

# --- Reconcile route ---
# Insert at front so it takes precedence over the platform catch-all.
# Identified by the causa-.* matcher, not just receiver name.
route  = cfg.setdefault("route", {})
routes = route.setdefault("routes", [])
already_has_route = any(
    any("causa-.*" in str(m) for m in r.get("matchers", []))
    for r in routes
)
if not already_has_route:
    routes.insert(0, {
        "matchers": ['alertname =~ "causa-.*"'],
        "receiver": "causa-critical",
        "group_by":        ["namespace", "alertname", "pod"],
        "group_wait":      "5s",
        "group_interval":  "5s",
        "repeat_interval": "15m"
    })

with open(out_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
PYEOF

        rm -f "${TMP_IN}"

        if [[ ! -s "${TMP_OUT}" ]]; then
            rm -f "${TMP_OUT}"
            echo "ERROR: Python YAML merge produced empty output" >&2
            exit 1
        fi

        oc create secret generic "${AM_SECRET}" \
            --from-file=alertmanager.yaml="${TMP_OUT}" \
            -n "${AM_NS}" \
            --dry-run=client -o yaml | oc apply -f -

        rm -f "${TMP_OUT}"
        echo "Alertmanager ${AM_SECRET} updated with causa-critical receiver"
    fi
fi

echo "Done."
