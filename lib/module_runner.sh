#!/usr/bin/env bash

################################################################################
# Module Registry — Causa RCA Installer
#
# Configuration-driven runner for the deployable components declared in
# modules.json (schema_version "1").  Provides:
#
#   registry_load           parse + validate modules.json, compute dependency
#                           waves, source the source_lib of every module that
#                           matches INSTALL_TARGET
#   registry_install_all    install every module that matches INSTALL_TARGET,
#                           wave by wave (modules.json order inside a wave)
#   registry_check_health   health-check the modules registry_install_all
#                           installed, via each module's <id>_health function
#   registry_uninstall_all  uninstall matching modules in reverse install order
#
# Semantics
#   targets     "*" matches any INSTALL_TARGET; otherwise the value must equal it.
#               A module that does not match is not sourced or installed.  It is
#               listed once in the log file (not on the terminal) in a "Modules
#               not applicable to target" section.
#   depends_on  a module runs in a later wave than its dependencies.  If one was
#               not installed (failed or skipped) the dependent is skipped with a
#               warning, or aborts the install if it is required.  Dependencies
#               not applicable to INSTALL_TARGET are ignored.
#   parallel    modules in a wave install concurrently, one subshell each; their
#               log output is buffered and appended to LOG_FILE after the wave,
#               in modules.json order.  Fail-fast: when a required module fails,
#               the rest of the wave is stopped and the installer exits 1.
#               install_fn runs in a subshell: share state via the cluster.
#   required    true  -> install failure aborts the installer (exit 1)
#               false -> install failure logs a warning and installation continues
#   skipped     an install_fn returning 2 deployed nothing on purpose (e.g. images
#               unset).  It is not recorded as installed, so its dependents skip.
#   functions   install_fn/uninstall_fn must be defined by the module's own
#               source_lib; functions defined in any other file are rejected.
#   uninstall   a failing uninstall_fn aborts the installer (exit 1).
#   health      optional, by naming convention (nothing is declared in
#               modules.json): a function <id>_health defined by the module's own
#               source_lib.  Exit 0 = healthy; stdout is shown as the failure
#               detail.  A module without one is not health-checked; a module
#               not applicable to the target is omitted from the report.
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

# install_fn exit status meaning "nothing was deployed, but not an error".
readonly REGISTRY_RC_SKIPPED=2

# Parallel arrays — one slot per module, in modules.json order.
_MOD_ID=()
_MOD_NAME=()
_MOD_LIB=()
_MOD_INSTALL_FN=()
_MOD_UNINSTALL_FN=()
_MOD_TARGETS=()     # space-separated
_MOD_REQUIRED=()    # "true" | "false"
_MOD_STATUS=()      # set by registry_install_all: ok | failed | skipped | filtered
_MOD_DEPS=()        # space-separated module ids
_MOD_WAVE=()        # 1-based dependency wave
_MOD_ORDER=()       # module indices sorted by (wave, modules.json position)

# Names of modules installed by the last registry_install_all call
REGISTRY_INSTALLED=()

# One colored line per checked module from the last registry_check_health call
REGISTRY_HEALTH_LINES=()

# State of the parallel wave in flight, used by the INT/TERM handler
_REGISTRY_WAVE_PIDS=()
_REGISTRY_WAVE_DIR=""
_REGISTRY_PENDING_SIG=""

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
    # The registry location is never taken from the environment: an ambient
    # variable must not be able to choose which functions the installer runs.
    local file="${1:-${SCRIPT_DIR}/modules.json}"

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

    # Source libraries and verify functions.  Only modules that apply to
    # INSTALL_TARGET are sourced, so libraries of other targets are never
    # loaded.  A module may only reference functions that its own source_lib
    # defines: a registry entry cannot point install_fn/uninstall_fn at core
    # functions (e.g. uninstall_kind_cluster) defined elsewhere in the shell.
    local i fn path failed=false fn_file
    for i in "${!_MOD_ID[@]}"; do
        _registry_matches_target "${i}" || continue
        path="${SCRIPT_DIR}/${_MOD_LIB[i]}"
        if [[ ! -f "${path}" ]]; then
            log_error "modules.json: source_lib for '${_MOD_ID[i]}' not found: ${_MOD_LIB[i]}"
            failed=true
            continue
        fi
        # shellcheck source=/dev/null
        source "${path}"
        for fn in "${_MOD_INSTALL_FN[i]}" "${_MOD_UNINSTALL_FN[i]}"; do
            # With extdebug, `declare -F` prints "name line file" for the file
            # that defined the function (subshell keeps the option scoped).
            fn_file=""
            read -r _ _ fn_file < <( shopt -s extdebug; declare -F "${fn}" 2>/dev/null ) || true
            if [[ "${fn_file}" != "${path}" ]]; then
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
# _registry_finish_module INDEX RC
# Records the outcome of one install_fn (exit status RC): sets _MOD_STATUS,
# reports it, and appends to REGISTRY_INSTALLED on success.  Any spinner must
# already be stopped.  Returns 1 when a required module failed, so the caller
# can abort the installer.
################################################################################
_registry_finish_module() {
    local i="$1" rc="$2" name="${_MOD_NAME[$1]}"

    if [[ ${rc} -eq ${REGISTRY_RC_SKIPPED} ]]; then
        # Function ran but deliberately deployed nothing (e.g. images unset):
        # not a failure, not "installed" — dependents will be skipped.
        _MOD_STATUS[i]="skipped"
        write_to_log_file "INFO" "${name}: nothing deployed — skipped"
    elif [[ ${rc} -ne 0 ]]; then
        _MOD_STATUS[i]="failed"
        if [[ "${_MOD_REQUIRED[i]}" == "true" ]]; then
            log_error "Failed to install ${name}"
            return 1
        fi
        log_warn "${name} installation skipped or failed"
    else
        _MOD_STATUS[i]="ok"
        log_install_success "${name}"
        REGISTRY_INSTALLED+=("${name}")
    fi
    return 0
}

