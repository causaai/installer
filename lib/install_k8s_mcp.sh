#!/usr/bin/env bash

################################################################################
# Kubernetes MCP Server — Installation Functions (Kind target)
#
# Uses the existing upstream image (quay.io/containers/kubernetes_mcp_server).
# Deployed as a Deployment + Service (NodePort) in the install namespace.
################################################################################

# Source guard
if [[ -n "${INSTALL_K8S_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_K8S_MCP_LIB_LOADED=1

################################################################################
# install_kubernetes_mcp_server
################################################################################
install_kubernetes_mcp_server() {
    log_section_silent "Installing Kubernetes MCP Server"

    if ! create_namespace; then return 1; fi

    local manifest="${SCRIPT_DIR}/manifests/k8s_mcp_server.yaml"
    local img="${K8S_MCP_SERVER_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*kubernetes_mcp_server.*" "${img}"; then
        log_error "Failed to apply Kubernetes MCP Server manifest"
        return 1
    fi

    if ! wait_for_deployment "kubernetes-mcp-server" "${INSTALL_NAMESPACE}" 300; then
        log_error "Kubernetes MCP Server did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Kubernetes MCP Server installed"
    write_to_log_file "INFO"    "NodePort: localhost:30000/mcp  (when port-forward is active)"
    return 0
}

################################################################################
# uninstall_kubernetes_mcp_server
################################################################################
uninstall_kubernetes_mcp_server() {
    log_section_silent "Uninstalling Kubernetes MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    local manifest="${SCRIPT_DIR}/manifests/k8s_mcp_server.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    # ClusterRole / ClusterRoleBinding are cluster-scoped — delete explicitly
    ${KUBE_CLI} delete clusterrolebinding kubernetes-mcp-server --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete clusterrole        kubernetes-mcp-server --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    write_to_log_file "SUCCESS" "Kubernetes MCP Server uninstalled"
    return 0
}

export -f install_kubernetes_mcp_server
export -f uninstall_kubernetes_mcp_server
