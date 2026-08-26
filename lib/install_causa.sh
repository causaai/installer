#!/usr/bin/env bash

################################################################################
# Causa Backend — Installation Functions
#
# Deploys the Causa RCA engine as a Kubernetes Deployment + Service.
# Image is configured via CAUSA_BACKEND_IMAGE (see lib/images.env).
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

    if ! create_namespace; then return 1; fi

    # Resync causa-db-secrets from the live CNPG secret on every run to handle
    # password rotation.
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        write_to_log_file "INFO" "Syncing DB credentials from CNPG secret..."
        local cnpg_secret="${_CNPG_DB_CLUSTER_NAME}-app"
        local db_user db_pass
        db_user=$(${KUBE_CLI} get secret "${cnpg_secret}" -n "${INSTALL_NAMESPACE}" \
            -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
        db_pass=$(${KUBE_CLI} get secret "${cnpg_secret}" -n "${INSTALL_NAMESPACE}" \
            -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
        if [[ -z "${db_user}" || -z "${db_pass}" ]]; then
            log_error "Failed to read credentials from CNPG secret '${cnpg_secret}' — is PostgreSQL installed?"
            return 1
        fi
        ${KUBE_CLI} delete secret "${_PG_SECRET_NAME}" \
            -n "${INSTALL_NAMESPACE}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
        if ! ${KUBE_CLI} create secret generic "${_PG_SECRET_NAME}" \
            -n "${INSTALL_NAMESPACE}" \
            --from-literal=CAUSA_DB_USERNAME="${db_user}" \
            --from-literal=CAUSA_DB_PASSWORD="${db_pass}" \
            --from-literal=CAUSA_DB_URL="jdbc:postgresql://iri-db-rw.${INSTALL_NAMESPACE}.svc.cluster.local:5432/${_PG_DB_NAME}" \
            >>"${LOG_FILE}" 2>&1; then
            log_error "Failed to sync ${_PG_SECRET_NAME}"
            return 1
        fi
        write_to_log_file "SUCCESS" "DB credentials synced (user: ${db_user})"
    fi

    local manifest="${SCRIPT_DIR}/manifests/causa/deployment.yaml"
    local img="${CAUSA_BACKEND_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"

    local tmp; tmp=$(mktemp /tmp/causa-rca-manifest-XXXXXX.yaml)
    sed -e "s/PLACEHOLDER_NAMESPACE/${INSTALL_NAMESPACE}/g" \
        -e "s|image: .*causa-backend.*|image: ${img}|g" \
        -e "s|value: \"kind\"|value: \"${INSTALL_TARGET:-kind}\"|g" \
        "${manifest}" > "${tmp}"
    if ! ${KUBE_CLI} apply -f "${tmp}" >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp}"
        log_error "Failed to apply Causa Backend manifest"
        return 1
    fi
    rm -f "${tmp}"

    if ! wait_for_deployment "causa-backend" "${INSTALL_NAMESPACE}" 600; then
        log_error "Causa Backend did not become ready in time"
        return 1
    fi

    write_to_log_file "SUCCESS" "Causa Backend installed"
    write_to_log_file "INFO"    "Internal URL: http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080"

    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        local route="${SCRIPT_DIR}/manifests/openshift/causa-backend-route.yaml"
        if ! apply_manifest "${route}" "${INSTALL_NAMESPACE}"; then
            log_error "Failed to apply Causa Backend Route"
            return 1
        fi
        write_to_log_file "INFO" "Route created for Causa Backend"
    else
        write_to_log_file "INFO" "NodePort: localhost:30001"
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

    local manifest="${SCRIPT_DIR}/manifests/causa/deployment.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        delete_manifest "${SCRIPT_DIR}/manifests/openshift/causa-backend-route.yaml" "${INSTALL_NAMESPACE}"
    fi

    write_to_log_file "SUCCESS" "Causa Backend uninstalled"
    return 0
}

export -f install_causa
export -f uninstall_causa
