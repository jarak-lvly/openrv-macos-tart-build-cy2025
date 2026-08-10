#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s expand_aliases
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SOURCE_DIR="${OPENRV_SOURCE_DIR}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--source DIR]

Installs, relocates, ad-hoc signs, verifies, and packages the validated OpenRV v${OPENRV_VERSION} / ${VFX_PLATFORM} build.
USAGE
}

while (($#)); do
  case "$1" in
    --source)
      SOURCE_DIR="$2"
      shift 2
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

start_stage "package-openrv"
source_openrv_environment
require_dir "${SOURCE_DIR}"
require_file "${SOURCE_DIR}/rvcmds.sh"
require_command install_name_tool
require_command otool
require_command codesign
require_command ditto
require_command shasum
require_command xargs
require_command file
require_command git
require_command brew

# Parallelism for the file(1)/codesign passes below. Ad-hoc signing
# (--sign -) touches no keychain or network resource, so it's safe to
# fan out across every core.
NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Temp indices of Mach-O files, built once per tree and reused by every
# later step instead of re-walking + re-`file`-testing the whole bundle
# on every pass (the old script did this walk-and-test 10+ times over).
STAGED_INDEX="$(mktemp "${TMPDIR:-/tmp}/openrv-staged-macho.XXXXXX")"
CONTENTS_INDEX="$(mktemp "${TMPDIR:-/tmp}/openrv-install-macho.XXXXXX")"
cleanup_indices() {
  rm -f "${STAGED_INDEX}" "${CONTENTS_INDEX}"
}
trap cleanup_indices EXIT

# Build a NUL-delimited list of Mach-O files under $1, in parallel, and
# write it to $2. One `file` invocation per file, but fanned out across
# NPROC workers instead of run serially, and run exactly once per tree
# instead of once per rewrite/scan/sign step.
build_macho_index() {
  local root="$1"
  local index_file="$2"
  local total macho_count
  total="$(find "${root}" -type f | wc -l | tr -d ' ')"
  log "Indexing Mach-O files under ${root} (${total} files, ${NPROC} parallel file(1) workers)."
  : > "${index_file}"
  find "${root}" -type f -print0 |
    xargs -0 -P "${NPROC}" -I{} sh -c '
      case "$(file -b "$1" 2>/dev/null)" in
        *Mach-O*) printf "%s\0" "$1" ;;
      esac
    ' _ {} > "${index_file}"
  macho_count="$(tr -cd '\0' < "${index_file}" | wc -c | tr -d ' ')"
  log "Found ${macho_count} Mach-O files under ${root}."
}

cd "${SOURCE_DIR}"

remote="$(git -C "${SOURCE_DIR}" remote get-url origin 2>/dev/null || true)"
[[ "${remote}" == "${OPENRV_REPOSITORY}" || "${remote}" == "git@github.com:AcademySoftwareFoundation/OpenRV.git" ]] \
  || fatal "Unexpected OpenRV origin: ${remote:-unknown}"
actual_tag="$(git -C "${SOURCE_DIR}" describe --tags --exact-match 2>/dev/null || true)"
assert_equals "${OPENRV_TAG}" "${actual_tag}" "OpenRV checkout"

cache="${SOURCE_DIR}/_build/CMakeCache.txt"
require_file "${cache}"
cache_vfx="$(sed -n 's/^RV_VFX_PLATFORM:STRING=//p' "${cache}" | tail -n 1)"
assert_equals "${VFX_PLATFORM}" "${cache_vfx}" "Configured VFX Platform"

export RV_VFX_PLATFORM="${VFX_PLATFORM}"

# OpenRV's rvcmds.sh is not written to run under Bash nounset/pipefail.
# Temporarily relax those options while sourcing it, then restore them.
set +u
set +o pipefail
# shellcheck disable=SC1091
source rvcmds.sh
set -o pipefail
set -u

STAGED_APP="${SOURCE_DIR}/_build/stage/app/RV.app"
STAGED_CONTENTS="${STAGED_APP}/Contents"
STAGED_LIB="${STAGED_CONTENTS}/lib"
STAGED_RV="${STAGED_CONTENTS}/MacOS/RV"
require_dir "${STAGED_APP}"
require_file "${STAGED_RV}"