################################################################################
# _registry_terminate_job PID
# Stops one wave job and everything it spawned.  Each job is started with job
# control enabled, so PID is also its process-group id: signalling the group
# reaches nested processes that would otherwise outlive the install subshell.
# Reaps the job, waits for the group to empty, and escalates to SIGKILL if it
# does not exit within ~10s.
################################################################################
_registry_terminate_job() {
    local pid="$1" n
    kill -TERM -- "-${pid}" 2>/dev/null || {
        # No such group (job control unavailable): fall back to the process tree
        pkill -TERM -P "${pid}" 2>/dev/null || true
        kill -TERM "${pid}" 2>/dev/null || true
    }
    wait "${pid}" 2>/dev/null || true
    for (( n = 0; n < 100; n++ )); do
        kill -0 -- "-${pid}" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL -- "-${pid}" 2>/dev/null || true
    return 0
}

################################################################################
# _registry_abort_wave SIGNAL
# INT/TERM handler while a parallel wave runs: stops the background installs
# (whole process groups), removes their buffered output and re-raises SIGNAL.
# (Background jobs do not receive the terminal's SIGINT, so they must be
# stopped here.)
################################################################################
_registry_abort_wave() {
    local sig="$1" pid
    stop_spinner
    for pid in ${_REGISTRY_WAVE_PIDS[@]+"${_REGISTRY_WAVE_PIDS[@]}"}; do
        _registry_terminate_job "${pid}"
    done
    [[ -n "${_REGISTRY_WAVE_DIR:-}" ]] && rm -rf "${_REGISTRY_WAVE_DIR}"
    trap - "${sig}"
    kill -s "${sig}" "$$"
}

################################################################################
# _registry_defer_signal SIGNAL
# Temporary INT/TERM handler used while module jobs are being launched: it only
# records the signal, so a job's PID can never be left unrecorded.  The launch
# loop acts on it once the PID is in _REGISTRY_WAVE_PIDS.
################################################################################
_registry_defer_signal() {
    _REGISTRY_PENDING_SIG="$1"
}

################################################################################
# _registry_job_done PID — returns 0 once the background job PID has exited
# (gone, or a zombie not yet reaped by `wait`).
################################################################################
_registry_job_done() {
    local state
    state=$(ps -p "$1" -o stat= 2>/dev/null) || state=""
    [[ -z "${state}" || "${state}" == Z* ]]
}

