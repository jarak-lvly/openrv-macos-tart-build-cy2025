#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

start_stage "provision"

require_command sw_vers
require_command uname
require_command brew
require_command curl
require_command hdiutil
require_command shasum
require_command sudo
require_command xip
require_command xcodebuild

log "Administrator access is required inside the Tart guest for /Applications installs and xcode-select."
log "sudo may prompt interactively for the guest account password."
run_logged sudo -v

actual_arch="$(uname -m)"
actual_macos="$(sw_vers -productVersion)"
actual_build="$(sw_vers -buildVersion)"

assert_equals "${EXPECTED_ARCH}" "${actual_arch}" "Guest architecture"
if [[ "${actual_macos}" != "${EXPECTED_MACOS_VERSION}" ]]; then
  warn "Validated guest version is ${EXPECTED_MACOS_VERSION}; detected ${actual_macos}."
fi
if [[ "${actual_build}" != "${EXPECTED_MACOS_BUILD}" ]]; then
  warn "Validated guest build is ${EXPECTED_MACOS_BUILD}; detected ${actual_build}."
fi

free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
if (( free_kb < 40 * 1024 * 1024 )); then
  fatal "At least 40 GiB free space is required; found approximately $((free_kb / 1024 / 1024)) GiB."
fi

log "Installing required Homebrew packages."
run_logged brew install \
  ninja zlib tcl-tk@8 automake python@3.11 yasm meson nasm glew rust ccache libdeflate \
  readline sqlite xz autoconf libtool pkgconf

PY311="$(brew --prefix python@3.11)/bin/python3.11"
require_file "${PY311}"
run_logged "${PY311}" --version
run_logged "${PY311}" -m pip install --upgrade pip
run_logged "${PY311}" -m pip install --upgrade "aqtinstall==${AQTINSTALL_VERSION}"
run_logged "${PY311}" -m aqt version

QT_HOME="${HOME}/Qt/${QT_VERSION}/macos"
if [[ -x "${QT_HOME}/bin/qmake" ]] && [[ "$("${QT_HOME}/bin/qmake" -query QT_VERSION)" == "${QT_VERSION}" ]]; then
  log "Qt ${QT_VERSION} already installed at ${QT_HOME}; skipping download."
