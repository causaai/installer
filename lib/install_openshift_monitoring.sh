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
#     alertmanager-main to add the causa-webhook receiver, preserving all
#     existing routes and receivers.
#
# This script auto-detects which topology is present and acts accordingly.
#
# In both cases this script:
#   1. Enables User Workload Monitoring (if not already on)
#   2. Configures the correct Alertmanager with a webhook receiver pointing to:
#        http://causa-backend.<namespace>.svc.cluster.local:8080/api/v1/alerts
#   3. Applies a PrometheusRule (same alert rules used on Kind)
#   4. Applies a NetworkPolicy (allows Alertmanager → Causa Backend on port 8080)
#
# References:
#   https://docs.openshift.com/container-platform/latest/monitoring/enabling-monitoring-for-user-defined-projects.html
#   https://docs.openshift.com/container-platform/latest/monitoring/configuring-the-alertmanager.html
################################################################################

# Source guard
if [[ -n "${INSTALL_OPENSHIFT_MONITORING_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_OPENSHIFT_MONITORING_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Constants (overridable via env vars)
# ---------------------------------------------------------------------------
OCP_UWM_NAMESPACE="${OCP_UWM_NAMESPACE:-openshift-user-workload-monitoring}"
OCP_MONITORING_NAMESPACE="${OCP_MONITORING_NAMESPACE:-openshift-monitoring}"
# Secret names for each topology
OCP_UWM_ALERTMANAGER_SECRET="${OCP_UWM_ALERTMANAGER_SECRET:-alertmanager-user-workload}"
OCP_PLATFORM_ALERTMANAGER_SECRET="${OCP_PLATFORM_ALERTMANAGER_SECRET:-alertmanager-main}"

export OCP_UWM_NAMESPACE OCP_MONITORING_NAMESPACE

################################################################################
# _ocp_causa_alertmanager_webhook_url
################################################################################
_ocp_causa_alertmanager_webhook_url() {
    echo "http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080/api/v1/alerts"
}

################################################################################
# _ocp_uwm_alertmanager_present
# Returns 0 if the UWM-specific Alertmanager StatefulSet exists and is ready.
################################################################################
_ocp_uwm_alertmanager_present() {
    ${KUBE_CLI} get statefulset alertmanager-user-workload \
        -n "${OCP_UWM_NAMESPACE}" &>/dev/null
}

################################################################################
# _ocp_enable_user_workload_monitoring
# Patches cluster-monitoring-config to enable UWM. Idempotent.
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
    ${KUBE_CLI} apply -f - >>"${LOG_FILE}" 2>&1 << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${cm_name}
  namespace: ${cm_ns}
data:
  config.yaml: |
    enableUserWorkload: true
EOF

    # Wait up to 90s for at least the UWM Prometheus to appear
    write_to_log_file "INFO" "Waiting for UWM Prometheus to start..."
    local waited=0
    while ! ${KUBE_CLI} get statefulset prometheus-user-workload \
            -n "${OCP_UWM_NAMESPACE}" &>/dev/null; do
        if [[ ${waited} -ge 90 ]]; then
            log_error "Timed out waiting for UWM Prometheus after enabling User Workload Monitoring"
            log_error "Check: ${KUBE_CLI} get pods -n openshift-monitoring"
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
################################################################################
_ocp_configure_uwm_alertmanager() {
    local webhook_url; webhook_url=$(_ocp_causa_alertmanager_webhook_url)
    local tmp; tmp=$(mktemp /tmp/causa-ocp-alertmanager-XXXXXX.yaml)

    cat > "${tmp}" << YAML
global:
  resolve_timeout: 5m
route:
  receiver: causa-webhook
  group_by: ['namespace', 'alertname', 'pod']
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 15m
receivers:
  - name: causa-webhook
    webhook_configs:
      - url: "${webhook_url}"
        send_resolved: true
        http_config: {}
  - name: "null"
YAML

    write_to_log_file "INFO" "Configuring UWM Alertmanager (alertmanager-user-workload Secret)..."
    if ! ${KUBE_CLI} create secret generic "${OCP_UWM_ALERTMANAGER_SECRET}" \
            --from-file=alertmanager.yaml="${tmp}" \
            -n "${OCP_UWM_NAMESPACE}" \
            --dry-run=client -o yaml \
            | ${KUBE_CLI} apply -f - >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp}"
        log_error "Failed to apply UWM Alertmanager configuration Secret"
        return 1
    fi

    rm -f "${tmp}"
    write_to_log_file "SUCCESS" "UWM Alertmanager configured with causa-webhook receiver"
    write_to_log_file "INFO"    "Webhook → ${webhook_url}"
    return 0
}

################################################################################
# _ocp_configure_platform_alertmanager
# Topology B: patch alertmanager-main in openshift-monitoring.
#
# We READ the existing config, inject the causa-webhook receiver and a route
# that matches alerts from the install namespace, then write it back.
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

    # Check if causa-webhook is already present — idempotent
    if echo "${existing_config}" | grep -q "causa-webhook"; then
        write_to_log_file "INFO" "causa-webhook receiver already present in platform Alertmanager — skipping"
        return 0
    fi

    # Build the merged config:
    # Append the causa-webhook receiver to the receivers list and add a
    # child route that matches alerts from the install namespace.
    local tmp_cfg; tmp_cfg=$(mktemp /tmp/causa-ocp-am-config-XXXXXX.yaml)
    local tmp_secret; tmp_secret=$(mktemp /tmp/causa-ocp-am-secret-XXXXXX.yaml)

    # Use Python (available on macOS/Linux) to safely merge the YAML.
    # Falls back to a sed-based approach if python3 is absent.
    if command -v python3 &>/dev/null; then
        # Write existing config to a temp file — we cannot use both a pipe and
        # a heredoc to the same python3 process (heredoc wins, pipe is ignored).
        local tmp_in; tmp_in=$(mktemp /tmp/causa-ocp-am-in-XXXXXX.yaml)
        echo "${existing_config}" > "${tmp_in}"

        python3 << PYEOF
import sys, yaml

in_path   = "${tmp_in}"
out_path  = "${tmp_cfg}"
webhook   = "${webhook_url}"
namespace = "${INSTALL_NAMESPACE}"

with open(in_path) as f:
    cfg = yaml.safe_load(f.read())

if cfg is None:
    cfg = {}

# Add causa-webhook receiver
cfg.setdefault("receivers", [])
cfg["receivers"].append({
    "name": "causa-webhook",
    "webhook_configs": [{
        "url": webhook,
        "send_resolved": True,
        "http_config": {}
    }]
})

# Inject a child route scoped to the install namespace (inserted first so it
# takes precedence over the default catch-all route).
route = cfg.setdefault("route", {})
routes = route.setdefault("routes", [])
routes.insert(0, {
    "matchers": ["namespace = " + namespace],
    "receiver": "causa-webhook",
    "group_by":        ["namespace", "alertname", "pod"],
    "group_wait":      "10s",
    "group_interval":  "1m",
    "repeat_interval": "15m"
})

with open(out_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
PYEOF
        local py_rc=$?
        rm -f "${tmp_in}"
        if [[ ${py_rc} -ne 0 ]]; then
            rm -f "${tmp_cfg}" "${tmp_secret}"
            log_error "Python YAML merge failed"
            return 1
        fi
    else
        # Fallback: append receiver and a simple route via sed/awk
        write_to_log_file "WARN" "python3 not found — using sed fallback for Alertmanager config merge"
        {
            echo "${existing_config}"
            cat << APPEND
# causa-rca additions (appended by installer)
  routes:
  - matchers:
    - "namespace = ${INSTALL_NAMESPACE}"
    receiver: causa-webhook
    group_by: ['namespace', 'alertname', 'pod']
    group_wait: 10s
    group_interval: 1m
    repeat_interval: 15m
receivers:
- name: causa-webhook
  webhook_configs:
  - url: "${webhook_url}"
    send_resolved: true
APPEND
        } > "${tmp_cfg}"
    fi

    if [[ ! -s "${tmp_cfg}" ]]; then
        rm -f "${tmp_cfg}" "${tmp_secret}"
        log_error "Failed to generate merged Alertmanager config"
        return 1
    fi

    write_to_log_file "INFO" "Patching platform Alertmanager Secret with causa-webhook..."
    if ! ${KUBE_CLI} create secret generic "${secret}" \
            --from-file=alertmanager.yaml="${tmp_cfg}" \
            -n "${ns}" \
            --dry-run=client -o yaml \
            | ${KUBE_CLI} apply -f - >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp_cfg}" "${tmp_secret}"
        log_error "Failed to patch platform Alertmanager Secret"
        return 1
    fi

    rm -f "${tmp_cfg}" "${tmp_secret}"
    write_to_log_file "SUCCESS" "Platform Alertmanager patched with causa-webhook receiver"
    write_to_log_file "INFO"    "Webhook → ${webhook_url}"
    return 0
}