log "Correcting staged libpng install names."
for png in \
  "${STAGED_LIB}/libpng.dylib" \
  "${STAGED_LIB}/libpng16.dylib" \
  "${STAGED_LIB}/libpng16.16.dylib" \
  "${STAGED_LIB}/libpng16.16.55.0.dylib"; do
  [[ -e "${png}" ]] || fatal "Expected staged libpng file not found: ${png}"
  run_logged install_name_tool -id '@rpath/libpng16.16.dylib' "${png}"
done

if otool -L "${STAGED_RV}" | grep -q $'^\tlibpng16\.16\.dylib'; then
  run_logged install_name_tool -change libpng16.16.dylib '@rpath/libpng16.16.dylib' "${STAGED_RV}"
fi

build_macho_index "${STAGED_CONTENTS}" "${STAGED_INDEX}"

bare_png=""
while IFS= read -r -d '' candidate; do
  if otool -L "${candidate}" 2>/dev/null | grep -q $'^\tlibpng16\.16\.dylib'; then
    log "Rewriting staged libpng consumer: ${candidate}"
    run_logged install_name_tool -change libpng16.16.dylib '@rpath/libpng16.16.dylib' "${candidate}"
    if otool -L "${candidate}" 2>/dev/null | grep -q $'^\tlibpng16\.16\.dylib'; then
      bare_png+="${candidate}"$'\n'
    fi
  fi
done < "${STAGED_INDEX}"
[[ -z "${bare_png}" ]] || fatal "Bare staged libpng references remain:\n${bare_png}"

log "Installing OpenRV from a clean destination."
rm -rf "${SOURCE_DIR}/_install/RV.app" "${SOURCE_DIR}/_install/OpenRV.app"

# rvinst is defined by OpenRV's rvcmds.sh and is not safe under
# Bash nounset/pipefail. Temporarily relax those options while it runs.
set +u
set +o pipefail
rvinst 2>&1 | tee -a "${CURRENT_LOG}"
rvinst_rc=${PIPESTATUS[0]}
set -o pipefail
set -u

(( rvinst_rc == 0 )) || exit "${rvinst_rc}"

require_dir "${SOURCE_DIR}/_install/RV.app"
mv "${SOURCE_DIR}/_install/RV.app" "${SOURCE_DIR}/_install/OpenRV.app"

APP="${SOURCE_DIR}/_install/OpenRV.app"
CONTENTS="${APP}/Contents"
LIBDIR="${CONTENTS}/lib"
PYDYN="${LIBDIR}/python3.11/lib-dynload"
require_dir "${PYDYN}"

log "Verifying OIIO configuration and installed dependency set."
OIIO_CACHE="${SOURCE_DIR}/_build/RV_DEPS_OIIO/build/CMakeCache.txt"
require_file "${OIIO_CACHE}"
grep -E '^(USE_HEIF|USE_JXL):' "${OIIO_CACHE}" | tee -a "${CURRENT_LOG}"
grep -q '^USE_HEIF:.*=OFF$' "${OIIO_CACHE}" || fatal "OIIO USE_HEIF is not OFF. Rebuild after applying the validated source patch."
grep -q '^USE_JXL:.*=OFF$' "${OIIO_CACHE}" || fatal "OIIO USE_JXL is not OFF. Rebuild after applying the validated source patch."

for oiio in \
  "${LIBDIR}/libOpenImageIO.dylib" \
  "${LIBDIR}/libOpenImageIO.3.1.dylib" \
  "${LIBDIR}/libOpenImageIO.3.1.12.dylib"; do
  require_file "${oiio}"
  if otool -L "${oiio}" | grep -Eq 'libheif|libjxl|/opt/homebrew/.*/(libheif|jpeg-xl)'; then
    fatal "Unsupported HEIF/JPEG XL dependency remains in ${oiio}."
  fi
done

log "Bundling validated Homebrew runtime libraries."
LIBDEFLATE_SRC="$(brew --prefix libdeflate)/lib/libdeflate.0.dylib"
LZMA_SRC="$(brew --prefix xz)/lib/liblzma.5.dylib"
READLINE_SRC="$(brew --prefix readline)/lib/libreadline.8.dylib"
TCL_SRC="$(brew --prefix tcl-tk@8)/lib/libtcl8.6.dylib"
TK_SRC="$(brew --prefix tcl-tk@8)/lib/libtk8.6.dylib"

for src in "${LIBDEFLATE_SRC}" "${LZMA_SRC}" "${READLINE_SRC}" "${TCL_SRC}" "${TK_SRC}"; do
  require_file "${src}"
  run_logged cp -f "${src}" "${LIBDIR}/"
