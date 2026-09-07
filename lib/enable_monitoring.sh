#!/usr/bin/env bash

################################################################################
# OpenShift User Workload Monitoring — Alertmanager Webhook Configuration
#
# OpenShift ships Prometheus + Alertmanager as part of its built-in monitoring
# stack.  The exact topology varies by cluster configuration:
#
#   Topology A — UWM Alertmanager present:
#     openshift-user-workload-monitoring has its own Alertmanager StatefulSet
#     (alertmanager-user-workload).  We configure that one via the
#     alertmanager-user-workload Secret.
#
#   Topology B — Platform Alertmanager only (this cluster):
#     Only alertmanager-main in openshift-monitoring exists.  We patch
#     alertmanager-main to add the causa-critical receiver, preserving all
#     existing routes and receivers.
#
# This script auto-detects which topology is present and acts accordingly.
#
# This script:
#   1. Enables User Workload Monitoring (if not already on)
#   2. Configures the correct Alertmanager with a webhook receiver pointing to:
#        http://causa-backend.<namespace>.svc.cluster.local:8080/api/v1/webhooks/alerts
#   3. Applies a PrometheusRule (same alert rules used on Kind)
#   4. Applies a NetworkPolicy (allows Alertmanager and causa-mcp → Causa Backend on port 8080)
#
# References:
#   https://docs.openshift.com/container-platform/latest/monitoring/enabling-monitoring-for-user-defined-projects.html
#   https://docs.openshift.com/container-platform/latest/monitoring/configuring-the-alertmanager.html
################################################################################

# Source guard
if [[ -n "${ENABLE_MONITORING_LIB_LOADED:-}" ]]; then return 0; fi
readonly ENABLE_MONITORING_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Constants (overridable via env vars)
# ---------------------------------------------------------------------------
OCP_UWM_NAMESPACE="${OCP_UWM_NAMESPACE:-openshift-user-workload-monitoring}"
OCP_MONITORING_NAMESPACE="${OCP_MONITORING_NAMESPACE:-openshift-monitoring}"
# Secret names for each topology
OCP_UWM_ALERTMANAGER_SECRET="${OCP_UWM_ALERTMANAGER_SECRET:-alertmanager-user-workload}"
OCP_PLATFORM_ALERTMANAGER_SECRET="${OCP_PLATFORM_ALERTMANAGER_SECRET:-alertmanager-main}"

export OCP_UWM_NAMESPACE OCP_MONITORING_NAMESPACE \
       OCP_UWM_ALERTMANAGER_SECRET OCP_PLATFORM_ALERTMANAGER_SECRET

################################################################################
# _ocp_causa_alertmanager_webhook_url
################################################################################
_ocp_causa_alertmanager_webhook_url() {
    echo "http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080/api/v1/webhooks/alerts"
}

################################################################################
# _ocp_uwm_alertmanager_present
# Returns 0 if the UWM-specific Alertmanager StatefulSet exists.
################################################################################
_ocp_uwm_alertmanager_present() {
    ${KUBE_CLI} get statefulset alertmanager-user-workload \
        -n "${OCP_UWM_NAMESPACE}" &>/dev/null
}

################################################################################
# _ocp_check_alertmanager_permissions
# Verifies the current user can patch Secrets in openshift-monitoring.
# Patching alertmanager-main requires cluster-admin (or an equivalent role).
# Fail early with an actionable message rather than a buried API error.
################################################################################
_ocp_check_alertmanager_permissions() {
    local ns="${OCP_MONITORING_NAMESPACE}"
    local secret="${OCP_PLATFORM_ALERTMANAGER_SECRET}"

    write_to_log_file "INFO" "Checking permissions to patch Alertmanager Secret in ${ns}..."

    if ! ${KUBE_CLI} auth can-i update secrets \
            --namespace "${ns}" >>"${LOG_FILE}" 2>&1; then
        log_error "Insufficient permissions: cannot update Secrets in namespace '${ns}'"
        log_error "Patching '${secret}' requires cluster-admin (or equivalent)."
        log_error "Re-run after logging in with a cluster-admin account:"
        log_error "  oc login --username=<admin-user> --server=<api-url>"
        return 1
    fi

    write_to_log_file "INFO" "Permission check passed (can update Secrets in ${ns})"
    return 0
}