################################################################################
# _registry_run_parallel INDEX...
# Installs the given modules concurrently (one background subshell each) and
# waits for them.  Each module's output is buffered under a temp dir and
# written out only after the wave ends, in the order given, so it is never
# interleaved:  <id>.log -> LOG_FILE,  <id>.out -> stdout,  <id>.err -> stderr.
# Fail-fast: the first required module that fails stops the modules of the wave
# that are still running (reported as aborted); everything is then flushed.
# Returns 1 if a required module failed.
################################################################################
_registry_run_parallel() {
    local i names="" k rc failed=0 dir id prev_int prev_term had_monitor=0
    local mods=("$@") remaining=$# culprit=-1
    # Path of the real log: inside a wave each module's LOG_FILE is a temp file
    # that is deleted afterwards, so messages must point users here instead.
    # shellcheck disable=SC2034  # read by module scripts running in the subshells
    local INSTALL_LOG_FILE="${LOG_FILE:-}"
    _REGISTRY_WAVE_PIDS=()
    local rcs=()

    dir=$(mktemp -d "${TMPDIR:-/tmp}/causa-$$-wave-XXXXXX") || {
        log_error "Failed to create a temporary directory for parallel install"
        return 1
    }
    _REGISTRY_WAVE_DIR="${dir}"

    for i in "$@"; do
        names+="${names:+, }${_MOD_NAME[i]}"
    done
    write_to_log_file "INFO" "Installing in parallel: ${names}"

    prev_int=$(trap -p INT);   prev_term=$(trap -p TERM)
    # While launching, only record a signal; act on it once every launched PID
    # is recorded (see _registry_defer_signal).
    _REGISTRY_PENDING_SIG=""
    trap '_registry_defer_signal INT'  INT
    trap '_registry_defer_signal TERM' TERM

    start_spinner "Installing ${names}..."
    # Job control gives every module job its own process group (see
    # _registry_terminate_job); restore the caller's setting afterwards.
    [[ $- == *m* ]] && had_monitor=1
    set -m
    for i in "$@"; do
        id="${_MOD_ID[i]}"
        (
            # The child writes its file log to its own buffer; `|| rc=$?` keeps
            # errexit off inside install_fn, exactly as in the serial path.
            # The override is deliberately local to this subshell.
            # shellcheck disable=SC2030
            LOG_FILE="${dir}/${id}.log"
            trap - EXIT
            rc=0
            "${_MOD_INSTALL_FN[i]}" || rc=$?
            exit "${rc}"
        ) </dev/null >"${dir}/${id}.out" 2>"${dir}/${id}.err" &
        _REGISTRY_WAVE_PIDS+=("$!")
        [[ -z "${_REGISTRY_PENDING_SIG}" ]] || break
    done
    [[ ${had_monitor} -eq 1 ]] || set +m

    trap '_registry_abort_wave INT'  INT
    trap '_registry_abort_wave TERM' TERM
    if [[ -n "${_REGISTRY_PENDING_SIG}" ]]; then
        _registry_abort_wave "${_REGISTRY_PENDING_SIG}"
    fi

    # Poll (bash 3.2 has no `wait -n`) until every job is done or a required
    # module has failed.
    while [[ ${remaining} -gt 0 && ${culprit} -lt 0 ]]; do
        for k in "${!_REGISTRY_WAVE_PIDS[@]}"; do
            [[ -z "${rcs[k]:-}" ]] || continue
            _registry_job_done "${_REGISTRY_WAVE_PIDS[k]}" || continue
            rc=0
            wait "${_REGISTRY_WAVE_PIDS[k]}" || rc=$?
            rcs[k]="${rc}"
            remaining=$(( remaining - 1 ))
            if [[ ${rc} -ne 0 && ${rc} -ne ${REGISTRY_RC_SKIPPED} \
                  && "${_MOD_REQUIRED[${mods[k]}]}" == "true" ]]; then
                culprit=${k}
                break
            fi
        done
        [[ ${remaining} -gt 0 && ${culprit} -lt 0 ]] && sleep 0.2
    done

    # Fail-fast: stop the siblings that are still running
    if [[ ${culprit} -ge 0 ]]; then
        for k in "${!_REGISTRY_WAVE_PIDS[@]}"; do
            [[ -z "${rcs[k]:-}" ]] || continue
            _registry_terminate_job "${_REGISTRY_WAVE_PIDS[k]}"
            rcs[k]="aborted"
        done
    fi
    stop_spinner

    eval "${prev_int:-trap - INT}"
    eval "${prev_term:-trap - TERM}"
    _REGISTRY_WAVE_PIDS=()

    # Flush in order, then record outcomes
    k=0
    for i in "$@"; do
        id="${_MOD_ID[i]}"
        # shellcheck disable=SC2031  # LOG_FILE here is the parent's, not the child's
        if [[ -n "${LOG_FILE:-}" ]]; then
            cat "${dir}/${id}.log" >> "${LOG_FILE}" 2>/dev/null || true
        fi
        cat "${dir}/${id}.out" 2>/dev/null || true
        cat "${dir}/${id}.err" >&2 2>/dev/null || true
        if [[ "${rcs[k]}" == "aborted" ]]; then
            _MOD_STATUS[i]="skipped"
            log_warn "${_MOD_NAME[i]} aborted: ${_MOD_NAME[${mods[culprit]}]} failed"
        else
            _registry_finish_module "${i}" "${rcs[k]}" || failed=1
        fi
        k=$(( k + 1 ))
    done

    rm -rf "${dir}"
    _REGISTRY_WAVE_DIR=""
    [[ ${failed} -eq 0 ]]
}