done

run_logged install_name_tool -id '@rpath/libdeflate.0.dylib' "${LIBDIR}/libdeflate.0.dylib"
run_logged install_name_tool -id '@rpath/liblzma.5.dylib' "${LIBDIR}/liblzma.5.dylib"
run_logged install_name_tool -id '@rpath/libreadline.8.dylib' "${LIBDIR}/libreadline.8.dylib"
run_logged install_name_tool -id '@rpath/libtcl8.6.dylib' "${LIBDIR}/libtcl8.6.dylib"
run_logged install_name_tool -id '@rpath/libtk8.6.dylib' "${LIBDIR}/libtk8.6.dylib"

# Index the final install tree once. Everything from here through signing
# reuses this same list instead of re-walking Contents each time.
build_macho_index "${CONTENTS}" "${CONTENTS_INDEX}"

rewrite_all_consumers() {
  local old="$1"
  local new="$2"
  while IFS= read -r -d '' candidate; do
    if otool -L "${candidate}" 2>/dev/null | grep -qF "${old}"; then
      log "Rewriting dependency in ${candidate}: ${old} -> ${new}"
      run_logged install_name_tool -change "${old}" "${new}" "${candidate}"
    fi
  done < "${CONTENTS_INDEX}"
}

rewrite_all_consumers "${LIBDEFLATE_SRC}" '@rpath/libdeflate.0.dylib'
rewrite_all_consumers "${LZMA_SRC}" '@rpath/liblzma.5.dylib'
rewrite_all_consumers "${READLINE_SRC}" '@rpath/libreadline.8.dylib'
rewrite_all_consumers "${TCL_SRC}" '@rpath/libtcl8.6.dylib'
rewrite_all_consumers "${TK_SRC}" '@rpath/libtk8.6.dylib'

# Preserve the specific validated Python extension checks as hard requirements.
require_file "${PYDYN}/_lzma.cpython-311-darwin.so"
require_file "${PYDYN}/readline.cpython-311-darwin.so"
require_file "${PYDYN}/_tkinter.cpython-311-darwin.so"

