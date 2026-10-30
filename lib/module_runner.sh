#!/usr/bin/env bash

################################################################################
# Module Registry — Causa RCA Installer
#
# Configuration-driven runner for the deployable components declared in
# modules.json (schema_version "1").  Provides:
#
#   registry_load           parse + validate modules.json, source every module's
#                           source_lib, compute dependency waves
#   registry_install_all    install every module that matches INSTALL_TARGET,
#                           wave by wave (modules.json order inside a wave)
#   registry_uninstall_all  uninstall matching modules in reverse install order
#
# Semantics
#   targets     "*" matches any INSTALL_TARGET; otherwise the value must equal it.
#               A module that does not match is silently skipped.
#   depends_on  a module is placed in a later wave than everything it depends on.
#               If a dependency was not installed (failed, skipped, or not
#               applicable to the target) the dependent is skipped with a warning,
#               or aborts the install when the dependent is required.
#   required    true  -> install failure aborts the installer (exit 1)
#               false -> install failure logs a warning and installation continues
#   uninstall   a failing uninstall_fn aborts the installer (exit 1).
#
# Not described by the registry (intentionally):
#   - manifest paths  (owned by each module's source_lib)
#   - image variables (owned by lib/images.env and lib/validator.sh)
#   - Kind cluster, cert-manager and OpenShift monitoring (owned by install.sh)
#
# Requires: jq, bash 3.2+ (no associative arrays), logging.sh helpers.
################################################################################