################################################################################
# _ocp_apply_prometheus_rule
################################################################################
_ocp_apply_prometheus_rule() {
    local prom_dir="${SCRIPT_DIR}/manifests/prometheus"
    local manifest="${prom_dir}/prometheusrule.yaml"

    if [[ ! -f "${manifest}" ]]; then
        write_to_log_file "WARN" "PrometheusRule manifest not found: ${manifest} — skipping"
        return 0
    fi

    write_to_log_file "INFO" "Applying PrometheusRule to namespace: ${INSTALL_NAMESPACE}"
    local tmp; tmp=$(mktemp /tmp/causa-ocp-prom-rule-XXXXXX.yaml)
    sed "s/PLACEHOLDER_NAMESPACE/${INSTALL_NAMESPACE}/g" "${manifest}" > "${tmp}"
    if ! ${KUBE_CLI} apply -f "${tmp}" >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp}"
        log_error "Failed to apply PrometheusRule"
        return 1
    fi
    rm -f "${tmp}"
    write_to_log_file "SUCCESS" "PrometheusRule applied to namespace: ${INSTALL_NAMESPACE}"
    return 0
}

################################################################################
# _ocp_apply_network_policy
# Allows Alertmanager (platform or UWM namespace) to reach Causa Backend.
################################################################################
_ocp_apply_network_policy() {
    write_to_log_file "INFO" "Applying NetworkPolicy for Alertmanager → Causa Backend..."

    local tmp; tmp=$(mktemp /tmp/causa-ocp-netpol-XXXXXX.yaml)

    # Allow from both possible Alertmanager namespaces so the policy works
    # regardless of which topology the cluster uses.
    cat > "${tmp}" << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-alertmanager-to-causa-backend
  namespace: ${INSTALL_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: causa-backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${OCP_MONITORING_NAMESPACE}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${OCP_UWM_NAMESPACE}
      ports:
        - protocol: TCP
          port: 8080
EOF

    if ! ${KUBE_CLI} apply -f "${tmp}" >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp}"
        log_error "Failed to apply NetworkPolicy for Alertmanager"
        return 1
    fi
    rm -f "${tmp}"
    write_to_log_file "SUCCESS" "NetworkPolicy applied"
    return 0
}