################################################################################
# _ocp_enable_user_workload_monitoring
# Patches cluster-monitoring-config to enable UWM. Idempotent.
# The ConfigMap manifest lives at manifests/openshift/cluster-monitoring-config.yaml
################################################################################
_ocp_enable_user_workload_monitoring() {
    local cm_name="cluster-monitoring-config"
    local cm_ns="${OCP_MONITORING_NAMESPACE}"

    write_to_log_file "INFO" "Checking if User Workload Monitoring is enabled..."

    if ${KUBE_CLI} get configmap "${cm_name}" -n "${cm_ns}" &>/dev/null; then
        local current
        current=$(${KUBE_CLI} get configmap "${cm_name}" -n "${cm_ns}" \
            -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
        if echo "${current}" | grep -q "enableUserWorkload: true"; then
            write_to_log_file "INFO" "User Workload Monitoring is already enabled"
            return 0
        fi
    fi

    write_to_log_file "INFO" "Enabling User Workload Monitoring..."
    local cm_manifest="${SCRIPT_DIR}/manifests/openshift/cluster-monitoring-config.yaml"
    if ! ${KUBE_CLI} apply -f "${cm_manifest}" >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to apply User Workload Monitoring ConfigMap"
        return 1
    fi

    # Wait up to 90s for UWM Prometheus AND Alertmanager to appear so that
    # topology detection (Topology A vs B) sees the final converged state.
    write_to_log_file "INFO" "Waiting for UWM components to start (up to 90s)..."
    local waited=0
    while true; do
        local prom_ready=false am_ready=false
        ${KUBE_CLI} get statefulset prometheus-user-workload \
            -n "${OCP_UWM_NAMESPACE}" &>/dev/null && prom_ready=true
        ${KUBE_CLI} get statefulset alertmanager-user-workload \
            -n "${OCP_UWM_NAMESPACE}" &>/dev/null && am_ready=true

        # Prometheus must be up; Alertmanager may or may not exist (Topology B
        # clusters never create it), so we stop waiting once Prometheus is up
        # AND either the Alertmanager has appeared OR we have waited long enough
        # to be confident it will not appear (i.e. Topology B).
        if ${prom_ready}; then
            if ${am_ready} || [[ ${waited} -ge 30 ]]; then
                break
            fi
        fi

        if [[ ${waited} -ge 90 ]]; then
            log_error "Timed out waiting for UWM Prometheus after enabling User Workload Monitoring"
            log_error "Check: ${KUBE_CLI} get pods -n ${OCP_UWM_NAMESPACE}"
            return 1
        fi
        sleep 5; waited=$(( waited + 5 ))
    done

    write_to_log_file "SUCCESS" "User Workload Monitoring enabled (prometheus-user-workload is up)"
    return 0
}

################################################################################
# _ocp_configure_uwm_alertmanager
# Topology A: configure the dedicated UWM Alertmanager via its own Secret.
# Reads manifests/prometheus/alertmanager-secret.yaml, substitutes the three
# placeholders, then applies it directly with kubectl apply -f 
################################################################################
_ocp_configure_uwm_alertmanager() {
    local webhook_url; webhook_url=$(_ocp_causa_alertmanager_webhook_url)
    local am_secret="${SCRIPT_DIR}/manifests/prometheus/alertmanager-secret.yaml"

    if [[ ! -f "${am_secret}" ]]; then
        log_error "Alertmanager Secret manifest not found: ${am_secret}"
        return 1
    fi

    local tmp; tmp=$(mktemp /tmp/causa-ocp-alertmanager-XXXXXX.yaml)
    sed -e "s|PLACEHOLDER_NAMESPACE|${OCP_UWM_NAMESPACE}|g" \
        -e "s|PLACEHOLDER_ALERTMANAGER_SECRET_NAME|${OCP_UWM_ALERTMANAGER_SECRET}|g" \
        -e "s|PLACEHOLDER_WEBHOOK_URL|${webhook_url}|g" \
        "${am_secret}" > "${tmp}"

    write_to_log_file "INFO" "Configuring UWM Alertmanager (${OCP_UWM_ALERTMANAGER_SECRET} Secret)..."
    if ! ${KUBE_CLI} apply -f "${tmp}" >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp}"
        log_error "Failed to apply UWM Alertmanager configuration Secret"
        return 1
    fi

    rm -f "${tmp}"
    write_to_log_file "SUCCESS" "UWM Alertmanager configured with causa-critical receiver"
    write_to_log_file "INFO"    "Webhook → ${webhook_url}"
    return 0
}

