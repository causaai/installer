#!/usr/bin/env bash

################################################################################
# Causa Backend — Installation Functions
#
# Deploys the Causa RCA engine as a Kubernetes Deployment + Service.
# Image is configured via CAUSA_BACKEND_IMAGE (see lib/images.env).
#
# After the deployment is ready, stamps three MCP endpoint env vars via
# `kubectl set env` so they are always current regardless of re-runs:
#   CAUSA_MCP_QUARKUS_ENDPOINT         — Quarkus MCP server
#   CAUSA_MCP_QUARKUS_METRICS_BASE_URL — target Quarkus app under analysis
#   CAUSA_MCP_ASYNC_PROFILER_ENDPOINT  — Jafra MCP server (async-profiler)
#
# OpenShift target: applies manifests/openshift/causa/ files
#   (serviceaccount, configmap, deployment, service, route).
# kind target: applies manifests/causa/deployment.yaml (NodePort Service).
################################################################################

# Source guard
if [[ -n "${INSTALL_CAUSA_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_CAUSA_LIB_LOADED=1

# Seconds to wait for the causa-backend Deployment to become Available
CAUSA_DEPLOY_TIMEOUT="${CAUSA_DEPLOY_TIMEOUT:-600}"

# ---------------------------------------------------------------------------
# _causa_mcp_endpoints — compute the three endpoint values for the current
# install target and namespace.  These are always derived from the cluster's
# internal DNS so they work on every run without hard-coding a namespace.
# ---------------------------------------------------------------------------
_causa_mcp_endpoints() {
    local ns="${INSTALL_NAMESPACE}"

    CAUSA_MCP_QUARKUS_ENDPOINT_VALUE="http://mcp-metrics.${ns}.svc.cluster.local:8080"
    CAUSA_MCP_ASYNC_PROFILER_ENDPOINT_VALUE="http://jafra-mcp.${ns}.svc.cluster.local:8083"

    # CAUSA_MCP_QUARKUS_METRICS_BASE_URL points to the *target* Quarkus app
    # under analysis — not our own infrastructure.  It is user-supplied via the
    # CAUSA_MCP_QUARKUS_METRICS_BASE_URL env var (exported from install.sh) and
    # defaults to an empty string when not provided.
    CAUSA_MCP_QUARKUS_METRICS_BASE_URL_VALUE="${CAUSA_MCP_QUARKUS_METRICS_BASE_URL:-}"
}

# ---------------------------------------------------------------------------
# _set_causa_env_vars — stamp the three env vars onto the running Deployment
# using `kubectl set env` (idempotent — safe to call on every install run).
# ---------------------------------------------------------------------------
_set_causa_env_vars() {
    local ns="${INSTALL_NAMESPACE}"

    _causa_mcp_endpoints

    write_to_log_file "INFO" "Setting Causa Backend env vars:"
    write_to_log_file "INFO" "  CAUSA_MCP_QUARKUS_ENDPOINT         = ${CAUSA_MCP_QUARKUS_ENDPOINT_VALUE}"
    write_to_log_file "INFO" "  CAUSA_MCP_QUARKUS_METRICS_BASE_URL = ${CAUSA_MCP_QUARKUS_METRICS_BASE_URL_VALUE}"
    write_to_log_file "INFO" "  CAUSA_MCP_ASYNC_PROFILER_ENDPOINT  = ${CAUSA_MCP_ASYNC_PROFILER_ENDPOINT_VALUE}"

    if ! ${KUBE_CLI} set env deployment/causa-backend \
            -n "${ns}" \
            "CAUSA_MCP_QUARKUS_ENDPOINT=${CAUSA_MCP_QUARKUS_ENDPOINT_VALUE}" \
            "CAUSA_MCP_QUARKUS_METRICS_BASE_URL=${CAUSA_MCP_QUARKUS_METRICS_BASE_URL_VALUE}" \
            "CAUSA_MCP_ASYNC_PROFILER_ENDPOINT=${CAUSA_MCP_ASYNC_PROFILER_ENDPOINT_VALUE}" \
            >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to set env vars on causa-backend deployment"
        return 1
    fi

    write_to_log_file "SUCCESS" "Causa Backend env vars set"
    return 0
}

# ---------------------------------------------------------------------------
# _rollout_causa — wait for the deployment rollout to complete after env
# injection (the set env triggers a new rollout; 180 s timeout per spec).
# ---------------------------------------------------------------------------
_rollout_causa() {
    local ns="${INSTALL_NAMESPACE}"
    write_to_log_file "INFO" "Waiting for Causa Backend rollout to complete..."
    if ! ${KUBE_CLI} rollout status deployment/causa-backend \
            -n "${ns}" \
            --timeout=180s \
            >>"${LOG_FILE}" 2>&1; then
        log_error "Causa Backend rollout did not complete within 180s"
        return 1
    fi
    write_to_log_file "SUCCESS" "Causa Backend rollout complete"
    return 0
}

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

    # Resolve the quarkus metrics base URL placeholder value (may be empty).
    # Escape characters that are special in a sed replacement string so that
    # URLs containing '&', '\', or the '|' delimiter are not corrupted.
    local quarkus_metrics_base_url="${CAUSA_MCP_QUARKUS_METRICS_BASE_URL:-}"
    # Escape backslashes first (must be first), then '&', then the delimiter '|'.
    local quarkus_metrics_base_url_escaped="${quarkus_metrics_base_url//\\/\\\\}"
    quarkus_metrics_base_url_escaped="${quarkus_metrics_base_url_escaped//&/\\&}"
    quarkus_metrics_base_url_escaped="${quarkus_metrics_base_url_escaped//|/\\|}"

    # Apply the MCP config ConfigMap — mounts mcp.json at /etc/causa inside the pod.
    # Applies to both kind and OpenShift; must exist before the deployment starts.
    # Built from target-specific mcp.json via --from-file; labels are stamped
    # afterwards with `kubectl label` (--labels on create configmap requires >=1.36).
    # Only stderr is redirected to the log so the YAML stdout reaches the temp file.
    local mcp_json
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        mcp_json="${SCRIPT_DIR}/manifests/openshift/causa/mcp.json"
    else
        mcp_json="${SCRIPT_DIR}/manifests/causa/mcp.json"
    fi

    if [[ ! -f "${mcp_json}" ]]; then
        log_error "MCP config file not found: ${mcp_json}"
        return 1
    fi

    local tmp_mcp_cm
    if ! tmp_mcp_cm=$(mktemp /tmp/causa-$$-mcp-configmap-XXXXXX.yaml); then
        log_error "Failed to create temporary file for Causa MCP ConfigMap"
        return 1
    fi
    if ! ${KUBE_CLI} create configmap causa-mcp-config \
            --from-file=mcp.json="${mcp_json}" \
            --namespace="${INSTALL_NAMESPACE}" \
            --dry-run=client -o yaml \
            2>>"${LOG_FILE}" \
            > "${tmp_mcp_cm}"; then
        rm -f "${tmp_mcp_cm}"
        log_error "Failed to generate Causa MCP ConfigMap YAML"
        return 1
    fi
    if ! ${KUBE_CLI} apply -f "${tmp_mcp_cm}" >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp_mcp_cm}"
        log_error "Failed to apply Causa MCP ConfigMap"
        return 1
    fi
    rm -f "${tmp_mcp_cm}"
    if ! ${KUBE_CLI} label configmap causa-mcp-config \
            -n "${INSTALL_NAMESPACE}" \
            app=causa-backend \
            app.kubernetes.io/component=rca-engine \
            --overwrite >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to label Causa MCP ConfigMap"
        return 1
    fi
    write_to_log_file "SUCCESS" "Manifest applied: ${mcp_json}"

    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        local ocp_dir="${SCRIPT_DIR}/manifests/openshift/causa"

        apply_manifest "${ocp_dir}/serviceaccount.yaml" "${INSTALL_NAMESPACE}" || return 1

        # configmap contains PLACEHOLDER_NAMESPACE and PLACEHOLDER_QUARKUS_METRICS_BASE_URL
        local tmp_cm
        if ! tmp_cm=$(mktemp /tmp/causa-$$-configmap-XXXXXX.yaml); then
            log_error "Failed to create temporary file for Causa Backend ConfigMap"
            return 1
        fi
        sed -e "s/PLACEHOLDER_NAMESPACE/${INSTALL_NAMESPACE}/g" \
            -e "s|PLACEHOLDER_QUARKUS_METRICS_BASE_URL|${quarkus_metrics_base_url_escaped}|g" \
            "${ocp_dir}/configmap.yaml" > "${tmp_cm}"
        if ! ${KUBE_CLI} apply -f "${tmp_cm}" >>"${LOG_FILE}" 2>&1; then
            rm -f "${tmp_cm}"
            log_error "Failed to apply Causa Backend ConfigMap"
            return 1
        fi
        rm -f "${tmp_cm}"
        write_to_log_file "SUCCESS" "Manifest applied: ${ocp_dir}/configmap.yaml"

        if ! apply_manifest "${ocp_dir}/deployment.yaml" "${INSTALL_NAMESPACE}" \
            "image: .*causa-backend.*" "${img}"; then
            log_error "Failed to apply Causa Backend deployment"
            return 1
        fi
        apply_manifest "${ocp_dir}/service.yaml" "${INSTALL_NAMESPACE}" || return 1

        wait_for_deployment "causa-backend" "${INSTALL_NAMESPACE}" "${CAUSA_DEPLOY_TIMEOUT}" || return 1

         # Stamp the three MCP endpoint env vars and wait for the triggered rollout
        if ! _set_causa_env_vars; then
            return 1
        fi
        if ! _rollout_causa; then
            return 1
        fi

        write_to_log_file "SUCCESS" "Causa Backend installed"
        write_to_log_file "INFO"    "Internal URL: http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080"

        if ! apply_manifest "${ocp_dir}/route.yaml" "${INSTALL_NAMESPACE}"; then
            log_error "Failed to apply Causa Backend Route"
            return 1
        fi
        write_to_log_file "INFO" "Route created for Causa Backend"
    else
        # ── kind path ─────────────────────────────────────────────────────────

        # Build a temp manifest with all placeholders substituted (namespace,
        # cluster type, and the Quarkus metrics base URL).
        local manifest="${SCRIPT_DIR}/manifests/causa/deployment.yaml"
        local tmp
        if ! tmp=$(mktemp /tmp/causa-$$-manifest-XXXXXX.yaml); then
            log_error "Failed to create temporary file for Causa Backend manifest"
            return 1
        fi
        sed -e "s/PLACEHOLDER_NAMESPACE/${INSTALL_NAMESPACE}/g" \
            -e "s/PLACEHOLDER_CLUSTER_TYPE/${INSTALL_TARGET:-kind}/g" \
            -e "s|image: .*causa-backend.*|image: ${img}|g" \
            -e "s|PLACEHOLDER_QUARKUS_METRICS_BASE_URL|${quarkus_metrics_base_url_escaped}|g" \
            "${manifest}" > "${tmp}"
        if ! ${KUBE_CLI} apply -f "${tmp}" >>"${LOG_FILE}" 2>&1; then
            rm -f "${tmp}"
            log_error "Failed to apply Causa Backend manifest"
            return 1
        fi
        rm -f "${tmp}"
        write_to_log_file "SUCCESS" "Manifest applied: ${manifest}"

        wait_for_deployment "causa-backend" "${INSTALL_NAMESPACE}" "${CAUSA_DEPLOY_TIMEOUT}" || return 1

        # Stamp the three MCP endpoint env vars and wait for the triggered rollout
        if ! _set_causa_env_vars; then
            return 1
        fi
        if ! _rollout_causa; then
            return 1
        fi
        write_to_log_file "SUCCESS" "Causa Backend installed"
        write_to_log_file "INFO"    "Internal URL: http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080"
        write_to_log_file "INFO"    "Host access: kubectl port-forward svc/causa-backend 30001:8080 -n ${INSTALL_NAMESPACE}"
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

    # Delete the backend Deployment first so no pods are left referencing the
    # ConfigMap volume mount.  Deployment deletion errors are propagated so a
    # broken Deployment is never silently left behind.
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        local ocp_dir="${SCRIPT_DIR}/manifests/openshift/causa"
        delete_manifest "${ocp_dir}/route.yaml"          "${INSTALL_NAMESPACE}"
        if ! delete_manifest "${ocp_dir}/deployment.yaml" "${INSTALL_NAMESPACE}"; then
            log_error "Failed to delete Causa Backend deployment"
            return 1
        fi
        delete_manifest "${ocp_dir}/service.yaml"        "${INSTALL_NAMESPACE}"
        delete_manifest "${ocp_dir}/configmap.yaml"      "${INSTALL_NAMESPACE}"
        delete_manifest "${ocp_dir}/serviceaccount.yaml" "${INSTALL_NAMESPACE}"
    else
        if ! delete_manifest "${SCRIPT_DIR}/manifests/causa/deployment.yaml" "${INSTALL_NAMESPACE}"; then
            log_error "Failed to delete Causa Backend deployment"
            return 1
        fi
    fi

    # Delete MCP config ConfigMap only after the Deployment is gone so no pod
    # is left with a missing required volume mount.
    if ! ${KUBE_CLI} delete configmap causa-mcp-config -n "${INSTALL_NAMESPACE}" --ignore-not-found >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to delete Causa MCP ConfigMap"
        return 1
    fi

    write_to_log_file "SUCCESS" "Causa Backend uninstalled"
    return 0
}

################################################################################
# causa_backend_health — post-install health check used by registry_check_health
################################################################################
causa_backend_health() {
    check_deployment_healthy "causa-backend"
}

export -f install_causa
export -f uninstall_causa
export -f causa_backend_health