################################################################################
# install_openshift_prometheus
# Main entry point — auto-detects topology and configures accordingly.
################################################################################
install_openshift_prometheus() {
    log_section_silent "Configuring OpenShift Monitoring"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping OpenShift monitoring configuration"
        return 0
    fi

    # ── 1. Enable UWM ────────────────────────────────────────────────────────
    if ! _ocp_enable_user_workload_monitoring; then
        return 1
    fi

    # ── 2. Ensure install namespace exists ───────────────────────────────────
    if ! create_namespace; then return 1; fi

    # ── 3. Configure Alertmanager (topology-aware) ───────────────────────────
    if _ocp_uwm_alertmanager_present; then
        write_to_log_file "INFO" "Topology A: UWM Alertmanager detected — configuring alertmanager-user-workload"
        if ! _ocp_configure_uwm_alertmanager; then
            return 1
        fi
    else
        write_to_log_file "INFO" "Topology B: No UWM Alertmanager — configuring platform alertmanager-main"
        if ! _ocp_configure_platform_alertmanager; then
            return 1
        fi
    fi

    # ── 4. Apply PrometheusRule ───────────────────────────────────────────────
    if ! _ocp_apply_prometheus_rule; then
        return 1
    fi

    # ── 5. Apply NetworkPolicy ────────────────────────────────────────────────
    if ! _ocp_apply_network_policy; then
        return 1
    fi

    write_to_log_file "SUCCESS" "OpenShift monitoring configured"
    write_to_log_file "INFO"    "Alertmanager webhook → $(_ocp_causa_alertmanager_webhook_url)"
    return 0
}