log "Normalizing bundled dylib install IDs."
while IFS= read -r -d '' candidate; do
  case "${candidate}" in
    "${LIBDIR}"/*) ;;
    *) continue ;;
  esac
  [[ -L "${candidate}" ]] && continue

  current_id="$(
    otool -D "${candidate}" 2>/dev/null |
      awk -v prefix="${SOURCE_DIR}/_build/" 'index($0, prefix) == 1 { print; exit }'
  )"

  [[ -n "${current_id}" ]] || continue

  new_id="@rpath/$(basename "${current_id}")"
  log "Rewriting dylib ID in ${candidate}: ${current_id} -> ${new_id}"
  run_logged install_name_tool -id "${new_id}" "${candidate}"
done < "${CONTENTS_INDEX}"

# Homebrew-reference and build-machine-reference scans used to be two
# separate full-tree passes (scan_macho_refs called twice, each doing its
# own find + is_macho + otool -L). Now it's one pass over the cached
# index with one otool -L per file, checked against both patterns.
# This must run after ID normalization above, so it's scanning the
# already-corrected install names rather than stale build-tree paths.
build_path_pattern="${SOURCE_DIR//\//\\/}|${HOME//\//\\/}\/Qt|\/Applications\/CMake\.app"
homebrew_pattern='/opt/homebrew/'

homebrew_refs=""
build_refs=""
while IFS= read -r -d '' candidate; do
  refs="$(otool -L "${candidate}" 2>/dev/null | grep $'^\t' || true)"
  [[ -z "${refs}" ]] && continue
  if grep -Eq "${homebrew_pattern}" <<<"${refs}"; then
    homebrew_refs+="=== ${candidate} ==="$'\n'"$(grep -E "${homebrew_pattern}" <<<"${refs}")"$'\n'
  fi
  if grep -Eq "${build_path_pattern}" <<<"${refs}"; then
    build_refs+="=== ${candidate} ==="$'\n'"$(grep -E "${build_path_pattern}" <<<"${refs}")"$'\n'
  fi
done < "${CONTENTS_INDEX}"

[[ -z "${homebrew_refs}" ]] || fatal "Homebrew references remain:\n${homebrew_refs}"
[[ -z "${build_refs}" ]] || fatal "Build-machine references remain:\n${build_refs}"

log "Ad-hoc signing OpenRV bundle."

# Bootstrap signatures for nested bundle components.
codesign --remove-signature "${APP}" 2>/dev/null || true
run_logged codesign --force --deep --sign - "${APP}"

# Re-sign every Mach-O file after relocation changes, serially. codesign
# can intermittently drop a request under concurrent load (a transient
# AMFI/daemon hiccup, not a problem with the file) and exit nonzero with
# little or no stderr — that's what happened last run, and it's exactly
# the failure mode signing one at a time avoids. sign_one also retries a
# couple of times before treating a failure as real, and logs the specific
# file and codesign's actual output if it still fails.
macho_count="$(tr -cd '\0' < "${CONTENTS_INDEX}" | wc -c | tr -d ' ')"

sign_one() {
  local f="$1" out rc attempt
  for attempt in 1 2 3; do
    out="$(codesign --force --sign - "${f}" 2>&1)"
    rc=$?
    (( rc == 0 )) && return 0
    (( attempt < 3 )) && sleep 1
  done
  printf 'FAILED after 3 attempts (rc=%s): %s\n%s\n' "${rc}" "${f}" "${out}" | tee -a "${CURRENT_LOG}" >&2
  return 1
}

log "Signing ${macho_count} Mach-O files (serial)."
fail=0
while IFS= read -r -d '' candidate; do
  sign_one "${candidate}" || fail=1
done < "${CONTENTS_INDEX}"
(( fail == 0 )) || fatal "codesign failed on one or more files; see ${CURRENT_LOG} for the specific file(s) and error(s)."

# Refresh the enclosing bundle signature after nested Mach-O signatures change,
# then perform strict verification.
run_logged codesign --force --deep --sign - "${APP}"
run_logged codesign --verify --deep --strict --verbose=2 "${APP}"

ARCHIVE="${SOURCE_DIR}/_install/${OUTPUT_NAME}"
rm -f "${ARCHIVE}" "${ARCHIVE}.sha256"
(
  cd "${SOURCE_DIR}/_install"
  ditto -c -k --sequesterRsrc --keepParent OpenRV.app "${OUTPUT_NAME}"
)
run_logged unzip -t "${ARCHIVE}"
(
  cd "$(dirname "${ARCHIVE}")"
  shasum -a 256 "$(basename "${ARCHIVE}")" > "$(basename "${ARCHIVE}").sha256"
)

MANIFEST="${SOURCE_DIR}/_install/OpenRV-${OPENRV_VERSION}-build-manifest.txt"
{
  echo "Build timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "Architecture: $(uname -m)"
  echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "SDK: $(xcrun --sdk macosx --show-sdk-path)"
  cmake_version_output="$(cmake --version)"
  echo "CMake: $(printf '%s\\n' "${cmake_version_output}" | sed -n '1p')"
  echo "Qt: $(qmake -query QT_VERSION) ($(qmake -query QT_INSTALL_PREFIX))"
  echo "OpenRV tag: $(git -C "${SOURCE_DIR}" describe --tags --exact-match 2>/dev/null || echo unknown)"
  echo "OpenRV commit: $(git -C "${SOURCE_DIR}" rev-parse HEAD)"
  echo "VFX Platform: ${RV_VFX_PLATFORM}"
  echo "Homebrew: $(brew --version | sed -n '1p')"
  echo "Homebrew runtime formulae:"
  for formula in libdeflate xz readline tcl-tk@8; do
    printf '  %s: %s\n' "${formula}" "$(brew list --versions "${formula}" 2>/dev/null || echo not-installed)"
  done
  echo "Archive: ${ARCHIVE}"
  echo "SHA-256: $(awk '{print $1}' "${ARCHIVE}.sha256")"
  echo "Homebrew Mach-O references: none"
  echo "Build-machine Mach-O references: none"
  echo "Code signature verification: passed"
} > "${MANIFEST}"

cp -f "${ARCHIVE}" "${OUTPUT_DIR}/"
cp -f "${ARCHIVE}.sha256" "${OUTPUT_DIR}/"
cp -f "${MANIFEST}" "${OUTPUT_DIR}/"

log "Packaging completed successfully."
log "Archive: ${ARCHIVE}"
log "Copied output: ${OUTPUT_DIR}/$(basename "${ARCHIVE}")"
