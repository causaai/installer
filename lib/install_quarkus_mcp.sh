#!/usr/bin/env bash

################################################################################
# Quarkus MCP Server — Installation Functions
################################################################################

# Source guard
if [[ -n "${INSTALL_QUARKUS_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_QUARKUS_MCP_LIB_LOADED=1

_quarkus_mcp_not_released() {
    [[ -z "${QUARKUS_MCP_IMAGE:-}" ]]
}

################################################################################
# install_quarkus_mcp
################################################################################
# OCP UWM Prometheus service URL (used when INSTALL_TARGET=openshift)
_OCP_PROMETHEUS_URL="http://prometheus-user-workload.openshift-user-workload-monitoring.svc.cluster.local:9090"

install_quarkus_mcp() {
    log_section_silent "Installing Quarkus MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if _quarkus_mcp_not_released; then
        log_warn "Quarkus MCP Server: image not yet released — skipping (set QUARKUS_MCP_IMAGE in lib/images.env to enable)"
        return 0
    fi

    # Quarkus MCP queries Prometheus for metrics.  On kind we must verify that
    # Prometheus (kube-prometheus-stack) is running before deploying.
    # On OpenShift, Prometheus is provided by User Workload Monitoring OOB so
    # the check is skipped automatically inside validate_prometheus_available.
    if ! validate_prometheus_available; then
        log_error "Quarkus MCP Server requires Prometheus — see above for install instructions"
        return 1
    fi

    local manifest="${SCRIPT_DIR}/manifests/quarkus_mcp/deployment.yaml"
    local img="${QUARKUS_MCP_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"

    # Select the correct Prometheus URL for the target platform
    local prom_url
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        prom_url="${_OCP_PROMETHEUS_URL}"
        write_to_log_file "INFO" "Using OpenShift UWM Prometheus URL: ${prom_url}"
    else
        prom_url="http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
        write_to_log_file "INFO" "Using kube-prometheus-stack URL: ${prom_url}"
    fi

    local tmp; tmp=$(mktemp /tmp/causa-rca-$$-manifest-XXXXXX.yaml)
    sed -e "s/PLACEHOLDER_NAMESPACE/${INSTALL_NAMESPACE}/g" \
        -e "s|image: .*quarkus-mcp.*|image: ${img}|g" \
        -e "s|PROMETHEUS_URL:.*|PROMETHEUS_URL: \"${prom_url}\"|g" \
        "${manifest}" > "${tmp}"
    if ! ${KUBE_CLI} apply -f "${tmp}" >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp}"
        log_error "Failed to apply Quarkus MCP manifest"
        return 1
    fi
    rm -f "${tmp}"

    if ! wait_for_deployment "mcp-metrics" "${INSTALL_NAMESPACE}" 300; then
        log_error "Quarkus MCP did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Quarkus MCP Server installed"

    # On OpenShift expose via a Route
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        local route="${SCRIPT_DIR}/manifests/openshift/quarkus-mcp-route.yaml"
        if ! apply_manifest "${route}" "${INSTALL_NAMESPACE}"; then
            log_error "Failed to apply Quarkus MCP Server Route"
            return 1
        fi
        write_to_log_file "INFO" "Route created for Quarkus MCP Server"
    else
        write_to_log_file "INFO" "NodePort: localhost:30004"
    fi
    return 0
}

################################################################################
# uninstall_quarkus_mcp
################################################################################
uninstall_quarkus_mcp() {
    log_section_silent "Uninstalling Quarkus MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    if _quarkus_mcp_not_released; then
        write_to_log_file "INFO" "Quarkus MCP Server: image not released — nothing to uninstall"
        return 0
    fi

    local manifest="${SCRIPT_DIR}/manifests/quarkus_mcp/deployment.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    # Remove Route on OpenShift
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        delete_manifest "${SCRIPT_DIR}/manifests/openshift/quarkus-mcp-route.yaml" "${INSTALL_NAMESPACE}"
    fi

    write_to_log_file "SUCCESS" "Quarkus MCP Server uninstalled"
    return 0
}

export -f install_quarkus_mcp
export -f uninstall_quarkus_mcp
