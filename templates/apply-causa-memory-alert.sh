#!/usr/bin/env bash
# =============================================================================
# apply-causa-memory-alert.sh
#
# Applies the causa-memory-alert-template.yaml for a specific application.
# Handles both Kind and OpenShift clusters:
#
#   Kind:       Applies PrometheusRule + NetworkPolicy.
#               Alertmanager is already wired by the installer via Helm values.
#
#   OpenShift:  Applies PrometheusRule + NetworkPolicy, then MERGES the
#               causa-webhook receiver into the existing Alertmanager config
#               (alertmanager-main or alertmanager-user-workload depending on
#               topology) — existing receivers and routes are preserved.
#
# Usage:
#   ./templates/apply-causa-memory-alert.sh \
#     --app-name <name> \
#     --namespace <namespace> \
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
[[ -z "${APP_NAME}"         ]] && { echo "ERROR: --app-name is required";                          exit 1; }
[[ -z "${APP_NAMESPACE}"    ]] && { echo "ERROR: --namespace is required";                         exit 1; }
[[ -z "${MEMORY_THRESHOLD}" ]] && { echo "ERROR: --threshold is required";                         exit 1; }
[[ -z "${CLUSTER_TARGET}"   ]] && { echo "ERROR: --target is required (kind|openshift)";   exit 1; }

[[ ! "${MEMORY_THRESHOLD}" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]] && \
    { echo "ERROR: --threshold must be a decimal between 0.0 and 1.0 (e.g. 0.80)"; exit 1; }

[[ "${CLUSTER_TARGET}" != "kind" && "${CLUSTER_TARGET}" != "openshift" ]] && \
    { echo "ERROR: --target must be 'kind' or 'openshift'"; exit 1; }

CLI=$( [[ "${CLUSTER_TARGET}" == "kind" ]] && echo "kubectl" || echo "oc" )

echo "Applying Causa memory alert for app '${APP_NAME}' in namespace '${APP_NAMESPACE}' (threshold: ${MEMORY_THRESHOLD}, target: ${CLUSTER_TARGET})"

# ---------------------------------------------------------------------------
# Step 1: Render the template (explicit variable list protects Prometheus
#         template variables like $labels and $value from being substituted)
# ---------------------------------------------------------------------------
export APP_NAME APP_NAMESPACE MEMORY_THRESHOLD
RENDERED=$(envsubst '${APP_NAME},${APP_NAMESPACE},${MEMORY_THRESHOLD}' < "${TEMPLATE}")

# ---------------------------------------------------------------------------
# Step 2: Apply PrometheusRule and NetworkPolicy (skip any Secret document)
# ---------------------------------------------------------------------------
echo "${RENDERED}" | python3 -c "
import sys, re
content = sys.stdin.read()
for doc in re.split(r'(?m)^---\s*$', content):
    if re.search(r'^kind:\s*Secret', doc, re.MULTILINE): continue
    if re.search(r'^apiVersion:', doc, re.MULTILINE):
        print(doc.strip()); print('---')
" | ${CLI} apply -f -

# ---------------------------------------------------------------------------
# Step 3: On OpenShift — merge causa-webhook into the existing Alertmanager.
#         Detects topology (UWM Alertmanager vs platform Alertmanager) and
#         merges into the correct Secret, preserving all existing config.
#         Skipped on Kind — Alertmanager is wired by the installer via Helm.
# ---------------------------------------------------------------------------
if [[ "${CLUSTER_TARGET}" == "openshift" ]]; then
    WEBHOOK_URL="http://causa-backend.${APP_NAMESPACE}.svc.cluster.local:8080/api/v1/webhooks/alerts"

    OCP_MONITORING_NS="openshift-monitoring"
    OCP_UWM_NS="openshift-user-workload-monitoring"

    # Detect topology: UWM Alertmanager (Topology A) vs platform (Topology B).
    # Distinguish a confirmed NotFound from permission/API errors — abort on
    # the latter to avoid silently modifying the wrong Alertmanager.
    TOPOLOGY_CHECK=$(oc get statefulset alertmanager-user-workload \
        -n "${OCP_UWM_NS}" 2>&1) && TOPOLOGY_RC=0 || TOPOLOGY_RC=$?
    if [[ ${TOPOLOGY_RC} -eq 0 ]]; then
        AM_SECRET="alertmanager-user-workload"
        AM_NS="${OCP_UWM_NS}"
        echo "Topology A detected: configuring alertmanager-user-workload"
    elif echo "${TOPOLOGY_CHECK}" | grep -qi "not found\|notfound"; then
        AM_SECRET="alertmanager-main"
        AM_NS="${OCP_MONITORING_NS}"
        echo "Topology B detected: configuring alertmanager-main"
    else
        echo "ERROR: Failed to detect Alertmanager topology: ${TOPOLOGY_CHECK}" >&2
        exit 1
    fi

    # Read the existing Alertmanager config
    EXISTING=$(oc get secret "${AM_SECRET}" -n "${AM_NS}" \
        -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    if [[ -z "${EXISTING}" ]]; then
        echo "ERROR: Could not read existing Alertmanager config from secret '${AM_SECRET}' in '${AM_NS}'"
        exit 1
    fi

    # Reconcile receiver and route independently rather than using a
    # text-presence check — handles stale URLs and missing routes correctly.
    echo "Reconciling causa-webhook receiver and route in ${AM_SECRET}..."

    MERGED=$(python3 - "${EXISTING}" "${WEBHOOK_URL}" << 'PYEOF'
import sys, yaml

existing_cfg = sys.argv[1]
webhook_url  = sys.argv[2]

cfg = yaml.safe_load(existing_cfg) or {}

# --- Reconcile receiver ---
# Remove any existing causa-webhook receiver (may have stale URL), then re-add.
receivers = [r for r in cfg.get("receivers", []) if r.get("name") != "causa-webhook"]
receivers.append({
    "name": "causa-webhook",
    "webhook_configs": [{
        "url": webhook_url,
        "send_resolved": True,
        "http_config": {}
    }]
})
cfg["receivers"] = receivers

# --- Reconcile route ---
# Remove any existing causa-webhook child route, then re-insert at front.
route = cfg.setdefault("route", {})
routes = [r for r in route.get("routes", []) if r.get("receiver") != "causa-webhook"]
routes.insert(0, {
    "matchers": ['alertname =~ "CausaApp.*"'],
    "receiver": "causa-webhook",
    "group_by": ["namespace", "alertname", "pod"],
    "group_wait": "10s",
    "group_interval": "1m",
    "repeat_interval": "15m"
})
route["routes"] = routes

print(yaml.dump(cfg, default_flow_style=False, allow_unicode=True))
PYEOF
)

    oc create secret generic "${AM_SECRET}" \
        --from-literal=alertmanager.yaml="${MERGED}" \
        -n "${AM_NS}" \
        --dry-run=client -o yaml | oc apply -f -

    echo "Alertmanager ${AM_SECRET} updated with causa-webhook receiver"
fi

echo "Done."
