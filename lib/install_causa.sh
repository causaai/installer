#!/usr/bin/env bash

################################################################################
# Causa Backend — Installation Functions
#
# Deploys the Causa RCA engine as a Kubernetes Deployment + Service.
# Image is configured via CAUSA_BACKEND_IMAGE (see lib/images.env).
#
# OpenShift target: applies manifests/openshift/causa-backend-manifests.yaml
#   (ConfigMap + ServiceAccount + Deployment with OCP security context +
#    ClusterIP Service) then the Route from causa-backend-route.yaml.
# kind target: applies manifests/causa/deployment.yaml (NodePort Service).
################################################################################

# Source guard
if [[ -n "${INSTALL_CAUSA_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_CAUSA_LIB_LOADED=1

################################################################################
# install_causa
################################################################################
install_causa() {
    log_section_silent "Installing Causa Backend"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    local img="${CAUSA_BACKEND_IMAGE}"
    write_to_log_file "INFO" "Using image: ${img}"

    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        # ── OpenShift path ────────────────────────────────────────────────────
        # Apply the combined OpenShift manifest (ConfigMap + ServiceAccount +
        # Deployment with OCP security context + ClusterIP Service).
        local ocp_manifest="${SCRIPT_DIR}/manifests/openshift/causa-backend-manifests.yaml"
        if ! apply_manifest "${ocp_manifest}" "${INSTALL_NAMESPACE}" \
            "image: .*causa-backend.*" "${img}"; then
            log_error "Failed to apply Causa Backend OpenShift manifests"
            return 1
        fi

        if ! wait_for_deployment "causa-backend" "${INSTALL_NAMESPACE}" 600; then
            log_error "Causa Backend did not become ready in time"
            return 1
        fi

        write_to_log_file "SUCCESS" "Causa Backend installed"
        write_to_log_file "INFO"    "Internal URL: http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080"

        local route="${SCRIPT_DIR}/manifests/openshift/causa-backend-route.yaml"
        if ! apply_manifest "${route}" "${INSTALL_NAMESPACE}"; then
            log_error "Failed to apply Causa Backend Route"
            return 1
        fi
        write_to_log_file "INFO" "Route created for Causa Backend"
    else
        # ── kind path (unchanged) ─────────────────────────────────────────────
        local manifest="${SCRIPT_DIR}/manifests/causa/deployment.yaml"
        if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
            "image: .*causa-backend.*" "${img}"; then
            log_error "Failed to apply Causa Backend manifest"
            return 1
        fi

        if ! wait_for_deployment "causa-backend" "${INSTALL_NAMESPACE}" 600; then
            log_error "Causa Backend did not become ready in time"
            return 1
        fi

        write_to_log_file "SUCCESS" "Causa Backend installed"
        write_to_log_file "INFO"    "Internal URL: http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080"
        write_to_log_file "INFO"    "NodePort: localhost:30001"
    fi

    return 0
}

################################################################################
# uninstall_causa
################################################################################
uninstall_causa() {
    log_section_silent "Uninstalling Causa Backend"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        # ── OpenShift path ────────────────────────────────────────────────────
        delete_manifest "${SCRIPT_DIR}/manifests/openshift/causa-backend-manifests.yaml" "${INSTALL_NAMESPACE}"
        delete_manifest "${SCRIPT_DIR}/manifests/openshift/causa-backend-route.yaml" "${INSTALL_NAMESPACE}"
    else
        # ── kind path (unchanged) ─────────────────────────────────────────────
        delete_manifest "${SCRIPT_DIR}/manifests/causa/deployment.yaml" "${INSTALL_NAMESPACE}"
    fi

    write_to_log_file "SUCCESS" "Causa Backend uninstalled"
    return 0
}

export -f install_causa
export -f uninstall_causa
