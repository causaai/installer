#!/usr/bin/env bash

################################################################################
# PostgreSQL — Installation Functions
#
# OpenShift target : CloudNativePG operator (OLM Subscription) + Cluster CRD.
#                   Credentials are read from the CNPG-generated secret.
# kind target      : Single-instance Deployment with pgvector.
#                   Credentials are set by the installer directly.
#
# In both cases the 'causa-db-secrets' Secret is created with:
#   CAUSA_DB_USERNAME, CAUSA_DB_PASSWORD, CAUSA_DB_URL
################################################################################

# Source guard
if [[ -n "${INSTALL_POSTGRES_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_POSTGRES_LIB_LOADED=1

# ── Shared constants ──────────────────────────────────────────────────────────
readonly _PG_SECRET_NAME="causa-db-secrets"
readonly _PG_DB_NAME="iri-db"

# ── kind-target constants ─────────────────────────────────────────────────────
readonly _PG_MANIFEST="${SCRIPT_DIR}/manifests/postgres/deployment.yaml"
readonly _PG_USER="causa_backend"
readonly _PG_PASS="causa_backend_pass"
# Image defaults — resolved at call time inside install_postgres so that
# CLI overrides (--postgres-kind-image / --postgres-ocp-image) take effect.
readonly _PG_KIND_IMAGE_DEFAULT="docker.io/pgvector/pgvector:pg17"

# ── OpenShift / CNPG constants ─────────────────────────────────────────────────
# Image default — resolved at call time (see _cnpg_create_db_cluster).
readonly _PG_OCP_IMAGE_DEFAULT="quay.io/causa-ai-hub/postgres-pgvector:17"

readonly _CNPG_OPERATOR_NAME="cloudnative-pg"
readonly _CNPG_OPERATOR_GROUP_YAML="${SCRIPT_DIR}/manifests/postgres/operator/operator_group.yaml"
readonly _CNPG_SUBSCRIPTION_YAML="${SCRIPT_DIR}/manifests/postgres/operator/cnpg_subscription.yaml"
readonly _CNPG_DB_CLUSTER_YAML="${SCRIPT_DIR}/manifests/postgres/database-cluster/iri_db_cluster.yaml"
readonly _CNPG_DB_CLUSTER_NAME="iri-db"

################################################################################
# _cnpg_find_operator_namespace
# Returns the namespace that already has a cloudnative-pg Subscription, or "".
################################################################################
_cnpg_find_operator_namespace() {
    ${KUBE_CLI} get subscription -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
        2>/dev/null \
        | awk -v op="${_CNPG_OPERATOR_NAME}" '$2 == op {print $1; exit}'
}

################################################################################
# _cnpg_operator_ready  <namespace>
################################################################################
_cnpg_operator_ready() {
    local ns="$1"
    ${KUBE_CLI} get csv -n "${ns}" 2>/dev/null \
        | grep "${_CNPG_OPERATOR_NAME}" | grep -q "Succeeded" || return 1
    ${KUBE_CLI} rollout status deployment/cnpg-controller-manager \
        -n "${ns}" --timeout=120s &>/dev/null || return 1
}

################################################################################
# _cnpg_operator_group_exists  <namespace>
################################################################################
_cnpg_operator_group_exists() {
    local ns="$1"
    local count
    count=$(${KUBE_CLI} get operatorgroup -n "${ns}" --no-headers 2>/dev/null | wc -l)
    [[ "${count}" -gt 0 ]]
}

################################################################################
# _cnpg_install_operator  <namespace>
################################################################################
_cnpg_install_operator() {
    local ns="$1"

    write_to_log_file "INFO" "Installing CNPG operator in namespace: ${ns}"

    # OperatorGroup — apply only when none exists yet
    if _cnpg_operator_group_exists "${ns}"; then
        write_to_log_file "INFO" "OperatorGroup already exists in ${ns} — skipping"
    else
        write_to_log_file "INFO" "Creating OperatorGroup..."
        local tmp_og; tmp_og=$(mktemp /tmp/causa-cnpg-og-XXXXXX.yaml)
        sed "s/PLACEHOLDER_NAMESPACE/${ns}/g" "${_CNPG_OPERATOR_GROUP_YAML}" > "${tmp_og}"
        if ! ${KUBE_CLI} apply -f "${tmp_og}" -n "${ns}" >>"${LOG_FILE}" 2>&1; then
            rm -f "${tmp_og}"
            log_error "Failed to create CNPG OperatorGroup"
            return 1
        fi
        rm -f "${tmp_og}"
        write_to_log_file "SUCCESS" "OperatorGroup created"
    fi

    # Subscription — namespace injected via -n flag (manifest has no namespace field)
    write_to_log_file "INFO" "Creating CNPG Subscription..."
    if ! ${KUBE_CLI} apply -f "${_CNPG_SUBSCRIPTION_YAML}" -n "${ns}" >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to apply CNPG Subscription"
        return 1
    fi
    write_to_log_file "SUCCESS" "CNPG Subscription created"

    # Wait for InstallPlan and approve it
    write_to_log_file "INFO" "Waiting for InstallPlan..."
    local installplan="" attempt
    for attempt in $(seq 1 60); do
        installplan=$(${KUBE_CLI} get subscription "${_CNPG_OPERATOR_NAME}" -n "${ns}" \
            -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
        [[ -n "${installplan}" && "${installplan}" != "null" ]] && break
        [[ ${attempt} -eq 60 ]] && { log_error "Timeout waiting for InstallPlan"; return 1; }
        sleep 5
    done
    write_to_log_file "INFO" "InstallPlan: ${installplan}"

    local approved
    approved=$(${KUBE_CLI} get installplan "${installplan}" -n "${ns}" \
        -o jsonpath='{.spec.approved}' 2>/dev/null || echo "false")
    if [[ "${approved}" != "true" ]]; then
        write_to_log_file "INFO" "Approving InstallPlan ${installplan}..."
        if ! ${KUBE_CLI} patch installplan "${installplan}" -n "${ns}" \
                --type merge -p '{"spec":{"approved":true}}' >>"${LOG_FILE}" 2>&1; then
            log_error "Failed to approve InstallPlan"
            return 1
        fi
        write_to_log_file "SUCCESS" "InstallPlan approved"
    else
        write_to_log_file "INFO" "InstallPlan already approved"
    fi

    # Wait for operator pod
    write_to_log_file "INFO" "Waiting for CNPG controller manager to be ready..."
    for attempt in $(seq 1 60); do
        if _cnpg_operator_ready "${ns}"; then
            write_to_log_file "SUCCESS" "CNPG operator is ready"
            return 0
        fi
        [[ ${attempt} -eq 60 ]] && { log_error "Timeout waiting for CNPG operator"; return 1; }
        sleep 5
    done
}

################################################################################
# _cnpg_db_cluster_ready  <namespace>
################################################################################
_cnpg_db_cluster_ready() {
    local ns="$1"
    local phase
    phase=$(${KUBE_CLI} get cluster.postgresql.cnpg.io "${_CNPG_DB_CLUSTER_NAME}" \
        -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "${phase}" == "Cluster in healthy state" ]]
}

################################################################################
# _cnpg_create_db_cluster  <namespace>
################################################################################
_cnpg_create_db_cluster() {
    local ns="$1"
    local pg_image="${POSTGRES_OCP_IMAGE:-${_PG_OCP_IMAGE_DEFAULT}}"

    if ${KUBE_CLI} get cluster.postgresql.cnpg.io "${_CNPG_DB_CLUSTER_NAME}" \
            -n "${ns}" &>/dev/null; then
        if _cnpg_db_cluster_ready "${ns}"; then
            write_to_log_file "INFO" "CNPG cluster already healthy — skipping"
            return 0
        fi
        # Cluster exists but is not yet healthy — could be starting, recovering,
        # or failing over. Wait up to 10 minutes before giving up to avoid
        # destroying data due to a transient state.
        write_to_log_file "INFO" "CNPG cluster exists but is not healthy — waiting up to 10 minutes..."
        local wait
        for wait in $(seq 1 120); do
            if _cnpg_db_cluster_ready "${ns}"; then
                write_to_log_file "SUCCESS" "CNPG cluster recovered and is healthy"
                return 0
            fi
            if [[ $((wait % 12)) -eq 0 ]]; then
                local phase
                phase=$(${KUBE_CLI} get cluster.postgresql.cnpg.io "${_CNPG_DB_CLUSTER_NAME}" \
                    -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                write_to_log_file "INFO" "CNPG cluster phase: ${phase} (${wait}/120)"
            fi
            [[ ${wait} -eq 120 ]] && { log_error "Timeout waiting for existing CNPG cluster to become healthy"; return 1; }
            sleep 5
        done
    fi

    write_to_log_file "INFO" "Applying CNPG Cluster manifest (image: ${pg_image})..."
    local tmp_cluster; tmp_cluster=$(mktemp /tmp/causa-cnpg-cluster-XXXXXX.yaml)
    sed "s|PLACEHOLDER_OCP_POSTGRES_IMAGE|${pg_image}|g" \
        "${_CNPG_DB_CLUSTER_YAML}" > "${tmp_cluster}"
    # Namespace injected via -n flag; manifest has no namespace field
    if ! ${KUBE_CLI} apply -f "${tmp_cluster}" -n "${ns}" >>"${LOG_FILE}" 2>&1; then
        rm -f "${tmp_cluster}"
        log_error "Failed to apply CNPG Cluster manifest"
        return 1
    fi
    rm -f "${tmp_cluster}"
    write_to_log_file "SUCCESS" "CNPG Cluster manifest applied"

    write_to_log_file "INFO" "Waiting for CNPG cluster to reach healthy state..."
    local attempt
    for attempt in $(seq 1 120); do
        if _cnpg_db_cluster_ready "${ns}"; then
            write_to_log_file "SUCCESS" "CNPG cluster is healthy"
            return 0
        fi
        if [[ $((attempt % 10)) -eq 0 ]]; then
            local phase
            phase=$(${KUBE_CLI} get cluster.postgresql.cnpg.io "${_CNPG_DB_CLUSTER_NAME}" \
                -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            write_to_log_file "INFO" "CNPG cluster phase: ${phase}"
        fi
        [[ ${attempt} -eq 120 ]] && { log_error "Timeout waiting for CNPG cluster"; return 1; }
        sleep 5
    done
}

################################################################################
# _cnpg_create_causa_db_secrets  <namespace>
################################################################################
_cnpg_create_causa_db_secrets() {
    local ns="$1"
    local cnpg_secret="${_CNPG_DB_CLUSTER_NAME}-app"

    ${KUBE_CLI} delete secret "${_PG_SECRET_NAME}" \
        -n "${ns}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    write_to_log_file "INFO" "Waiting for CNPG app secret: ${cnpg_secret}..."
    local attempt
    for attempt in $(seq 1 60); do
        ${KUBE_CLI} get secret "${cnpg_secret}" -n "${ns}" &>/dev/null && break
        [[ ${attempt} -eq 60 ]] && { log_error "Timeout waiting for CNPG secret ${cnpg_secret}"; return 1; }
        sleep 2
    done

    # base64 decode: GNU coreutils uses -d / --decode; macOS BSD uses -D.
    # Capture raw b64 first, then decode portably in a single pass.
    local _b64_decode="base64 --decode"
    base64 --decode </dev/null &>/dev/null || _b64_decode="base64 -D"

    local db_user db_pass
    db_user=$(${KUBE_CLI} get secret "${cnpg_secret}" -n "${ns}" \
        -o jsonpath='{.data.username}' 2>/dev/null | ${_b64_decode})
    db_pass=$(${KUBE_CLI} get secret "${cnpg_secret}" -n "${ns}" \
        -o jsonpath='{.data.password}' 2>/dev/null | ${_b64_decode})

    if [[ -z "${db_user}" || -z "${db_pass}" ]]; then
        log_error "Failed to extract credentials from CNPG secret ${cnpg_secret}"
        return 1
    fi

    if ! ${KUBE_CLI} create secret generic "${_PG_SECRET_NAME}" \
        -n "${ns}" \
        --from-literal=CAUSA_DB_USERNAME="${db_user}" \
        --from-literal=CAUSA_DB_PASSWORD="${db_pass}" \
        --from-literal=CAUSA_DB_URL="jdbc:postgresql://iri-db-rw.${ns}.svc.cluster.local:5432/${_PG_DB_NAME}" \
        >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to create ${_PG_SECRET_NAME} secret"
        return 1
    fi

    write_to_log_file "SUCCESS" "${_PG_SECRET_NAME} created (user: ${db_user})"
    return 0
}

################################################################################
# install_postgres
################################################################################
install_postgres() {
    log_section_silent "Installing PostgreSQL"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    # ── OpenShift: CloudNativePG operator path ────────────────────────────────
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        local ns="${INSTALL_NAMESPACE}"

        # Check if operator is already present in any namespace
        local op_ns
        op_ns=$(_cnpg_find_operator_namespace)

        if [[ -n "${op_ns}" ]]; then
            write_to_log_file "INFO" "CNPG operator found in namespace: ${op_ns} — skipping install"
            if ! _cnpg_operator_ready "${op_ns}"; then
                write_to_log_file "INFO" "Operator not yet ready — waiting..."
                local attempt
                for attempt in $(seq 1 24); do
                    _cnpg_operator_ready "${op_ns}" && break
                    [[ ${attempt} -eq 24 ]] && { log_error "Timeout waiting for CNPG operator"; return 1; }
                    sleep 5
                done
            fi
            write_to_log_file "SUCCESS" "CNPG operator is ready in ${op_ns}"
        else
            write_to_log_file "INFO" "CNPG operator not found — installing..."
            if ! _cnpg_install_operator "${ns}"; then
                log_error "Failed to install CNPG operator"
                return 1
            fi
        fi

        if ! _cnpg_create_db_cluster "${ns}"; then
            log_error "Failed to create CNPG database cluster"
            return 1
        fi

        if ! _cnpg_create_causa_db_secrets "${ns}"; then
            log_error "Failed to create ${_PG_SECRET_NAME}"
            return 1
        fi

        write_to_log_file "SUCCESS" "PostgreSQL (CNPG) installed"
        write_to_log_file "INFO"    "URL: jdbc:postgresql://iri-db-rw.${ns}.svc.cluster.local:5432/${_PG_DB_NAME}"
        return 0
    fi

    # ── kind: standalone Deployment path ─────────────────────────────────────
    local pg_image="${POSTGRES_KIND_IMAGE:-${_PG_KIND_IMAGE_DEFAULT}}"
    write_to_log_file "INFO" "Using image: ${pg_image}"

    write_to_log_file "INFO" "Creating postgres-credentials secret..."
    ${KUBE_CLI} delete secret postgres-credentials \
        -n "${INSTALL_NAMESPACE}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    if ! ${KUBE_CLI} create secret generic postgres-credentials \
        -n "${INSTALL_NAMESPACE}" \
        --from-literal=POSTGRES_DB="${_PG_DB_NAME}" \
        --from-literal=POSTGRES_USER="${_PG_USER}" \
        --from-literal=POSTGRES_PASSWORD="${_PG_PASS}" \
        >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to create postgres-credentials secret"
        return 1
    fi

    write_to_log_file "INFO" "Applying Postgres manifest..."
    if ! apply_manifest "${_PG_MANIFEST}" "${INSTALL_NAMESPACE}" \
        "image: .*postgres.*" "${pg_image}"; then
        log_error "Failed to apply Postgres manifest"
        return 1
    fi

    if ! wait_for_deployment "postgres" "${INSTALL_NAMESPACE}" 180; then
        log_error "Postgres did not become ready in time"
        return 1
    fi

    write_to_log_file "INFO" "Creating ${_PG_SECRET_NAME} secret..."
    ${KUBE_CLI} delete secret "${_PG_SECRET_NAME}" \
        -n "${INSTALL_NAMESPACE}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    if ! ${KUBE_CLI} create secret generic "${_PG_SECRET_NAME}" \
        -n "${INSTALL_NAMESPACE}" \
        --from-literal=CAUSA_DB_USERNAME="${_PG_USER}" \
        --from-literal=CAUSA_DB_PASSWORD="${_PG_PASS}" \
        --from-literal=CAUSA_DB_URL="jdbc:postgresql://postgres.${INSTALL_NAMESPACE}.svc.cluster.local:5432/${_PG_DB_NAME}" \
        >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to create ${_PG_SECRET_NAME} secret"
        return 1
    fi

    write_to_log_file "SUCCESS" "PostgreSQL installed"
    write_to_log_file "INFO"    "URL:  jdbc:postgresql://postgres.${INSTALL_NAMESPACE}.svc.cluster.local:5432/${_PG_DB_NAME}"
    write_to_log_file "INFO"    "User: ${_PG_USER}"
    return 0
}

################################################################################
# uninstall_postgres
################################################################################
uninstall_postgres() {
    log_section_silent "Uninstalling PostgreSQL"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        local ns="${INSTALL_NAMESPACE}"
        local op_ns
        op_ns=$(_cnpg_find_operator_namespace)
        [[ -z "${op_ns}" ]] && op_ns="${ns}"

        write_to_log_file "INFO" "Deleting CNPG cluster..."
        ${KUBE_CLI} delete cluster.postgresql.cnpg.io "${_CNPG_DB_CLUSTER_NAME}" \
            -n "${ns}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

        write_to_log_file "INFO" "Deleting CNPG Subscription..."
        ${KUBE_CLI} delete subscription "${_CNPG_OPERATOR_NAME}" \
            -n "${op_ns}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

        write_to_log_file "INFO" "Deleting CNPG CSV..."
        ${KUBE_CLI} get csv -n "${op_ns}" -o name 2>/dev/null \
            | grep cloudnative \
            | xargs -r ${KUBE_CLI} delete -n "${op_ns}" >>"${LOG_FILE}" 2>&1 || true

        write_to_log_file "INFO" "Deleting CNPG OperatorGroup..."
        ${KUBE_CLI} delete operatorgroup cnpg-operator-group \
            -n "${op_ns}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    else
        delete_manifest "${_PG_MANIFEST}" "${INSTALL_NAMESPACE}"
        ${KUBE_CLI} delete secret postgres-credentials \
            -n "${INSTALL_NAMESPACE}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    fi

    ${KUBE_CLI} delete secret "${_PG_SECRET_NAME}" \
        -n "${INSTALL_NAMESPACE}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    write_to_log_file "SUCCESS" "PostgreSQL uninstalled"
    return 0
}

export -f install_postgres
export -f uninstall_postgres
