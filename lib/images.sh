#!/usr/bin/env bash

################################################################################
# Images Library — Causa RCA Installer
#
# lib/images.env is the ONLY place image variables are declared.  Everything
# else (initialisation, <VAR>_OVERRIDDEN sentinels, CLI flags, --help text and
# format validation) is derived from it, so adding a component image means
# adding one entry to lib/images.env — nothing in install.sh or validator.sh.
#
# Conventions for lib/images.env entries:
#
#   # Quarkus MCP Server                  <- comment on the line directly above
#   QUARKUS_MCP_IMAGE=${QUARKUS_MCP_IMAGE:-quay.io/org/quarkus-mcp:0.0.2}
#
#   - variable name  ^[A-Z][A-Z0-9_]*_IMAGE=   (anything else is ignored)
#   - CLI flag       derived from the name:  QUARKUS_MCP_IMAGE -> --quarkus-mcp-image
#   - --help text    "Override <comment>" (text from " (" onwards is dropped;
#                    " image" is appended if the comment lacks it)
#
# Provides:
#   images_load [FILE]              discover images, initialise + export
#                                   <VAR> and <VAR>_OVERRIDDEN=false
#   images_has_flag FLAG            0 if FLAG is a discovered image flag
#   images_set_override FLAG VALUE  apply a CLI override (sets <VAR>, marks
#                                   <VAR>_OVERRIDDEN=true); 1 if FLAG unknown
#   images_usage                    print one --help line per image flag
#   IMAGE_VARS / IMAGE_FLAGS        parallel arrays used by the validator
#
# Requires: bash 3.2+ (no associative arrays).
################################################################################

# Prevent multiple sourcing
if [[ -n "${IMAGES_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly IMAGES_LIB_LOADED=1

# Parallel arrays — one slot per image, in images.env order.
IMAGE_VARS=()    # e.g. CAUSA_MCP_IMAGE
IMAGE_FLAGS=()   # e.g. --causa-mcp-image
IMAGE_DESCS=()   # e.g. Causa MCP Server

################################################################################
# images_flag_for_var VAR — prints the CLI flag derived from a variable name
################################################################################
images_flag_for_var() {
    local name
    name=$(printf '%s' "$1" | tr 'A-Z_' 'a-z-')
    printf -- '--%s\n' "${name}"
}

################################################################################
# images_load [FILE]
# Discovers image variables from FILE (default lib/images.env).  The file itself
# is sourced by install.sh before this runs, so values from the environment or
# the file are already in place; this only registers the names and makes sure
# every variable and its sentinel exist and are exported.
################################################################################
images_load() {
    local file="${1:-${SCRIPT_DIR}/lib/images.env}"
    IMAGE_VARS=(); IMAGE_FLAGS=(); IMAGE_DESCS=()

    if [[ ! -f "${file}" ]]; then
        return 0
    fi

    local line var desc="" flag
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^#[[:space:]]*(.*)$ ]]; then
            desc="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "${line}" =~ ^([A-Z][A-Z0-9_]*_IMAGE)= ]]; then
            var="${BASH_REMATCH[1]}"
            flag=$(images_flag_for_var "${var}")
            desc="${desc%% (*}"   # drop trailing "(details)" from the comment
            [[ -z "${desc}" ]] && desc="${var}"
            [[ "${desc}" == *[Ii]mage* ]] || desc="${desc} image"

            IMAGE_VARS+=("${var}")
            IMAGE_FLAGS+=("${flag}")
            IMAGE_DESCS+=("${desc}")

            printf -v "${var}" '%s' "${!var:-}"
            printf -v "${var}_OVERRIDDEN" '%s' "false"
            # shellcheck disable=SC2163  # indirect export by name is intended
            export "${var}" "${var}_OVERRIDDEN"
        fi
        desc=""
    done < "${file}"
    return 0
}

################################################################################
# images_has_flag FLAG — returns 0 if FLAG is an image override flag
################################################################################
images_has_flag() {
    local f
    for f in ${IMAGE_FLAGS[@]+"${IMAGE_FLAGS[@]}"}; do
        [[ "${f}" == "$1" ]] && return 0
    done
    return 1
}

################################################################################
# images_set_override FLAG VALUE
################################################################################
images_set_override() {
    local i
    for i in "${!IMAGE_FLAGS[@]}"; do
        [[ "${IMAGE_FLAGS[i]}" == "$1" ]] || continue
        printf -v "${IMAGE_VARS[i]}" '%s' "$2"
        printf -v "${IMAGE_VARS[i]}_OVERRIDDEN" '%s' "true"
        return 0
    done
    return 1
}

################################################################################
# images_usage — one aligned --help line per image flag
################################################################################
images_usage() {
    local i
    for i in "${!IMAGE_FLAGS[@]}"; do
        printf '    %-42s Override %s\n' "${IMAGE_FLAGS[i]} IMAGE" "${IMAGE_DESCS[i]}"
    done
}