################################################################################
# uninstall_openshift_prometheus
# Removes the webhook config, PrometheusRule, and NetworkPolicy.
################################################################################
uninstall_openshift_prometheus() {
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

    # For platform Alertmanager: restore original config (remove causa-webhook receiver).
    # We do this by re-reading the current secret and stripping the causa additions.
    if ${KUBE_CLI} get secret "${OCP_PLATFORM_ALERTMANAGER_SECRET}" \
            -n "${OCP_MONITORING_NAMESPACE}" &>/dev/null; then
        local existing
        existing=$(${KUBE_CLI} get secret "${OCP_PLATFORM_ALERTMANAGER_SECRET}" \
            -n "${OCP_MONITORING_NAMESPACE}" \
            -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if echo "${existing}" | grep -q "causa-webhook"; then
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

# Remove causa-webhook receiver
cfg["receivers"] = [r for r in cfg.get("receivers", []) if r.get("name") != "causa-webhook"]

# Remove causa-webhook child routes
route = cfg.get("route", {})
route["routes"] = [r for r in route.get("routes", []) if r.get("receiver") != "causa-webhook"]

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
                    write_to_log_file "INFO" "Platform Alertmanager restored (causa-webhook removed)"
                fi
                rm -f "${tmp_clean}"
            else
                write_to_log_file "WARN" "python3 not found — cannot automatically restore platform Alertmanager config"
                write_to_log_file "WARN" "Remove the causa-webhook receiver manually from secret '${OCP_PLATFORM_ALERTMANAGER_SECRET}' in '${OCP_MONITORING_NAMESPACE}'"
            fi
        fi
    fi

    # Remove PrometheusRule
    local prom_dir="${SCRIPT_DIR}/manifests/prometheus"
    local manifest="${prom_dir}/prometheusrule.yaml"
    if [[ -f "${manifest}" ]]; then
        local tmp; tmp=$(mktemp /tmp/causa-ocp-prom-rule-XXXXXX.yaml)
        sed "s/PLACEHOLDER_NAMESPACE/${INSTALL_NAMESPACE}/g" "${manifest}" > "${tmp}"
        ${KUBE_CLI} delete -f "${tmp}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
        rm -f "${tmp}"
        write_to_log_file "INFO" "PrometheusRule removed (or was absent)"
    fi

    # Remove NetworkPolicy
    ${KUBE_CLI} delete networkpolicy allow-alertmanager-to-causa-backend \
        -n "${INSTALL_NAMESPACE}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    write_to_log_file "INFO" "NetworkPolicy removed (or was absent)"

    write_to_log_file "SUCCESS" "OpenShift monitoring configuration removed"
    return 0
}

export -f install_openshift_prometheus
export -f uninstall_openshift_prometheus