else
  QT_MODULES=()
  while IFS= read -r module; do
    [[ -z "${module}" || "${module}" == \#* ]] && continue
    QT_MODULES+=("${module}")
  done < "${PROJECT_DIR}/config/qt-modules.txt"
  run_logged "${PY311}" -m aqt install-qt \
    mac desktop "${QT_VERSION}" "${QT_ARCH}" \
    --outputdir "${HOME}/Qt" \
    --modules "${QT_MODULES[@]}"
fi
run_logged "${QT_HOME}/bin/qmake" -query QT_VERSION
run_logged "${QT_HOME}/bin/qmake" -query QT_INSTALL_PREFIX

installed_cmake=""
if [[ -x "${CMAKE_APP}/Contents/bin/cmake" ]]; then
  installed_cmake="$(${CMAKE_APP}/Contents/bin/cmake --version | awk 'NR==1 {print $3}')"
fi
if [[ "${installed_cmake}" == "${CMAKE_VERSION}" ]]; then
  log "CMake ${CMAKE_VERSION} already installed at ${CMAKE_APP}."
else
  downloads="${HOME}/Downloads"
  mkdir -p "${downloads}"
  dmg="${downloads}/${CMAKE_DMG}"
  run_logged curl -fL "${CMAKE_URL}" -o "${dmg}"
  actual_cmake_sha256="$(shasum -a 256 "${dmg}" | awk '{print $1}')"
  assert_equals "${CMAKE_SHA256}" "${actual_cmake_sha256}" "CMake DMG SHA-256"
  log "Verified CMake DMG SHA-256 before mounting or installing it."
  mount_point="$(hdiutil attach -nobrowse "${dmg}" | awk '/\/Volumes\// {print substr($0,index($0,"/Volumes/")); exit}')"
  [[ -n "${mount_point}" ]] || fatal "Could not determine mounted CMake volume."
  run_logged sudo ditto "${mount_point}/CMake.app" "${CMAKE_APP}"
  run_logged sudo chown -R root:wheel "${CMAKE_APP}"
  run_logged hdiutil detach "${mount_point}"
fi
run_logged "${CMAKE_APP}/Contents/bin/cmake" --version

xcode_xip="${HOME}/Downloads/${XCODE_XIP}"
if [[ -d "${XCODE_APP}" ]]; then
  detected_xcode="$(DEVELOPER_DIR="${XCODE_APP}/Contents/Developer" xcodebuild -version | awk 'NR==1 {print $2}')"
  [[ "${detected_xcode}" == "${XCODE_VERSION}" ]] || fatal "${XCODE_APP} exists but reports Xcode ${detected_xcode}."
  log "Xcode ${XCODE_VERSION} already installed at ${XCODE_APP}."
else
  require_file "${xcode_xip}"
  work_dir="${HOME}/Downloads/openrv-xcode-expand"
  rm -rf "${work_dir}"
  mkdir -p "${work_dir}"
  log "+ (cd ${work_dir} && xip --expand ${xcode_xip})"
  (cd "${work_dir}" && xip --expand "${xcode_xip}") 2>&1 | tee -a "${CURRENT_LOG}"
  xip_rc=${PIPESTATUS[0]}
  (( xip_rc == 0 )) || exit "${xip_rc}"
  require_dir "${work_dir}/Xcode.app"
  run_logged sudo mv "${work_dir}/Xcode.app" "${XCODE_APP}"
  run_logged sudo chown -R root:wheel "${XCODE_APP}"
  rm -rf "${work_dir}"
fi

run_logged sudo xcode-select -s "${XCODE_APP}/Contents/Developer"
run_logged sudo xcodebuild -license accept
run_logged sudo xcodebuild -runFirstLaunch

cat > "${HOME}/openrv_env.sh" <<ENVEOF
export DEVELOPER_DIR="${XCODE_APP}/Contents/Developer"
export SDKROOT="${XCODE_APP}/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/${MACOS_SDK}"
export QT_HOME="\$HOME/Qt/${QT_VERSION}/macos"
export CMAKE_PREFIX_PATH="\$QT_HOME\${CMAKE_PREFIX_PATH:+:\$CMAKE_PREFIX_PATH}"
export PATH="${CMAKE_APP}/Contents/bin:\$QT_HOME/bin:\$PATH"
unset CC CXX CPP CXXCPP CFLAGS CXXFLAGS
ENVEOF
chmod 0644 "${HOME}/openrv_env.sh"

source_openrv_environment
assert_equals "${CMAKE_VERSION}" "$(cmake --version | awk 'NR==1 {print $3}')" "CMake version"
assert_equals "${QT_VERSION}" "$(qmake -query QT_VERSION)" "Qt version"
assert_equals "${XCODE_VERSION}" "$(xcodebuild -version | awk 'NR==1 {print $2}')" "Xcode version"
assert_equals "${XCODE_BUILD}" "$(xcodebuild -version | awk 'NR==2 {print $3}')" "Xcode build"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
[[ "${sdk_path}" == *"/${MACOS_SDK}" ]] || fatal "Expected SDK ${MACOS_SDK}; got ${sdk_path}."

run_logged ccache --version
run_logged ccache --show-stats
cat <<EOF | tee -a "${CURRENT_LOG}"

Provisioning completed successfully.

For manual OpenRV builds:

  source ${HOME}/openrv_env.sh

Clone OpenRV with its submodules, apply the validated source patches, and then
continue with rvcmds.sh, rvcfg, and rvbootstrap. See README.md for the complete
manual and automated build workflows.

To reproduce the validated OpenRV ${OPENRV_VERSION} / ${VFX_PLATFORM} build:

  ${SCRIPT_DIR}/build-openrv.sh
EOF