################################################################################
# _ocp_configure_platform_alertmanager
# Topology B: patch alertmanager-main in openshift-monitoring.
#
# We READ the existing config, inject the causa-critical receiver and a
# causa-.* child route, then write it back.
# All pre-existing receivers and routes are preserved.
################################################################################
_ocp_configure_platform_alertmanager() {
    local webhook_url; webhook_url=$(_ocp_causa_alertmanager_webhook_url)
    local secret="${OCP_PLATFORM_ALERTMANAGER_SECRET}"
    local ns="${OCP_MONITORING_NAMESPACE}"

    write_to_log_file "INFO" "Configuring platform Alertmanager (${secret} Secret in ${ns})..."

    # Decode the existing alertmanager.yaml from the Secret
    local existing_config
    existing_config=$(${KUBE_CLI} get secret "${secret}" -n "${ns}" \
        -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    if [[ -z "${existing_config}" ]]; then
        log_error "Could not read existing Alertmanager config from secret '${secret}' in '${ns}'"
        return 1
    fi

    write_to_log_file "INFO" "Read existing platform Alertmanager config (${#existing_config} bytes)"

    # Check if Causa webhook is already present — identified by URL, not receiver
    # name, to avoid false-positives if the cluster has an unrelated receiver
    # also named causa-critical.
    local webhook_url_escaped
    webhook_url_escaped=$(echo "${webhook_url}" | sed 's|/|\\/|g')
    if echo "${existing_config}" | grep -q "${webhook_url_escaped}"; then
        write_to_log_file "INFO" "Causa webhook already present in platform Alertmanager — skipping"
        return 0
    fi

    # Build the merged config:
    # Append the causa-critical receiver to the receivers list and add a
    # child route that matches causa-* alerts.
    local tmp_cfg; tmp_cfg=$(mktemp /tmp/causa-ocp-am-config-XXXXXX.yaml)

    # Use Python with PyYAML to safely merge the YAML.
    # Both python3 and the yaml module are required; fail fast if either is absent.
    local am_secret="${SCRIPT_DIR}/manifests/prometheus/alertmanager-secret.yaml"
    if [[ ! -f "${am_secret}" ]]; then
        log_error "Alertmanager Secret manifest not found: ${am_secret}"
        return 1
    fi

    if command -v python3 &>/dev/null && python3 -c 'import yaml' &>/dev/null; then
        # Write existing config to a temp file — we cannot use both a pipe and
        # a heredoc to the same python3 process (heredoc wins, pipe is ignored).
        local tmp_in; tmp_in=$(mktemp /tmp/causa-ocp-am-in-XXXXXX.yaml)
        echo "${existing_config}" > "${tmp_in}"

        python3 << PYEOF
import sys, yaml

in_path    = "${tmp_in}"
out_path   = "${tmp_cfg}"
am_secret  = "${am_secret}"
webhook    = "${webhook_url}"

with open(in_path) as f:
    cfg = yaml.safe_load(f.read())

if cfg is None:
    cfg = {}

# Read the Alertmanager config from inside the Secret manifest's stringData block,
# substituting the webhook URL placeholder before parsing.
with open(am_secret) as f:
    secret_doc = yaml.safe_load(f.read().replace("PLACEHOLDER_WEBHOOK_URL", webhook))
causa_cfg = yaml.safe_load(secret_doc["stringData"]["alertmanager.yaml"])

# Add causa-critical receiver from the manifest file
causa_receiver = next(
    (r for r in causa_cfg.get("receivers", []) if r.get("name") == "causa-critical"),
    None
)
if causa_receiver:
    cfg.setdefault("receivers", [])
    cfg["receivers"].append(causa_receiver)

# Inject the causa child route from the manifest file
# (inserted first so it takes precedence over the default catch-all route).
causa_route = next(
    (r for r in causa_cfg.get("route", {}).get("routes", [])
     if r.get("receiver") == "causa-critical"),
    None
)
if causa_route:
    route = cfg.setdefault("route", {})
    routes = route.setdefault("routes", [])
    routes.insert(0, causa_route)

with open(out_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
PYEOF
        local py_rc=$?
        rm -f "${tmp_in}"
        if [[ ${py_rc} -ne 0 ]]; then
            rm -f "${tmp_cfg}"
            log_error "Python YAML merge failed"
            return 1
        fi
    else
        rm -f "${tmp_cfg}"
        log_error "python3 with PyYAML is required to merge Alertmanager config safely"
        log_error "Install PyYAML:  pip3 install pyyaml"
        return 1
    fi

    if [[ ! -s "${tmp_cfg}" ]]; then
        rm -f "${tmp_cfg}"
        log_error "Failed to generate merged Alertmanager config"
        return 1
    fi

    write_to_log_file "INFO" "Patching platform Alertmanager Secret with causa-critical receiver..."
    if ! ${KUBE_CLI} create secret generic "${secret}" \
            --from-file=alertmanager.yaml="${tmp_cfg}" \
            -n "${ns}" \
            --dry-run=client -o yaml \
            | ${KUBE_CLI} apply -f - >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp_cfg}"
        log_error "Failed to patch platform Alertmanager Secret"
        return 1
    fi

    rm -f "${tmp_cfg}"
    write_to_log_file "SUCCESS" "Platform Alertmanager patched with causa-critical receiver"
    write_to_log_file "INFO"    "Webhook → ${webhook_url}"
    return 0
}

################################################################################
# _ocp_apply_prometheus_rule
# Deploys the PrometheusRule to the correct namespace based on topology:
#
#   Topology A (UWM Alertmanager present):
#     Deploy to openshift-user-workload-monitoring so the UWM Prometheus picks
#     it up and routes alerts to the UWM Alertmanager we configured.
#
#   Topology B (platform Alertmanager only):
#     Deploy to openshift-monitoring so the platform Prometheus (prometheus-k8s)
#     picks it up — the only Prometheus with container_* and kube_* metrics.
#
# The PromQL expressions filter on PLACEHOLDER_NAMESPACE (install namespace)
# to scope alerts to Causa workloads only regardless of topology.
################################################################################
_ocp_apply_prometheus_rule() {
    local prom_dir="${SCRIPT_DIR}/manifests/prometheus"
    local manifest="${prom_dir}/prometheusrule.yaml"

    if [[ ! -f "${manifest}" ]]; then
        write_to_log_file "WARN" "PrometheusRule manifest not found: ${manifest} — skipping"
        return 0
    fi

    # Choose rule namespace based on topology: UWM namespace for Topology A,
    # platform monitoring namespace for Topology B.
    local rule_ns
    if _ocp_uwm_alertmanager_present; then
        rule_ns="${OCP_UWM_NAMESPACE}"
    else
        rule_ns="${OCP_MONITORING_NAMESPACE}"
    fi

    write_to_log_file "INFO" "Applying PrometheusRule to namespace: ${rule_ns} (rule), metrics scoped to: ${INSTALL_NAMESPACE}"
    # arg 2 = PLACEHOLDER_NAMESPACE (install ns — used in PromQL filters)
    # arg 5 = PLACEHOLDER_RULE_NAMESPACE (topology-dependent — where the rule lives)
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" "" "" "${rule_ns}"; then
        log_error "Failed to apply PrometheusRule"
        return 1
    fi
    write_to_log_file "SUCCESS" "PrometheusRule applied to namespace: ${rule_ns}"
    return 0
}

################################################################################
# _ocp_apply_network_policy
# Allows Alertmanager (platform or UWM namespace) and the OpenShift ingress
# router to reach Causa Backend on port 8080.
# Uses the shared manifests/prometheus/networkpolicy.yaml
################################################################################
_ocp_apply_network_policy() {
    write_to_log_file "INFO" "Applying NetworkPolicy for Alertmanager + ingress → Causa Backend..."

    local manifest="${SCRIPT_DIR}/manifests/prometheus/networkpolicy.yaml"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}"; then
        log_error "Failed to apply NetworkPolicy for Alertmanager and causa-mcp"
        return 1
    fi
    write_to_log_file "SUCCESS" "NetworkPolicy applied (Alertmanager and causa-mcp → Causa Backend on port 8080)"
    return 0
}

