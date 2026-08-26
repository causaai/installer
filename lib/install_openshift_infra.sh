#!/usr/bin/env bash

################################################################################
# OpenShift Infrastructure Setup
#
# Ensures the install namespace exists as an OCP Project.
#
# Prerequisites:
#   - User must already be logged in (oc login / KUBECONFIG pointing at OCP)
################################################################################

# Source guard
if [[ -n "${INSTALL_OPENSHIFT_INFRA_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_OPENSHIFT_INFRA_LIB_LOADED=1

# Label stamped on namespaces this installer creates — used for ownership tracking.
_OCP_NS_MANAGED_LABEL="app.kubernetes.io/managed-by=causa-installer"

################################################################################
# install_openshift_infra
# Ensures the target namespace exists.
################################################################################
install_openshift_infra() {
    log_section_silent "OpenShift Namespace Setup"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping OpenShift namespace setup"
        return 0
    fi

    if ${KUBE_CLI} get namespace "${INSTALL_NAMESPACE}" &>/dev/null; then
        local phase
        phase=$(${KUBE_CLI} get namespace "${INSTALL_NAMESPACE}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Terminating" ]]; then
            log_error "Namespace '${INSTALL_NAMESPACE}' is in Terminating state — wait for deletion and retry"
            return 1
        fi
        write_to_log_file "INFO" "Namespace '${INSTALL_NAMESPACE}' already exists"
    else
        write_to_log_file "INFO" "Creating namespace: ${INSTALL_NAMESPACE}"
        if ! ${KUBE_CLI} create namespace "${INSTALL_NAMESPACE}" \
                >>"${LOG_FILE}" 2>&1; then
            log_error "Failed to create namespace '${INSTALL_NAMESPACE}'"
            return 1
        fi
        # Label so uninstall can identify namespaces we created
        ${KUBE_CLI} label namespace "${INSTALL_NAMESPACE}" \
            ${_OCP_NS_MANAGED_LABEL} --overwrite \
            >>"${LOG_FILE}" 2>&1 || true
        write_to_log_file "SUCCESS" "Namespace '${INSTALL_NAMESPACE}' created"
    fi

    write_to_log_file "SUCCESS" "OpenShift namespace ready: ${INSTALL_NAMESPACE}"
    return 0
}

################################################################################
# uninstall_openshift_infra
# The namespace is intentionally preserved to avoid accidental data loss.
# Logs a hint for manual cleanup.
################################################################################
uninstall_openshift_infra() {
    log_section_silent "OpenShift Namespace Teardown"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping OpenShift namespace teardown"
        return 0
    fi

    write_to_log_file "INFO" "Namespace '${INSTALL_NAMESPACE}' is preserved (delete manually if desired):"
    write_to_log_file "INFO" "  ${KUBE_CLI} delete namespace ${INSTALL_NAMESPACE}"
    return 0
}

export -f install_openshift_infra
export -f uninstall_openshift_infra
