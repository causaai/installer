#!/usr/bin/env bash

################################################################################
# OpenShift Infrastructure Setup
#
# Ensures the install namespace exists as an OCP Project.
# Namespace creation and deletion are handled by the shared create_namespace /
# delete_namespace functions in lib/install_utils.sh, which stamp a managed-by
# label on creation so delete_namespace can safely distinguish installer-owned
# namespaces from pre-existing ones.
#
# Prerequisites:
#   - User must already be logged in (oc login / KUBECONFIG pointing at OCP)
################################################################################

# Source guard
if [[ -n "${INSTALL_OPENSHIFT_INFRA_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_OPENSHIFT_INFRA_LIB_LOADED=1

################################################################################
# install_openshift_infra
# Ensures the target namespace exists.
################################################################################
install_openshift_infra() {
    log_section_silent "OpenShift Namespace Setup"

    if ! create_namespace; then
        return 1
    fi

    write_to_log_file "SUCCESS" "OpenShift namespace ready: ${INSTALL_NAMESPACE}"
    return 0
}

################################################################################
# uninstall_openshift_infra
# Deletes the namespace only if the installer created it (managed-by label
# present). Pre-existing namespaces are preserved to avoid data loss.
################################################################################
uninstall_openshift_infra() {
    log_section_silent "OpenShift Namespace Teardown"

    delete_namespace
}

export -f install_openshift_infra
export -f uninstall_openshift_infra