################################################################################
# enable_monitoring
# Enables UWM, wires the Alertmanager webhook receiver, applies PrometheusRule
# and NetworkPolicy.
################################################################################
enable_monitoring() {
    log_section_silent "Configuring OpenShift Monitoring"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping OpenShift monitoring configuration"
        return 0
    fi

    # ── 1. Enable UWM ────────────────────────────────────────────────────────
    if ! _ocp_enable_user_workload_monitoring; then
        return 1
    fi

    # ── 2. Configure Alertmanager (topology-aware) ───────────────────────────
    # Namespace is guaranteed to exist at this point — install_openshift_infra
    # (Step 2a in install.sh) runs before this function is called.
    if _ocp_uwm_alertmanager_present; then
        write_to_log_file "INFO" "Topology A: UWM Alertmanager detected — configuring alertmanager-user-workload"
        if ! _ocp_configure_uwm_alertmanager; then
            return 1
        fi
    else
        write_to_log_file "INFO" "Topology B: No UWM Alertmanager — configuring platform alertmanager-main"
        # Topology B requires cluster-admin to patch alertmanager-main
        if ! _ocp_check_alertmanager_permissions; then
            return 1
        fi
        if ! _ocp_configure_platform_alertmanager; then
            return 1
        fi
    fi

    # ── 3. Apply PrometheusRule ───────────────────────────────────────────────
    if ! _ocp_apply_prometheus_rule; then
        return 1
    fi

    # ── 4. Apply NetworkPolicy ────────────────────────────────────────────────
    if ! _ocp_apply_network_policy; then
        return 1
    fi

    write_to_log_file "SUCCESS" "OpenShift monitoring configured"
    write_to_log_file "INFO"    "Alertmanager webhook → $(_ocp_causa_alertmanager_webhook_url)"
    return 0
}

