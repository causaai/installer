#!/usr/bin/env bash

################################################################################
# Causa MCP Server — Installation Functions
#
# Wraps the Causa Backend REST API as MCP tools:
#   - list_diagnostics()    → GET /api/v1/diagnostics
#   - get_diagnostic(id)    → GET /api/v1/diagnostics/{id}
#
# Image: configured via CAUSA_MCP_IMAGE (see lib/images.env).
# NodePort: 30005
################################################################################

# Source guard
if [[ -n "${INSTALL_CAUSA_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_CAUSA_MCP_LIB_LOADED=1

# Seconds to wait for an MCP server Deployment to become Available
MCP_DEPLOY_TIMEOUT="${MCP_DEPLOY_TIMEOUT:-300}"

################################################################################
# _with_causa_mcp_lock
# Serializes install and uninstall operations targeting the same namespace.
################################################################################
_with_causa_mcp_lock() {
    local ns="$1"
    shift
    local lock_dir="${TMPDIR:-/tmp}/causa-mcp-${ns}.lock"
    local waited=0
    local max_wait=30

    while ! mkdir "${lock_dir}" 2>/dev/null; do
        if [[ ${waited} -ge ${max_wait} ]]; then
            log_error "Timed out waiting for lock on Causa MCP operations in namespace '${ns}'"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    local rc=0
    "$@" || rc=$?
    rmdir "${lock_dir}" 2>/dev/null || true
    return ${rc}
}

################################################################################
# _validate_causa_backend_ready
# Checks that the Causa Backend deployment exists and is fully available before
# installing the Causa MCP Server, which depends on it at startup.
################################################################################
_validate_causa_backend_ready() {
    local ns="${INSTALL_NAMESPACE}"
    local deploy="causa-backend"

    write_to_log_file "INFO" "Checking Causa Backend is ready before installing Causa MCP Server..."

    if ! ${KUBE_CLI} get deployment "${deploy}" -n "${ns}" &>/dev/null; then
        log_error "Causa Backend deployment not found in namespace '${ns}'."
        log_error "Causa MCP Server requires Causa Backend to be installed first."
        return 1
    fi

    # readyReplicas is absent from the status JSON (not "0") when no pods are up,
    # so we must default an empty result to "0" explicitly after command substitution.
    local ready desired
    ready=$(${KUBE_CLI} get deployment "${deploy}" -n "${ns}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    ready="${ready:-0}"
    desired=$(${KUBE_CLI} get deployment "${deploy}" -n "${ns}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)
    desired="${desired:-0}"

    # A deployment scaled to 0 is explicitly stopped — treat as not ready.
    if [[ "${desired}" -eq 0 ]] 2>/dev/null || [[ "${ready}" != "${desired}" ]]; then
        log_error "Causa Backend is not ready (${ready}/${desired} replicas)."
        log_error "Causa MCP Server requires Causa Backend to be fully running first."
        log_error "Scale it back up:  ${KUBE_CLI} scale deployment ${deploy} -n ${ns} --replicas=1"
        return 1
    fi

    write_to_log_file "SUCCESS" "Causa Backend is ready (${ready}/${desired} replicas)"
    return 0
}

################################################################################
# _generate_causa_mcp_manifest
# Dynamically adapts upstream manifests to the target environment without
# modifying the raw upstream files on disk.
################################################################################
_generate_causa_mcp_manifest() {
    local src="$1"
    local ns="$2"
    local img="$3"
    local target="$4"
    local out="$5"

    if [[ "${target}" == "openshift" ]]; then
        sed -e "s|image: .*|image: ${img}|g" \
            -e "s|http://causa-backend:[0-9]*|http://causa-backend.${ns}.svc.cluster.local:8080|g" \
            -e "s|http://causa-backend\.[^:]*:8080|http://causa-backend.${ns}.svc.cluster.local:8080|g" \
            -e "s|value: \"openshift\"|value: \"${target}\"|g" \
            "${src}" > "${out}"
    else
        # For kind/k8s: strip standalone kind: Namespace document, parameterize namespace, image, backend url, cluster name
        awk '
            BEGIN { doc="" }
            /^---/ {
                if (doc !~ /kind:[[:space:]]*Namespace/) {
                    printf "%s", doc
                }
                doc = "---\n"
                next
            }
            { doc = doc $0 "\n" }
            END {
                if (doc !~ /kind:[[:space:]]*Namespace/) {
                    printf "%s", doc
                }
            }
        ' "${src}" | sed \
            -e "s/namespace: causa/namespace: ${ns}/g" \
            -e "s|image: .*|image: ${img}|g" \
            -e "s|imagePullPolicy: Never|imagePullPolicy: IfNotPresent|g" \
            -e "s|http://causa-backend[^\"']*|http://causa-backend.${ns}.svc.cluster.local:8080|g" \
            -e "s|value: \"kind\"|value: \"${target}\"|g" \
            > "${out}"
    fi
}

################################################################################
# _uninstall_causa_mcp_resources
# Deletes resources defined by the target manifest and cleans up any OpenShift route.
################################################################################
_uninstall_causa_mcp_resources() {
    local ns="${INSTALL_NAMESPACE}"
    local target="${INSTALL_TARGET:-kind}"
    local img="${CAUSA_MCP_IMAGE}"
    local manifest
    if _is_openshift_target; then
        manifest="${SCRIPT_DIR}/manifests/causa_mcp/causa-mcp-server-openshift.yaml"
    else
        manifest="${SCRIPT_DIR}/manifests/causa_mcp/causa-mcp-server.yaml"
    fi

    local tmp
    tmp=$(make_temp causa-mcp) || { log_error "Failed to create temp file"; return 1; }

    _generate_causa_mcp_manifest "${manifest}" "${ns}" "${img}" "${target}" "${tmp}"

    local rc=0
    ${KUBE_CLI} delete -f "${tmp}" -n "${ns}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || rc=$?
    rm -f "${tmp}"

    # Always ensure OpenShift route is removed even if default kind target is used on uninstall
    ${KUBE_CLI} delete route causa-mcp -n "${ns}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    return ${rc}
}

################################################################################
# _install_causa_mcp_impl
################################################################################
_install_causa_mcp_impl() {
    log_section_silent "Installing Causa MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if ! _validate_causa_backend_ready; then
        return 1
    fi

    local manifest
    if _is_openshift_target; then
        manifest="${SCRIPT_DIR}/manifests/causa_mcp/causa-mcp-server-openshift.yaml"
    else
        manifest="${SCRIPT_DIR}/manifests/causa_mcp/causa-mcp-server.yaml"
    fi

    local img="${CAUSA_MCP_IMAGE}"
    local ns="${INSTALL_NAMESPACE}"
    local target="${INSTALL_TARGET:-kind}"

    write_to_log_file "INFO" "Using image: ${img}"
    write_to_log_file "INFO" "Applying Causa MCP manifest: ${manifest}"

    local tmp
    tmp=$(make_temp causa-mcp) || { log_error "Failed to create temp file"; return 1; }

    _generate_causa_mcp_manifest "${manifest}" "${ns}" "${img}" "${target}" "${tmp}"

    local rc=0
    ${KUBE_CLI} apply -f "${tmp}" -n "${ns}" >>"${LOG_FILE}" 2>&1 || rc=$?
    rm -f "${tmp}"

    if [[ ${rc} -ne 0 ]]; then
        log_error "Failed to apply Causa MCP manifest"
        _uninstall_causa_mcp_resources || true
        return 1
    fi

    if ! wait_for_deployment "causa-mcp" "${ns}" "${MCP_DEPLOY_TIMEOUT}"; then
        log_error "Causa MCP deployment readiness check failed; rolling back resources"
        _uninstall_causa_mcp_resources || true
        return 1
    fi

    if _is_openshift_target; then
        write_to_log_file "INFO" "OpenShift Route applied for Causa MCP Server"
    else
        write_to_log_file "INFO" "Host access: kubectl port-forward svc/causa-mcp 30005:8081 -n ${ns}"
    fi

    write_to_log_file "SUCCESS" "Causa MCP Server installed"
    return 0
}

################################################################################
# _uninstall_causa_mcp_impl
################################################################################
_uninstall_causa_mcp_impl() {
    log_section_silent "Uninstalling Causa MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    if ! _uninstall_causa_mcp_resources; then
        log_error "Failed to delete Causa MCP resources"
        return 1
    fi

    write_to_log_file "SUCCESS" "Causa MCP Server uninstalled"
    return 0
}

################################################################################
# install_causa_mcp
################################################################################
install_causa_mcp() {
    _with_causa_mcp_lock "${INSTALL_NAMESPACE}" _install_causa_mcp_impl
}

################################################################################
# uninstall_causa_mcp
################################################################################
uninstall_causa_mcp() {
    _with_causa_mcp_lock "${INSTALL_NAMESPACE}" _uninstall_causa_mcp_impl
}

################################################################################
# causa_mcp_health — post-install health check used by registry_check_health
################################################################################
causa_mcp_health() {
    check_deployment_healthy "causa-mcp"
}

export -f _validate_causa_backend_ready
export -f install_causa_mcp
export -f uninstall_causa_mcp
export -f causa_mcp_health
