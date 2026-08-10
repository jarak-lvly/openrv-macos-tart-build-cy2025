#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SOURCE_DIR="${OPENRV_SOURCE_DIR}"
MODE="apply"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") [options]

By default, missing patches are applied.

Options:
  --check, --dry-run   Report patch status without modifying the source tree.
  --source DIR         OpenRV source directory. Default: ${OPENRV_SOURCE_DIR}
  -h, --help           Show this help.
USAGE
}

while (($#)); do
  case "$1" in
    --source)
      (($# >= 2)) || fatal "--source requires a directory."
      SOURCE_DIR="$2"
      shift 2
      ;;
    --check|--dry-run)
      MODE="check"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fatal "Unknown argument: $1"
      ;;
  esac
done

start_stage "apply-openrv-patches"
require_command git
require_dir "${SOURCE_DIR}"
require_dir "${SOURCE_DIR}/.git"
require_dir "${PROJECT_DIR}/patches"

remote="$(git -C "${SOURCE_DIR}" remote get-url origin 2>/dev/null || true)"
[[ "${remote}" == "${OPENRV_REPOSITORY}" || "${remote}" == "git@github.com:AcademySoftwareFoundation/OpenRV.git" ]] \
  || fatal "Unexpected OpenRV origin: ${remote:-none}"

actual_tag="$(git -C "${SOURCE_DIR}" describe --tags --exact-match 2>/dev/null || true)"
assert_equals "${OPENRV_TAG}" "${actual_tag}" "OpenRV checkout"

patches=("${PROJECT_DIR}"/patches/*.patch)
((${#patches[@]} == 4)) || fatal "Expected exactly four patch files; found ${#patches[@]}."

PATCH_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openrv-patches.XXXXXX")"
trap 'rm -rf "${PATCH_TMP_DIR}"' EXIT

configured_sdkroot="${XCODE_APP}/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/${MACOS_SDK}"
require_dir "${configured_sdkroot}"

render_patch() {
  local patch="$1"
  local name rendered replacement
  name="$(basename "${patch}")"

  if [[ "${name}" != "0003-aja-xcode-16.4-sdk.patch" ]]; then
    printf '%s\n' "${patch}"
    return 0
  fi

  grep -q '@OPENRV_MACOS_SDKROOT@' "${patch}" \
    || fatal "${name} is missing the expected @OPENRV_MACOS_SDKROOT@ template token."

  rendered="${PATCH_TMP_DIR}/${name}"
  replacement="${configured_sdkroot//\\/\\\\}"
  replacement="${replacement//&/\\&}"
  replacement="${replacement//|/\\|}"
  sed "s|@OPENRV_MACOS_SDKROOT@|${replacement}|g" "${patch}" > "${rendered}"

  grep -Fq -- "-DCMAKE_OSX_SYSROOT=${configured_sdkroot}" "${rendered}" \
    || fatal "Failed to render ${name} from XCODE_APP/MACOS_SDK configuration."

  printf '%s\n' "${rendered}"
}

applied=0
already=0
needed=0

for patch in "${patches[@]}"; do
  name="$(basename "${patch}")"
  rendered_patch="$(render_patch "${patch}")"
  log "Checking patch: ${name}"
  if [[ "${name}" == "0003-aja-xcode-16.4-sdk.patch" ]]; then
    log "Rendered ${name} with SDK root: ${configured_sdkroot}"
  fi

  if git -C "${SOURCE_DIR}" apply --check "${rendered_patch}" >/dev/null 2>&1; then
    if [[ "${MODE}" == "check" ]]; then
      log "[MISSING] ${name}"
      ((needed += 1))
    else
      run_logged git -C "${SOURCE_DIR}" apply "${rendered_patch}"
      log "APPLIED: ${name}"
      ((applied += 1))
    fi
  elif git -C "${SOURCE_DIR}" apply --reverse --check "${rendered_patch}" >/dev/null 2>&1; then
    log "[OK] ${name}"
    ((already += 1))
  else
    fatal "Patch neither applies cleanly nor appears already applied: ${name}. The source may differ from ${OPENRV_TAG} or contain conflicting edits."
  fi
done

if [[ "${MODE}" == "check" ]]; then
  log "Patch check complete."
  printf '\n  %d patch(es) can be applied.\n  %d patch(es) are already applied.\n\n' "${needed}" "${already}" | tee -a "${CURRENT_LOG}"
  printf 'No files were modified.\n' | tee -a "${CURRENT_LOG}"
  if (( needed > 0 )); then
    printf '\nRun the command again without --check to apply the missing patches.\n' | tee -a "${CURRENT_LOG}"
    exit 2
  fi
  exit 0
fi

run_logged git -C "${SOURCE_DIR}" diff --check

modified="$(git -C "${SOURCE_DIR}" status --short | awk '{print $2}' | sort)"
expected="$(cat <<'FILES' | sort
cmake/dependencies/aja.cmake
cmake/dependencies/build/png.cmake
cmake/dependencies/oiio.cmake
cmake/macros/rv_create_std_deps_vars.cmake
FILES
)"
assert_equals "${expected}" "${modified}" "Modified source files"

log "Patch processing complete: ${applied} applied; ${already} already applied."