################################################################################
# registry_install_all
# Installs matching modules wave by wave.  Populates REGISTRY_INSTALLED with the
# display names of modules that installed successfully.
#
# Modules of one wave run concurrently.  A failing required module aborts the
# installer once its wave has finished; no later wave is started.
################################################################################
registry_install_all() {
    REGISTRY_INSTALLED=()
    _MOD_STATUS=()      # per module: ok | failed | skipped | filtered
    local i dep d unmet name w max_wave=0 not_applicable=""
    local batch

    # Report non-applicable modules once, up front, so the skips are not
    # interleaved with (and mistaken for part of) another module's output.
    for i in "${_MOD_ORDER[@]}"; do
        _registry_matches_target "${i}" && continue
        _MOD_STATUS[i]="filtered"
        not_applicable+="${not_applicable:+, }${_MOD_NAME[i]}"
    done
    if [[ -n "${not_applicable}" ]]; then
        log_section_silent "Modules not applicable to target '${INSTALL_TARGET:-kind}'"
        write_to_log_file "INFO" "Not installed: ${not_applicable}"
    fi

    for i in "${_MOD_ORDER[@]}"; do
        [[ ${_MOD_WAVE[i]} -gt ${max_wave} ]] && max_wave=${_MOD_WAVE[i]}
    done

    for (( w = 1; w <= max_wave; w++ )); do
        batch=()

        # Dependencies always live in earlier waves, so their status is final.
        for i in "${_MOD_ORDER[@]}"; do
            [[ ${_MOD_WAVE[i]} -eq ${w} ]] || continue
            [[ "${_MOD_STATUS[i]:-}" == "filtered" ]] && continue
            name="${_MOD_NAME[i]}"

            unmet=""
            for dep in ${_MOD_DEPS[i]}; do
                d=$(_registry_index_of "${dep}")
                # A dependency that does not apply to this target can never be
                # installed here, so it is not a reason to skip the dependent.
                [[ "${_MOD_STATUS[d]:-}" == "filtered" ]] && continue
                [[ "${_MOD_STATUS[d]:-}" == "ok" ]] || unmet+="${unmet:+ }${dep}"
            done
            if [[ -n "${unmet}" ]]; then
                _MOD_STATUS[i]="skipped"
                if [[ "${_MOD_REQUIRED[i]}" == "true" ]]; then
                    log_error "Cannot install ${name}: dependency not installed (${unmet})"
                    exit 1
                fi
                log_warn "${name} skipped: dependency not installed (${unmet})"
                continue
            fi
            batch+=("${i}")
        done

        [[ ${#batch[@]} -eq 0 ]] && continue
        _registry_run_parallel "${batch[@]}" || exit 1
    done
    return 0
}

################################################################################
# _registry_health_fn INDEX
# Prints the module's health function name (<id>_health) if its own source_lib
# defines one; prints nothing otherwise.  Same origin rule as install_fn: a
# function defined in any other file is ignored.
################################################################################
_registry_health_fn() {
    local fn="${_MOD_ID[$1]}_health" fn_file=""
    read -r _ _ fn_file < <( shopt -s extdebug; declare -F "${fn}" 2>/dev/null ) || true
    if [[ "${fn_file}" == "${SCRIPT_DIR}/${_MOD_LIB[$1]}" ]]; then
        echo "${fn}"
    fi
}

################################################################################
# registry_check_health
# Health-checks the modules that match INSTALL_TARGET, in install order, using
# each module's <id>_health function.  The check is against live cluster state
# and runs whatever the module's install status was, so a leftover unhealthy
# deployment from a failed or skipped install is still reported.
#   health function exit 0 -> healthy (✓)
#   health function exit 2 -> not deployed (yellow "not installed"), no failure
#   any other exit         -> unhealthy (✗); stdout, if any, is shown as detail
#   no <id>_health         -> not checked
#   not applicable to target -> omitted
# Populates REGISTRY_HEALTH_LINES with one colored line per checked module.
# Returns 1 if any checked module is unhealthy.
################################################################################
registry_check_health() {
    REGISTRY_HEALTH_LINES=()
    local failed=0 i fn name detail rc

    for i in "${_MOD_ORDER[@]}"; do
        _registry_matches_target "${i}" || continue
        fn=$(_registry_health_fn "${i}")
        [[ -n "${fn}" ]] || continue
        name="${_MOD_NAME[i]}"

        rc=0
        detail=$("${fn}") || rc=$?
        case "${rc}" in
            0)
                REGISTRY_HEALTH_LINES+=("${COLOR_BOLD_GREEN}${name} ✓${COLOR_RESET}")
                ;;
            2)
                REGISTRY_HEALTH_LINES+=("${COLOR_YELLOW}${name} — not installed${COLOR_RESET}")
                ;;
            *)
                REGISTRY_HEALTH_LINES+=("${COLOR_BOLD_RED}${name} ✗${detail:+ — ${detail}}${COLOR_RESET}")
                failed=$(( failed + 1 ))
                ;;
        esac
    done

    [[ ${failed} -eq 0 ]]
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