# Prevent multiple sourcing
if [[ -n "${MODULE_REGISTRY_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly MODULE_REGISTRY_LIB_LOADED=1

readonly _REGISTRY_SUPPORTED_SCHEMA="1"

# Parallel arrays — one slot per module, in modules.json order.
_MOD_ID=()
_MOD_NAME=()
_MOD_LIB=()
_MOD_INSTALL_FN=()
_MOD_UNINSTALL_FN=()
_MOD_TARGETS=()     # space-separated
_MOD_REQUIRED=()    # "true" | "false"
_MOD_DEPS=()        # space-separated module ids
_MOD_WAVE=()        # 1-based dependency wave
_MOD_ORDER=()       # module indices sorted by (wave, modules.json position)

# Names of modules installed by the last registry_install_all call
REGISTRY_INSTALLED=()

################################################################################
# _registry_schema_errors FILE
# Prints one line per structural problem found in FILE (nothing when valid).
################################################################################
_registry_schema_errors() {
    jq -r '
        def isstr:  type == "string" and length > 0;
        def isid:   type == "string" and test("^[a-z0-9_]+$");
        def isfn:   type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$");

        if type != "object" then
            "top-level value must be an object"
        elif (.modules | type) != "array" then
            "\"modules\" must be an array"
        elif (.modules | length) == 0 then
            "\"modules\" must not be empty"
        else
            .modules | to_entries[] | .key as $i | .value as $m |
            if ($m | type) != "object" then
                "modules[\($i)] must be an object"
            else
                ( select(($m.id | isid) | not)
                  | "modules[\($i)]: \"id\" must match ^[a-z0-9_]+$" ),
                ( select(($m.name | isstr) | not)
                  | "modules[\($i)]: \"name\" must be a non-empty string" ),
                ( select(($m.source_lib | isstr) | not)
                  | "modules[\($i)]: \"source_lib\" must be a non-empty string" ),
                ( select(($m.source_lib | isstr)
                         and (($m.source_lib | startswith("/")) or ($m.source_lib | contains(".."))))
                  | "modules[\($i)]: \"source_lib\" must be a relative path without \"..\"" ),
                ( select(($m.install_fn | isfn) | not)
                  | "modules[\($i)]: \"install_fn\" must be a shell function name" ),
                ( select(($m.uninstall_fn | isfn) | not)
                  | "modules[\($i)]: \"uninstall_fn\" must be a shell function name" ),
                ( select(($m.required | type) != "boolean")
                  | "modules[\($i)]: \"required\" must be true or false" ),
                ( select((($m.targets | type) != "array") or (($m.targets | length) == 0)
                         or (($m.targets | all(. == "*" or . == "kind" or . == "openshift")) | not))
                  | "modules[\($i)]: \"targets\" must be a non-empty array of: *, kind, openshift" ),
                ( select((($m.depends_on | type) != "array") or (($m.depends_on | all(isid)) | not))
                  | "modules[\($i)]: \"depends_on\" must be an array of module ids" )
            end
        end
    ' "$1"
}

################################################################################
# _registry_index_of ID — prints the array index of module ID; returns 1 if none
################################################################################
_registry_index_of() {
    local want="$1" i
    for i in "${!_MOD_ID[@]}"; do
        if [[ "${_MOD_ID[$i]}" == "${want}" ]]; then
            echo "${i}"
            return 0
        fi
    done
    return 1
}

################################################################################
# _registry_matches_target INDEX — returns 0 if the module applies to
# INSTALL_TARGET
################################################################################
_registry_matches_target() {
    local t targets
    # read -ra splits without pathname expansion, so a literal "*" survives
    read -ra targets <<< "${_MOD_TARGETS[$1]}"
    for t in "${targets[@]}"; do
        if [[ "${t}" == "*" || "${t}" == "${INSTALL_TARGET:-kind}" ]]; then
            return 0
        fi
    done
    return 1
}

################################################################################
# _registry_compute_waves
# Assigns _MOD_WAVE and _MOD_ORDER.  Returns 1 on unknown dependencies or cycles.
################################################################################
_registry_compute_waves() {
    local n=${#_MOD_ID[@]} i dep d

    # Unknown dependencies
    local bad=false
    for (( i = 0; i < n; i++ )); do
        _MOD_WAVE[i]=0
        for dep in ${_MOD_DEPS[i]}; do
            if ! _registry_index_of "${dep}" >/dev/null; then
                log_error "modules.json: module '${_MOD_ID[i]}' depends on unknown module '${dep}'"
                bad=true
            fi
        done
    done
    [[ "${bad}" == "true" ]] && return 1

    # Level assignment: wave = 1 + max(wave of dependencies)
    local progress=true max_dep ready
    while [[ "${progress}" == "true" ]]; do
        progress=false
        for (( i = 0; i < n; i++ )); do
            [[ ${_MOD_WAVE[i]} -ne 0 ]] && continue
            ready=true
            max_dep=0
            for dep in ${_MOD_DEPS[i]}; do
                d=$(_registry_index_of "${dep}")
                if [[ ${_MOD_WAVE[d]} -eq 0 ]]; then
                    ready=false
                    break
                fi
                [[ ${_MOD_WAVE[d]} -gt ${max_dep} ]] && max_dep=${_MOD_WAVE[d]}
            done
            if [[ "${ready}" == "true" ]]; then
                _MOD_WAVE[i]=$(( max_dep + 1 ))
                progress=true
            fi
        done
    done

    # Anything still unassigned is part of (or behind) a cycle
    local cyclic=()
    for (( i = 0; i < n; i++ )); do
        [[ ${_MOD_WAVE[i]} -eq 0 ]] && cyclic+=("${_MOD_ID[i]}")
    done
    if [[ ${#cyclic[@]} -gt 0 ]]; then
        log_error "modules.json: dependency cycle involving: ${cyclic[*]}"
        return 1
    fi

    # Execution order: by wave, then by position in modules.json
    local w max_wave=0
    for (( i = 0; i < n; i++ )); do
        [[ ${_MOD_WAVE[i]} -gt ${max_wave} ]] && max_wave=${_MOD_WAVE[i]}
    done
    _MOD_ORDER=()
    for (( w = 1; w <= max_wave; w++ )); do
        for (( i = 0; i < n; i++ )); do
            [[ ${_MOD_WAVE[i]} -eq ${w} ]] && _MOD_ORDER+=("${i}")
        done
    done
    return 0
}

################################################################################
# registry_load [FILE]
# Parses and validates the registry, sources every module's source_lib and
# verifies the declared functions exist.  Returns 1 (after logging the reason)
# on any problem so the caller can abort before touching the cluster.
################################################################################
registry_load() {
    local file="${1:-${MODULES_FILE:-${SCRIPT_DIR}/modules.json}}"

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required to read ${file} (https://jqlang.github.io/jq/download/)"
        return 1
    fi
    if [[ ! -f "${file}" ]]; then
        log_error "Module registry not found: ${file}"
        return 1
    fi
    if ! jq -e . "${file}" >/dev/null 2>&1; then
        log_error "Module registry is not valid JSON: ${file}"
        return 1
    fi

    local schema
    schema=$(jq -r '.schema_version // empty' "${file}")
    if [[ "${schema}" != "${_REGISTRY_SUPPORTED_SCHEMA}" ]]; then
        log_error "Unsupported modules.json schema_version '${schema:-<missing>}' (expected '${_REGISTRY_SUPPORTED_SCHEMA}')"
        return 1
    fi

    local errors
    errors=$(_registry_schema_errors "${file}")
    if [[ -n "${errors}" ]]; then
        local line
        while IFS= read -r line; do
            log_error "modules.json: ${line}"
        done <<< "${errors}"
        return 1
    fi

    local dups
    dups=$(jq -r '[.modules[].id] | group_by(.)[] | select(length > 1) | .[0]' "${file}")
    if [[ -n "${dups}" ]]; then
        log_error "modules.json: duplicate module id(s): $(echo "${dups}" | tr '\n' ' ')"
        return 1
    fi

    # Load into parallel arrays
    _MOD_ID=(); _MOD_NAME=(); _MOD_LIB=(); _MOD_INSTALL_FN=(); _MOD_UNINSTALL_FN=()
    _MOD_TARGETS=(); _MOD_REQUIRED=(); _MOD_DEPS=(); _MOD_WAVE=(); _MOD_ORDER=()

    local id name lib ifn ufn targets required deps
    while IFS=$'\t' read -r id name lib ifn ufn targets required deps; do
        _MOD_ID+=("${id}")
        _MOD_NAME+=("${name}")
        _MOD_LIB+=("${lib}")
        _MOD_INSTALL_FN+=("${ifn}")
        _MOD_UNINSTALL_FN+=("${ufn}")
        _MOD_TARGETS+=("${targets}")
        _MOD_REQUIRED+=("${required}")
        _MOD_DEPS+=("${deps:-}")
    done < <(jq -r '.modules[] | [.id, .name, .source_lib, .install_fn, .uninstall_fn,
                                  (.targets | join(" ")), (.required | tostring),
                                  (.depends_on | join(" "))] | @tsv' "${file}")

    if ! _registry_compute_waves; then
        return 1
    fi

    # Source libraries and verify functions
    local i fn path failed=false
    for i in "${!_MOD_ID[@]}"; do
        path="${SCRIPT_DIR}/${_MOD_LIB[i]}"
        if [[ ! -f "${path}" ]]; then
            log_error "modules.json: source_lib for '${_MOD_ID[i]}' not found: ${_MOD_LIB[i]}"
            failed=true
            continue
        fi
        # shellcheck source=/dev/null
        source "${path}"
        for fn in "${_MOD_INSTALL_FN[i]}" "${_MOD_UNINSTALL_FN[i]}"; do
            if ! declare -F "${fn}" >/dev/null 2>&1; then
                log_error "modules.json: function '${fn}' (module '${_MOD_ID[i]}') is not defined by ${_MOD_LIB[i]}"
                failed=true
            fi
        done
    done
    [[ "${failed}" == "true" ]] && return 1

    write_to_log_file "INFO" "Module registry loaded: ${#_MOD_ID[@]} modules from ${file}"
    return 0
}

################################################################################
# registry_install_all
# Installs matching modules wave by wave.  Populates REGISTRY_INSTALLED with the
# display names of modules that installed successfully.
################################################################################
registry_install_all() {
    REGISTRY_INSTALLED=()
    local status=()     # per module: ok | failed | skipped | filtered
    local i dep d unmet name

    for i in "${_MOD_ORDER[@]}"; do
        name="${_MOD_NAME[i]}"

        if ! _registry_matches_target "${i}"; then
            status[i]="filtered"
            write_to_log_file "INFO" "${name}: not applicable to target '${INSTALL_TARGET:-kind}' — skipped"
            continue
        fi

        unmet=""
        for dep in ${_MOD_DEPS[i]}; do
            d=$(_registry_index_of "${dep}")
            [[ "${status[d]:-}" == "ok" ]] || unmet+="${unmet:+ }${dep}"
        done
        if [[ -n "${unmet}" ]]; then
            status[i]="skipped"
            if [[ "${_MOD_REQUIRED[i]}" == "true" ]]; then
                log_error "Cannot install ${name}: dependency not installed (${unmet})"
                exit 1
            fi
            log_warn "${name} skipped: dependency not installed (${unmet})"
            continue
        fi

        start_spinner "Installing ${name}..."
        if ! "${_MOD_INSTALL_FN[i]}"; then
            stop_spinner
            status[i]="failed"
            if [[ "${_MOD_REQUIRED[i]}" == "true" ]]; then
                log_error "Failed to install ${name}"
                exit 1
            fi
            log_warn "${name} installation skipped or failed"
        else
            stop_spinner
            status[i]="ok"
            log_install_success "${name}"
            REGISTRY_INSTALLED+=("${name}")
        fi
    done
    return 0
}

################################################################################
# registry_uninstall_all
# Uninstalls matching modules in reverse install order.  A failing uninstall
# aborts the installer.
################################################################################
registry_uninstall_all() {
    local k i name
    for (( k = ${#_MOD_ORDER[@]} - 1; k >= 0; k-- )); do
        i="${_MOD_ORDER[k]}"
        _registry_matches_target "${i}" || continue
        name="${_MOD_NAME[i]}"

        start_spinner "Uninstalling ${name}..."
        if ! "${_MOD_UNINSTALL_FN[i]}"; then
            stop_spinner
            log_error "Failed to uninstall ${name}"
            exit 1
        fi
        stop_spinner
        log_uninstall_success "${name}"
    done
    return 0
}
