#!/usr/bin/env bash

################################################################################
# Prometheus MCP Server — Installation Functions
#
# Deploys the Prometheus MCP Server (ghcr.io/tjhop/prometheus-mcp-server) on
# Kind clusters, enabling MCP clients and AI agents to execute PromQL queries
# (instant and range) over Streamable HTTP (/mcp) against the in-cluster
# Prometheus instance.
#
# Kind:       plain HTTP against prometheus-operated.monitoring.svc.cluster.local:9090
# OpenShift:  not yet supported (reserved for future implementation)
################################################################################

# Source guard
if [[ -n "${INSTALL_PROMETHEUS_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_PROMETHEUS_MCP_LIB_LOADED=1

# Seconds to wait for an MCP server Deployment to become Available
MCP_DEPLOY_TIMEOUT="${MCP_DEPLOY_TIMEOUT:-300}"

################################################################################
# _prometheus_mcp_not_released
# Returns 0 (true) when PROMETHEUS_MCP_SERVER_IMAGE is unset — install is skipped.
################################################################################
_prometheus_mcp_not_released() {
    [[ -z "${PROMETHEUS_MCP_SERVER_IMAGE:-}" ]]
}

################################################################################
# discover_prometheus_url
# Discovers the in-cluster Prometheus query endpoint URL in PROMETHEUS_NAMESPACE.
#
# Primary:  kubectl get svc prometheus-operated  (Prometheus Operator default)
# Fallback: label selector app.kubernetes.io/name=prometheus
# Returns:  http://<svc>.<ns>.svc.cluster.local:9090
################################################################################
discover_prometheus_url() {
    local prom_ns="${PROMETHEUS_NAMESPACE:-monitoring}"

    write_to_log_file "INFO" "Discovering Prometheus query endpoint in namespace '${prom_ns}'..."

    local svc_name
    svc_name=$(${KUBE_CLI} get svc "prometheus-operated" \
        -n "${prom_ns}" \
        -o jsonpath='{.metadata.name}' 2>/dev/null || true)

    if [[ -z "${svc_name}" ]]; then
        svc_name=$(${KUBE_CLI} get svc \
            -n "${prom_ns}" \
            -l "app.kubernetes.io/name=prometheus" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi

    if [[ -n "${svc_name}" ]]; then
        local url="http://${svc_name}.${prom_ns}.svc.cluster.local:9090"
        write_to_log_file "SUCCESS" "Found Prometheus endpoint: ${url}"
        echo "${url}"
        return 0
    fi

    log_error "Could not find a Prometheus service in namespace '${prom_ns}'."
    return 1
}

################################################################################
# install_prometheus_mcp_server
################################################################################
install_prometheus_mcp_server() {
    log_section_silent "Installing Prometheus MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if _prometheus_mcp_not_released; then
        log_warn "Prometheus MCP Server: image not configured — skipping (set PROMETHEUS_MCP_SERVER_IMAGE in lib/images.env to enable)"
        return 2   # nothing deployed: module runner must not report it as installed
    fi

    # OpenShift is not yet supported — skip cleanly instead of falling through
    # to discover_prometheus_url (which looks for prometheus-operated in the
    # monitoring namespace, a service that doesn't exist on OpenShift).
    if [[ "${INSTALL_TARGET:-kind}" != "kind" ]]; then
        write_to_log_file "INFO" "Prometheus MCP Server: skipping — OpenShift target not yet supported"
        return 2   # nothing deployed
    fi

    # Prometheus MCP queries Prometheus for metrics. Verify Prometheus is running.
    if ! validate_prometheus_available; then
        log_error "Prometheus MCP Server requires Prometheus — see above for install instructions"
        return 1
    fi

    if ! create_namespace; then return 1; fi

    local prometheus_url
    if ! prometheus_url=$(discover_prometheus_url); then
        return 1
    fi

    local manifest="${SCRIPT_DIR}/manifests/prometheus_mcp/deployment.yaml"
    local img="${PROMETHEUS_MCP_SERVER_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"
    write_to_log_file "INFO" "Using Prometheus URL: ${prometheus_url}"

    local tmp
    if ! tmp=$(mktemp /tmp/causa-$$-prom-mcp-XXXXXX.yaml); then
        log_error "Failed to create temporary file for Prometheus MCP manifest"
        return 1
    fi

    sed -e "s/PLACEHOLDER_NAMESPACE/${INSTALL_NAMESPACE}/g" \
        -e "s|image: .*prometheus-mcp-server.*|image: ${img}|g" \
        -e "s|value: \"http://prometheus-operated.monitoring.svc.cluster.local:9090\"|value: \"${prometheus_url}\"|g" \
        "${manifest}" > "${tmp}"

    if ! ${KUBE_CLI} apply -f "${tmp}" >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp}"
        log_error "Failed to apply Prometheus MCP manifest"
        return 1
    fi
    rm -f "${tmp}"
    write_to_log_file "SUCCESS" "Manifest applied: ${manifest}"

    if ! wait_for_deployment "prometheus-mcp-server" "${INSTALL_NAMESPACE}" "${MCP_DEPLOY_TIMEOUT}"; then
        log_error "Prometheus MCP Server did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Prometheus MCP Server installed"
    write_to_log_file "INFO"    "Internal URL: http://prometheus-mcp-server.${INSTALL_NAMESPACE}.svc.cluster.local:8080"
    return 0
}

################################################################################
# uninstall_prometheus_mcp_server
################################################################################
uninstall_prometheus_mcp_server() {
    log_section_silent "Uninstalling Prometheus MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    # Prometheus MCP Server is not installed on OpenShift — skip cleanly to avoid
    # accidentally deleting a same-named resource we do not own.
    if [[ "${INSTALL_TARGET:-kind}" != "kind" ]]; then
        write_to_log_file "INFO" "Prometheus MCP Server: skipping uninstall — OpenShift target not yet supported"
        return 0
    fi

    if ! ${KUBE_CLI} get deployment prometheus-mcp-server -n "${INSTALL_NAMESPACE}" &>/dev/null && \
       ! ${KUBE_CLI} get service prometheus-mcp-server -n "${INSTALL_NAMESPACE}" &>/dev/null; then
        write_to_log_file "INFO" "Prometheus MCP Server not found — nothing to remove"
        return 0
    fi

    local manifest="${SCRIPT_DIR}/manifests/prometheus_mcp/deployment.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    write_to_log_file "SUCCESS" "Prometheus MCP Server uninstalled"
    return 0
}

################################################################################
# prometheus_mcp_health — post-install health check used by registry_check_health
################################################################################
prometheus_mcp_health() {
    check_deployment_healthy "prometheus-mcp-server"
}

export -f discover_prometheus_url
export -f install_prometheus_mcp_server
export -f uninstall_prometheus_mcp_server
export -f prometheus_mcp_health
