#!/usr/bin/env bash

################################################################################
# Validator Library — Causa RCA Installer
#
# Pre-flight checks: required CLI tools, Docker, cluster access, RBAC.
################################################################################

# Prevent multiple sourcing
if [[ -n "${VALIDATOR_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly VALIDATOR_LIB_LOADED=1

################################################################################
# validate_prerequisites
# Checks that all required CLI tools are present.
################################################################################
validate_prerequisites() {
    log_file_only "Validating Prerequisites"

    local missing=()

    # Core tools always required (kind is only needed for the kind target)
    local required_tools=("kubectl" "curl" "grep" "sed" "awk")
    if [[ "${INSTALL_TARGET:-kind}" == "kind" ]]; then
        required_tools+=("kind")
    fi

    # Accept either docker or podman as the container runtime (kind target only)
    local container_runtime=""
    if [[ "${INSTALL_TARGET:-kind}" == "kind" ]]; then
        if check_command_exists "docker"; then
            container_runtime="docker"
        elif check_command_exists "podman"; then
            container_runtime="podman"
        fi
        [[ -z "${container_runtime}" ]] && required_tools+=("docker")  # will fail with a clear message
    fi

    for tool in "${required_tools[@]}"; do
        if ! check_command_exists "${tool}"; then
            log_error "Required tool not found: ${tool}"
            missing+=("${tool}")
        else
            write_to_log_file "SUCCESS" "${tool} found"
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install them and retry."
        if [[ "${INSTALL_TARGET:-kind}" == "kind" ]]; then
            log_error "  - kind:    https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
        fi
        log_error "  - kubectl: https://kubernetes.io/docs/tasks/tools/"
        return 1
    fi

    if [[ "${INSTALL_TARGET:-kind}" == "kind" ]]; then
        if [[ -z "${container_runtime}" ]]; then
            log_error "No container runtime found. Install docker or podman."
            log_error "  - docker: https://docs.docker.com/get-docker/"
            log_error "  - podman: https://podman.io/getting-started/installation"
            return 1
        fi
        # Export so other scripts can use the correct runtime
        export CONTAINER_RUNTIME="${container_runtime}"
        write_to_log_file "SUCCESS" "Container runtime: ${container_runtime}"
    fi

    log_validation_success "Validating Prerequisites"
    return 0
}

################################################################################
# validate_docker_running
# Ensures the Docker daemon is reachable.
################################################################################
validate_docker_running() {
    local runtime="${CONTAINER_RUNTIME:-docker}"
    log_file_only "Validating container runtime (${runtime})"

    if ! ${runtime} info &>/dev/null; then
        if [[ "${runtime}" == "podman" ]]; then
            log_error "Podman is not running or not reachable."
            log_error "Start the Podman machine:  podman machine start"
        else
            log_error "Docker daemon is not running or not reachable."
            log_error "Start Docker Desktop (macOS/Windows) or run: sudo systemctl start docker"
        fi
        return 1
    fi

    if [[ "${runtime}" == "podman" ]]; then
        local rootful
        rootful=$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null || echo "")
        if [[ "${rootful}" == "false" ]]; then
            log_error "Podman machine is running in rootless mode — Kind requires rootful mode."
            log_error "Recreate the Podman machine as rootful:"
            log_error "  podman machine stop"
            log_error "  podman machine rm"
            log_error "  podman machine init --rootful --cpus 4 --memory 4096"
            log_error "  podman machine start"
            return 1
        fi
    fi

    write_to_log_file "SUCCESS" "Container runtime is running (${runtime})"
    log_validation_success "Validating container runtime"
    return 0
}

################################################################################
# validate_cluster_access
# For the kind target: switches to the kind-<cluster-name> context before
# checking connectivity, so an unrelated current context doesn't cause a hang.
################################################################################
validate_cluster_access() {
    log_file_only "Validating cluster access"

    # ── OpenShift target ──────────────────────────────────────────────────────
    # Use `oc whoami` — it validates the token and the API server URL in one
    # shot, exactly as the reference installer does. No context switching needed
    # because `oc login` already wrote the correct context into kubeconfig.
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        log_file_only "Checking OpenShift cluster connectivity via oc whoami..."

        if ! ${KUBE_CLI} whoami &>/dev/null; then
            log_error "Cannot connect to OpenShift cluster."
            log_error "Please log in first:  oc login --server=<url> --token=<token>"
            return 1
        fi

        local current_user cluster_url
        current_user=$(${KUBE_CLI} whoami 2>/dev/null)
        cluster_url=$(${KUBE_CLI} whoami --show-server 2>/dev/null || echo "")

        write_to_log_file "SUCCESS" "Authenticated as: ${current_user}"
        [[ -n "${cluster_url}" ]] && write_to_log_file "INFO" "Cluster URL: ${cluster_url}"

        # Basic node-list check (confirms RBAC is sufficient)
        local node_count
        if node_count=$(${KUBE_CLI} get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '); then
            write_to_log_file "SUCCESS" "Cluster access verified (${node_count} nodes)"
        else
            log_warn "Cannot list nodes — may need elevated permissions"
        fi

        log_validation_success "Validating Cluster Access"
        return 0
    fi

    # ── Kind target ───────────────────────────────────────────────────────────
    # Switch to the kind-<cluster-name> context so an unrelated current context
    # doesn't cause a hang or connect to the wrong cluster.
    local prev_ctx
    prev_ctx=$(${KUBE_CLI} config current-context 2>/dev/null || echo "")

    local kind_ctx="kind-${KIND_CLUSTER_NAME:-causa-rca}"
    if ${KUBE_CLI} config get-contexts "${kind_ctx}" &>/dev/null; then
        ${KUBE_CLI} config use-context "${kind_ctx}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
        write_to_log_file "INFO" "Switched kubectl context to ${kind_ctx} (was: ${prev_ctx:-none})"
    else
        log_error "Kind context '${kind_ctx}' not found in kubeconfig."
        log_error "The Kind cluster may not have been created yet — this should not happen at this stage."
        return 1
    fi

    local ctx
    ctx=$(${KUBE_CLI} config current-context 2>/dev/null || echo "")
    write_to_log_file "INFO" "Current context: ${ctx}"

    local rc=0
    if ! ${KUBE_CLI} cluster-info --request-timeout=10s &>/dev/null; then
        log_error "Cannot reach the cluster API server (context: ${ctx})"
        log_error "Ensure the Kind cluster is running:  kind get clusters"
        rc=1
    fi

    if [[ -n "${prev_ctx}" && "${prev_ctx}" != "${ctx}" ]]; then
        ${KUBE_CLI} config use-context "${prev_ctx}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
        write_to_log_file "INFO" "Restored kubectl context to ${prev_ctx}"
    fi

    [[ ${rc} -ne 0 ]] && return 1
    write_to_log_file "SUCCESS" "Cluster is reachable (context: ${ctx})"
    log_validation_success "Validating Cluster Access"
    return 0
}

################################################################################
# validate_image_format_silent
# Validates image format for images loaded from images.env (silent on success).
################################################################################
validate_image_format_silent() {
    local image="$1"
    local flag_name="$2"

    [[ -z "${image}" ]]                                     && { log_error "Image empty for ${flag_name}"; return 1; }
    [[ "${image}" =~ [[:space:]] ]]                         && { log_error "Image has spaces: ${image} (${flag_name})"; return 1; }
    [[ "${image}" =~ [\$\`\!\&\|\;\<\>\(\)\{\}\[\]\\] ]]   && { log_error "Image has invalid chars: ${image}"; return 1; }
    [[ ! "${image}" =~ : ]]                                 && { log_error "Image missing tag: ${image}"; return 1; }

    local tag="${image##*:}"
    [[ -z "${tag}" ]]                                       && { log_error "Empty tag in image: ${image}"; return 1; }
    [[ ! "${tag}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]       && { log_error "Invalid tag: ${tag}"; return 1; }

    local repo="${image%:*}"
    [[ -z "${repo}" ]]                                      && { log_error "Empty repo in image: ${image}"; return 1; }
    [[ ! "${repo}" =~ ^[a-zA-Z0-9._/-]+$ ]]                 && { log_error "Invalid repo: ${repo}"; return 1; }
    [[ ${#image} -gt 255 ]]                                 && { log_error "Image name too long: ${image}"; return 1; }

    write_to_log_file "SUCCESS" "Image validated (images.env): ${image}"
    return 0
}

################################################################################
# validate_image_format
# Same as above but also prints success to the terminal (used for CLI overrides).
################################################################################
validate_image_format() {
    local image="$1"
    local flag_name="$2"

    validate_image_format_silent "${image}" "${flag_name}" || return 1

    echo -e "${COLOR_GREEN}Image format validated: ${image}${COLOR_RESET}" > /dev/tty 2>/dev/null || true
    write_to_log_file "SUCCESS" "Image format validated: ${image}"
    return 0
}

################################################################################
# validate_image_overrides
# Validates all image variables (whether from images.env or CLI override).
################################################################################
validate_image_overrides() {
    local failed=false

    _vi() {
        local img="$1" flag="$2" overridden="$3"
        [[ -z "${img}" ]] && return 0
        if [[ "${overridden}" == "true" ]]; then
            validate_image_format "${img}" "${flag}" || failed=true
        else
            validate_image_format_silent "${img}" "${flag}" || failed=true
        fi
    }

    _vi "${K8S_MCP_SERVER_IMAGE}"          "--k8s-mcp-server-image"       "${K8S_MCP_SERVER_IMAGE_OVERRIDDEN:-false}"
    _vi "${CAUSA_BACKEND_IMAGE}"           "--causa-backend-image"        "${CAUSA_BACKEND_IMAGE_OVERRIDDEN:-false}"
    _vi "${ASYNC_PROFILER_MCP_IMAGE}"      "--async-profiler-mcp-image"   "${ASYNC_PROFILER_MCP_IMAGE_OVERRIDDEN:-false}"
    _vi "${QUARKUS_MCP_IMAGE}"             "--quarkus-mcp-image"          "${QUARKUS_MCP_IMAGE_OVERRIDDEN:-false}"
    _vi "${CAUSA_MCP_IMAGE}"               "--causa-mcp-image"            "${CAUSA_MCP_IMAGE_OVERRIDDEN:-false}"
    _vi "${JAFRA_CONTROLLER_IMAGE}"        "--jafra-controller-image"     "${JAFRA_CONTROLLER_IMAGE_OVERRIDDEN:-false}"
    _vi "${JAFRA_AGENT_IMAGE}"             "--jafra-agent-image"          "${JAFRA_AGENT_IMAGE_OVERRIDDEN:-false}"
    _vi "${JAFRA_ANALYZER_IMAGE}"          "--jafra-analyzer-image"       "${JAFRA_ANALYZER_IMAGE_OVERRIDDEN:-false}"

    if [[ "${failed}" == "true" ]]; then
        log_error "Image validation failed. Correct the image format and retry."
        return 1
    fi
    return 0
}

################################################################################
# post_component_validation
# Health summary after all components are installed.
################################################################################
post_component_validation() {
    local elapsed_label="${1:-}"
    log_section_silent "Post-Installation Validation"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping post-install health validation"
        return 0
    fi

    local failed=0

    _check_deployment() {
        local display="$1" deploy="$2" var="$3"
        local rr dr
        if ${KUBE_CLI} get deployment "${deploy}" -n "${INSTALL_NAMESPACE}" &>/dev/null; then
            rr=$(${KUBE_CLI} get deployment "${deploy}" -n "${INSTALL_NAMESPACE}" \
                    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            dr=$(${KUBE_CLI} get deployment "${deploy}" -n "${INSTALL_NAMESPACE}" \
                    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            if [[ "${rr:-0}" == "${dr}" ]]; then
                printf -v "${var}" '%b' "${COLOR_BOLD_GREEN}${display} ✓${COLOR_RESET}"
                write_to_log_file "SUCCESS" "${display} is healthy"
            else
                printf -v "${var}" '%b' "${COLOR_BOLD_RED}${display} ✗${COLOR_RESET}"
                write_to_log_file "ERROR" "${display} pods not ready: ${rr:-0}/${dr}"
                (( failed++ ))
            fi
        else
            printf -v "${var}" '%b' "${COLOR_YELLOW}${display} — not installed${COLOR_RESET}"
            write_to_log_file "INFO" "${display} deployment not found (skipped)"
        fi
    }

    local k8s_mcp_status causa_status quarkus_status causa_mcp_status

    _check_deployment "Kubernetes MCP Server"    "kubernetes-mcp-server"  k8s_mcp_status
    _check_deployment "Causa Backend"            "causa-backend"          causa_status
    _check_deployment "Quarkus MCP Server"       "mcp-metrics"            quarkus_status
    _check_deployment "Causa MCP Server"         "causa-mcp"              causa_mcp_status

    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Component Health Summary${COLOR_RESET}"
        echo ""
        echo -e "${k8s_mcp_status}"
        echo -e "${causa_status}"
        echo -e "${quarkus_status}"
        echo -e "${causa_mcp_status}"
        echo ""
        [[ -n "${elapsed_label}" ]] && echo -e "${COLOR_BOLD_YELLOW}Total installation time: ${elapsed_label}${COLOR_RESET}" && echo ""
    } >/dev/tty 2>/dev/null || true

    if [[ ${failed} -eq 0 ]]; then
        write_to_log_file "SUCCESS" "All components passed health validation"
        return 0
    else
        log_error "${failed} component(s) failed health validation"
        return 1
    fi
}

export -f validate_prerequisites
export -f validate_docker_running
export -f validate_cluster_access
export -f validate_image_format_silent
export -f validate_image_format
export -f validate_image_overrides
export -f post_component_validation
