#!/usr/bin/env bash

set -Eeuo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${COMMON_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_DIR}/config/versions.env"

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

LOG_DIR="${PROJECT_DIR}/logs"
OUTPUT_DIR="${PROJECT_DIR}/output"
mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}"

CURRENT_STAGE="startup"
CURRENT_LOG="${LOG_DIR}/automation.log"

_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '[%s] %s\n' "$(_timestamp)" "$*" | tee -a "${CURRENT_LOG}"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(_timestamp)" "$*" | tee -a "${CURRENT_LOG}" >&2
}

fatal() {
  printf '[%s] ERROR: %s\n' "$(_timestamp)" "$*" | tee -a "${CURRENT_LOG}" >&2
  exit 1
}

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-unknown}
  local command=${BASH_COMMAND:-unknown}
  printf '[%s] FAILED stage=%s rc=%s line=%s command=%q\n' \
    "$(_timestamp)" "${CURRENT_STAGE}" "${rc}" "${line}" "${command}" \
    | tee -a "${CURRENT_LOG}" >&2
  exit "${rc}"
}
trap on_error ERR

start_stage() {
  CURRENT_STAGE="$1"
  CURRENT_LOG="${LOG_DIR}/${CURRENT_STAGE}.log"
  : > "${CURRENT_LOG}"
  log "Starting stage: ${CURRENT_STAGE}"
}

run_logged() {
  log "+ $*"
  "$@" 2>&1 | tee -a "${CURRENT_LOG}"
  local rc=${PIPESTATUS[0]}
  return "${rc}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

require_file() {
  [[ -f "$1" ]] || fatal "Required file not found: $1"
}

require_dir() {
  [[ -d "$1" ]] || fatal "Required directory not found: $1"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || fatal "${label}: expected '${expected}', got '${actual}'"
}

is_macho() {
  file "$1" 2>/dev/null | grep -q 'Mach-O'
}

source_openrv_environment() {
  require_file "${HOME}/openrv_env.sh"
  # shellcheck disable=SC1090
  source "${HOME}/openrv_env.sh"
}

openrv_source_dir() {
  printf '%s\n' "${1:-${OPENRV_SOURCE_DIR}}"
}
