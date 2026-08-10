#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s expand_aliases
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SOURCE_DIR="${OPENRV_SOURCE_DIR}"
MODE="build"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--source DIR] [--prepare-source|--configure-only|--build]

Default: reproduce the validated OpenRV ${OPENRV_VERSION} / ${VFX_PLATFORM} build.
USAGE
}

while (($#)); do
  case "$1" in
    --source)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --prepare-source)
      MODE="prepare"
      shift
      ;;
    --configure-only)
      MODE="configure"
      shift
      ;;
    --build)
      MODE="build"
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

start_stage "build-openrv"
source_openrv_environment
require_command git
require_command cmake
require_command qmake

assert_equals "${CMAKE_VERSION}" "$(cmake --version | awk 'NR==1 {print $3}')" "CMake version"
assert_equals "${QT_VERSION}" "$(qmake -query QT_VERSION)" "Qt version"
assert_equals "${XCODE_VERSION}" "$(xcodebuild -version | awk 'NR==1 {print $2}')" "Xcode version"

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  [[ ! -e "${SOURCE_DIR}" ]] || fatal "${SOURCE_DIR} exists but is not a Git repository."
  run_logged git clone --recursive --branch "${OPENRV_TAG}" "${OPENRV_REPOSITORY}" "${SOURCE_DIR}"
else
  remote="$(git -C "${SOURCE_DIR}" remote get-url origin)"
  [[ "${remote}" == "${OPENRV_REPOSITORY}" || "${remote}" == "git@github.com:AcademySoftwareFoundation/OpenRV.git" ]] \
    || fatal "Unexpected OpenRV origin: ${remote}"
fi

run_logged git -C "${SOURCE_DIR}" submodule update --init --recursive
actual_tag="$(git -C "${SOURCE_DIR}" describe --tags --exact-match 2>/dev/null || true)"
assert_equals "${OPENRV_TAG}" "${actual_tag}" "OpenRV checkout"

run_logged "${SCRIPT_DIR}/apply-openrv-patches.sh" --source "${SOURCE_DIR}"

if [[ "${MODE}" == "prepare" ]]; then
  log "Source preparation completed."
  exit 0
fi

cd "${SOURCE_DIR}"
export RV_VFX_PLATFORM="${VFX_PLATFORM}"
# OpenRV's rvcmds.sh is not written to run under Bash nounset/pipefail.
set +u
set +o pipefail
# shellcheck disable=SC1091
source rvcmds.sh
set -o pipefail
set -u

assert_equals "${VFX_PLATFORM}" "${RV_VFX_PLATFORM}" "VFX Platform"
assert_equals "${CMAKE_VERSION}" "$(cmake --version | awk 'NR==1 {print $3}')" "CMake after rvcmds.sh"
assert_equals "${QT_VERSION}" "$(qmake -query QT_VERSION)" "Qt after rvcmds.sh"

log "Running rvcfg with the validated decoder list."
set +u
set +o pipefail
rvcfg -DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="${FFMPEG_DECODERS}" 2>&1 | tee -a "${CURRENT_LOG}"
rvcfg_rc=${PIPESTATUS[0]}
set -o pipefail
set -u
(( rvcfg_rc == 0 )) || exit "${rvcfg_rc}"

cache="${SOURCE_DIR}/_build/CMakeCache.txt"
require_file "${cache}"
grep -E '^(RV_VFX_PLATFORM|RV_DEPS_QT_LOCATION|CMAKE_BUILD_TYPE|RV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE):' "${cache}" | tee -a "${CURRENT_LOG}"

grep -q '^RV_VFX_PLATFORM:STRING=CY2025$' "${cache}" || fatal "CMake cache does not contain CY2025."
grep -q "^RV_DEPS_QT_LOCATION:STRING=${HOME}/Qt/${QT_VERSION}/macos$" "${cache}" || fatal "Unexpected Qt path in CMake cache."

if [[ "${MODE}" == "configure" ]]; then
  log "Configuration completed."
  exit 0
fi

log "Running rvbootstrap. rvbuild is not run afterward."
set +u
set +o pipefail
rvbootstrap 2>&1 | tee -a "${CURRENT_LOG}"
bootstrap_rc=${PIPESTATUS[0]}
set -o pipefail
set -u
(( bootstrap_rc == 0 )) || exit "${bootstrap_rc}"

staged_rv="${SOURCE_DIR}/_build/stage/app/RV.app/Contents/MacOS/RV"
require_file "${staged_rv}"
file "${staged_rv}" | tee -a "${CURRENT_LOG}"
file "${staged_rv}" | grep -q 'Mach-O 64-bit executable arm64' || fatal "Staged RV executable is not arm64 Mach-O."

rpaths="$(otool -l "${staged_rv}" | awk '/LC_RPATH/{getline; getline; print $2}')"
grep -q '^@executable_path/../Frameworks$' <<<"${rpaths}" || fatal "Frameworks LC_RPATH is missing."
grep -q '^@executable_path/../lib$' <<<"${rpaths}" || fatal "lib LC_RPATH is missing."

log "OpenRV build completed successfully. Next: ${SCRIPT_DIR}/package-openrv.sh --source ${SOURCE_DIR}"