################################################################################
# disable_monitoring
# Removes the Alertmanager webhook config, PrometheusRule, and NetworkPolicy.
################################################################################
disable_monitoring() {
    log_section_silent "Removing OpenShift monitoring configuration"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping OpenShift monitoring removal"
        return 0
    fi

    # Remove UWM Alertmanager secret if present
    ${KUBE_CLI} delete secret "${OCP_UWM_ALERTMANAGER_SECRET}" \
        -n "${OCP_UWM_NAMESPACE}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    write_to_log_file "INFO" "UWM Alertmanager Secret removed (or was absent)"

    # For platform Alertmanager: restore original config (remove causa additions).
    # Identified by webhook URL — not receiver name — to avoid touching any
    # unrelated pre-existing receiver that happens to be named causa-critical.
    local webhook_url; webhook_url=$(_ocp_causa_alertmanager_webhook_url)
    if ${KUBE_CLI} get secret "${OCP_PLATFORM_ALERTMANAGER_SECRET}" \
            -n "${OCP_MONITORING_NAMESPACE}" &>/dev/null; then
        local existing
        existing=$(${KUBE_CLI} get secret "${OCP_PLATFORM_ALERTMANAGER_SECRET}" \
            -n "${OCP_MONITORING_NAMESPACE}" \
            -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if echo "${existing}" | grep -qF "${webhook_url}"; then
            if command -v python3 &>/dev/null; then
                local tmp_clean; tmp_clean=$(mktemp /tmp/causa-ocp-am-clean-XXXXXX.yaml)
                local tmp_existing; tmp_existing=$(mktemp /tmp/causa-ocp-am-existing-XXXXXX.yaml)
                echo "${existing}" > "${tmp_existing}"
                python3 << PYEOF
import yaml

in_path  = "${tmp_existing}"
out_path = "${tmp_clean}"

with open(in_path) as f:
    cfg = yaml.safe_load(f.read()) or {}

webhook_url = "${webhook_url}"

# Remove causa-critical receiver — identified by webhook URL, not name,
# so an unrelated pre-existing receiver named causa-critical is not deleted.
def _has_causa_url(receiver):
    for wc in receiver.get("webhook_configs", []):
        if wc.get("url") == webhook_url:
            return True
    return False

cfg["receivers"] = [r for r in cfg.get("receivers", []) if not _has_causa_url(r)]

# Remove causa child routes — those pointing to causa-critical receiver.
route = cfg.get("route", {})
route["routes"] = [r for r in route.get("routes", []) if r.get("receiver") != "causa-critical"]

with open(out_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
PYEOF
                rm -f "${tmp_existing}"
                if [[ -s "${tmp_clean}" ]]; then
                    ${KUBE_CLI} create secret generic "${OCP_PLATFORM_ALERTMANAGER_SECRET}" \
                        --from-file=alertmanager.yaml="${tmp_clean}" \
                        -n "${OCP_MONITORING_NAMESPACE}" \
                        --dry-run=client -o yaml \
                        | ${KUBE_CLI} apply -f - >>"${LOG_FILE}" 2>&1 || true
                    write_to_log_file "INFO" "Platform Alertmanager restored (causa-critical receiver removed)"
                fi
                rm -f "${tmp_clean}"
            else
                write_to_log_file "WARN" "python3 not found — cannot automatically restore platform Alertmanager config"
                write_to_log_file "WARN" "Remove the causa-critical receiver manually from secret '${OCP_PLATFORM_ALERTMANAGER_SECRET}' in '${OCP_MONITORING_NAMESPACE}'"
            fi
        fi
    fi

    # Remove PrometheusRule from whichever namespace it was deployed to
    local rule_ns
    if _ocp_uwm_alertmanager_present; then
        rule_ns="${OCP_UWM_NAMESPACE}"
    else
        rule_ns="${OCP_MONITORING_NAMESPACE}"
    fi
    ${KUBE_CLI} delete prometheusrule causa-rca-alerts \
        -n "${rule_ns}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    write_to_log_file "INFO" "PrometheusRule removed (or was absent)"

    # Remove NetworkPolicy
    ${KUBE_CLI} delete networkpolicy allow-alertmanager-to-causa-backend \
        -n "${INSTALL_NAMESPACE}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    write_to_log_file "INFO" "NetworkPolicy removed (or was absent)"

    write_to_log_file "SUCCESS" "OpenShift monitoring configuration removed"
    return 0
}

export -f enable_monitoring
export -f disable_monitoring
