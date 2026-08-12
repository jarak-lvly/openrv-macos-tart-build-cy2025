# OpenRV CY2025 / 4.0.1 macOS Tart Build Automation

This repository documents and automates a validated proof of concept for building OpenRV 4.0.1 / CY2025 inside an Apple Silicon Tart guest running macOS Tahoe. The primary goal is to provide a repeatable macOS build environment and OpenRV build workflow for an administrator who already uses Tart.

It intentionally does **not** install Tart or manage Tart VM lifecycle. The operator is expected to be familiar with Tart and to know how to pull, clone, run, and connect to a Tart VM. Tart and its Homebrew prerequisite should already be installed on the physical Apple Silicon Mac before using this repository.

## Intended scope

This is a proof of concept, not an official OpenRV build environment or a replacement for the upstream OpenRV documentation. It focuses on reproducing the macOS build inside Tart.

The repository also includes `package-openrv.sh`, which preserves the install/relocation steps used to validate that the resulting OpenRV application can run away from the build tree. Packaging is a secondary validation/convenience stage, not an attempt to provide a production macOS application distribution pipeline. The generated application is ad-hoc signed; it is not Developer ID signed or Apple-notarized.

## Tart prerequisite and starting image

The physical host should already have Homebrew and Tart installed. This repository does not document their installation or general Tart administration. The validated Cirrus Labs guest also provided Homebrew inside the VM; `provision-openrv-build-env.sh` preflights `brew` and stops if it is not available in the guest.

The validated guest can be created from the Cirrus Labs macOS Tahoe base image:

```bash
tart pull ghcr.io/cirruslabs/macos-tahoe-base:latest
```

Use that image as the clean base for a disposable build VM, then run the scripts in this repository inside the guest. For example, an operator may clone the pulled image to a local working VM before making changes.

The base image uses a 50 GB virtual disk by default. Resize the working VM to 150 GB before provisioning so there is sufficient space for Xcode, Qt, the OpenRV source/dependencies, the build tree, and packaging output. For example:

```bash
tart set <vm-name> --disk-size 150
```

The base image does not need to provide the OpenRV compiler toolchain. The provisioning workflow installs the user-supplied Xcode 16.4 archive as `/Applications/Xcode_16.4.app`, selects it with `xcode-select`, initializes it, and verifies build `16F6` plus the macOS 15.5 SDK. A clean validation run from `macos-tahoe-base:latest` completed provisioning, the OpenRV build, and packaging successfully without relying on the Xcode image.

The registry tag `latest` is intentionally the upstream moving tag. It may resolve to a newer macOS base in the future. The exact guest OS and toolchain versions successfully tested for this proof of concept are listed below; the provisioning script warns when the guest macOS version/build differs from the validated values.

## Tested configuration

| Component | Tested value | Notes |
| --- | --- | --- |
| Physical host | Apple Silicon iMac | Tart host |
| Tart | 2.32.1 | Installed on the physical Mac |
| Tart base image | `ghcr.io/cirruslabs/macos-tahoe-base:latest` | Upstream moving tag validated without a preinstalled Xcode toolchain |
| Guest macOS | Tahoe 26.4, build 25E246 | Exact validated guest |
| Guest architecture | arm64 | Required by the automation |
| Guest disk | 150 GB Tart virtual disk; 139 GiB APFS filesystem | Base image defaults to 50 GB; resize the working VM before provisioning; provisioning requires at least 40 GiB free |
| Guest CPU / RAM | 4 vCPUs / 8 GB RAM | Actual validated Tart guest allocation; the automation does not enforce CPU/RAM |
| Xcode | 16.4, build 16F6 | Installed side-by-side by this repository from the user-supplied XIP and selected for the build |
| macOS SDK | 15.5 | From Xcode 16.4 |
| CMake | 3.31.7 | Installed by the provisioning script |
| Qt | 6.5.3 | Installed with `aqtinstall` 3.3.0 |
| OpenRV | v4.0.1 | Validated source tag |
| VFX Reference Platform | CY2025 | Validated build configuration |


### Observed build times

On the tested Tart guest (4 vCPUs, 8 GB RAM), the successful clean validation run
from `macos-tahoe-base:latest` on August 11, 2026 produced the following wall-clock times:

| Stage | Observed time |
| --- | ---: |
| Provision build environment | ~4m 23s |
| Build OpenRV | ~33m 49s |
| Package OpenRV | ~5m 49s |

**Provisioning note:** The Xcode 16.4 `.xip` had already been downloaded before
this validation run. The provisioning time therefore excludes the Xcode
download. Download time will vary with network performance.

**Build note:** The OpenRV build was performed with an empty ccache
(`0.0 / 5.0 GiB`), so the ~33m 49s measurement represents a cold build rather
than a rebuild benefiting from cached compilation.

These are observed times from the validated configuration, not performance
guarantees. Times will vary with host hardware, Tart resource allocation,
network performance, and caching.


### Guest resources

The validated Tart build guest used 4 vCPUs, 8 GB of memory, and a 150 GB virtual disk. Inside macOS, the root APFS filesystem reported a 139 GiB size. These values describe the tested configuration rather than hard minimum requirements. The automation enforces free-disk-space checks because disk exhaustion is a predictable build failure; it does not enforce CPU or RAM values. Use `tart get <vm-name>` on the host to confirm the allocation for a build VM before starting.

The scripts intentionally fix the versions that were important to the validated OpenRV build, such as Xcode, CMake, Qt, OpenRV, and the VFX Platform. Homebrew formulae installed as build prerequisites are not frozen to historical formula revisions; Homebrew may therefore supply newer compatible package revisions when the environment is rebuilt later. This repository is intended to reproduce the validated build procedure, not to provide a bit-for-bit hermetic build environment.

## Guest account requirement

Run the automation from an administrator account inside the Tart guest. Provisioning uses `sudo` to install CMake and Xcode under `/Applications`, change the system-wide selected Xcode, and initialize that Xcode installation. The script performs `sudo -v` near the beginning of provisioning, so an interactive password prompt is expected unless the guest already has a valid sudo credential timestamp.

The provisioning preflight also requires the macOS `xip` utility because the supplied Xcode archive is expanded with `xip --expand`.

## Manual prerequisite: Xcode 16.4

Download `Xcode_16.4.xip` from the Apple Developer portal. Apple authentication and download are not automated.

Copy the file into the guest as:

```bash
~/Downloads/Xcode_16.4.xip
```

For example, from the physical Mac:

```bash
scp ~/Downloads/Xcode_16.4.xip admin@<tart-vm-ip>:~/Downloads/
```

## Repository contents

```
openrv-macos-tart-build-cy2025/
├── config/
│   ├── qt-modules.txt               Exact Qt module list
│   └── versions.env                 Validated versions and build settings
├── LICENSE                          MIT license for this repository
├── logs/                            Automation logs
├── output/                          Copies of final artifacts
├── patches/                         Four validated OpenRV source patches
│   ├── 0001-dependency-rpath-defaults.patch
│   ├── 0002-libpng-rpath.patch
│   ├── 0003-aja-xcode-16.4-sdk.patch
│   └── 0004-disable-oiio-heif-jxl.patch
├── README.md
└── scripts/
    ├── apply-openrv-patches.sh
    ├── build-openrv.sh
    ├── lib/
    │   └── common.sh
    ├── package-openrv.sh
    └── provision-openrv-build-env.sh
```

## 1. Provision the guest build environment

Run inside the Tart guest:

```bash
./scripts/provision-openrv-build-env.sh
```

The script:

- validates the guest architecture and reports macOS version differences;
- installs the required Homebrew packages;
- installs `aqtinstall` with Homebrew Python 3.11;
- installs Qt 6.5.3 and only the documented modules;
- downloads CMake 3.31.7, verifies its configured SHA-256 checksum, and only then mounts/installs it under `/Applications/CMake.app`;
- expands and installs the supplied Xcode 16.4 archive;
- selects and initializes Xcode 16.4;
- creates `~/openrv_env.sh`; and
- verifies the resulting toolchain.

Provisioning intentionally modifies the disposable Tart guest: it installs Homebrew formulae, writes CMake and Xcode under `/Applications`, changes the guest's system-wide selected Xcode with `xcode-select`, accepts/initializes that Xcode installation, and writes `~/openrv_env.sh`. These changes are expected inside the dedicated build VM and are one reason a disposable Tart clone is recommended. The script validates sudo access near startup so privilege problems fail before lengthy downloads or build work begin.

## Workflow

The automation follows the same overall split as the upstream OpenRV documentation:
prepare the macOS build environment first, then build OpenRV.

- Preparing Open RV on macOS: https://aswf-openrv.readthedocs.io/en/latest/build_system/config_macos.html
- Building Open RV: https://aswf-openrv.readthedocs.io/en/latest/build_system/config_common_build.html


```
Cirrus Labs Tart guest
        |
        v
./scripts/provision-openrv-build-env.sh
        |
        |  Xcode 16.4
        |  CMake 3.31.7
        |  Qt 6.5.3
        |  build dependencies
        |  ~/openrv_env.sh
        v
Provisioned build environment
        |
        +------------------------------+
        |                              |
        v                              v
./scripts/build-openrv.sh       Manual OpenRV workflow
        |                       (collapsed below)
        v
OpenRV 4.0.1 / CY2025
staged application
        |
        v
./scripts/package-openrv.sh
        |
        v
output/OpenRV-4.0.1-macos-arm64.zip
```

The automated path is the validated workflow for this proof of concept. The manual
workflow remains available for troubleshooting, experimentation, or changing
OpenRV configuration.

## 2. Build OpenRV

At this point, the validated build environment is ready.

Choose one of the following workflows.

<details>
<summary><strong>Option A — Manual OpenRV build</strong></summary>

### Option A — Manual OpenRV build

Use the standard OpenRV build process. On macOS, start a Bash shell first so
OpenRV's `rvcmds.sh` runs in the same shell family used by the automation:

Provisioning creates `~/openrv_env.sh`. For the validated configuration, the
generated file is:

```bash
export DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
export SDKROOT="/Applications/Xcode_16.4.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk"
export QT_HOME="$HOME/Qt/6.5.3/macos"
export CMAKE_PREFIX_PATH="$QT_HOME${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PATH="/Applications/CMake.app/Contents/bin:$QT_HOME/bin:$PATH"
unset CC CXX CPP CXXCPP CFLAGS CXXFLAGS
```

Source this file before configuring or building OpenRV manually:

```bash
bash
source ~/openrv_env.sh

cd ~
git clone --recursive \
  https://github.com/AcademySoftwareFoundation/OpenRV.git

cd OpenRV

# Apply the four validated source patches before configuration.
/path/to/openrv-macos-tart-build-cy2025/scripts/apply-openrv-patches.sh \
  --source "$HOME/OpenRV"

source rvcmds.sh

# Select CY2025 when prompted by rvcmds.sh, then use the validated rvcfg options.
rvcfg -DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="prores;hevc;aac;aac_at;aac_fixed;aac_latm;dnxhd"

rvbootstrap
```

The patch helper checks each patch before making changes. Missing patches are
applied, already-applied patches are left unchanged, and conflicting source
changes stop the script. To check without modifying the checkout, use:

```bash
/path/to/openrv-macos-tart-build-cy2025/scripts/apply-openrv-patches.sh \
  --check --source "$HOME/OpenRV"
```

`--dry-run` is an alias for `--check`. Check mode never modifies the source tree
and tells you to rerun without `--check` when patches are missing.

The command above shows the validated CY2025 decoder configuration used by
`build-openrv.sh`. For a different manual build, select another supported VFX
Platform or change the `rvcfg` options intentionally; those builds are outside
the exact validated configuration.

</details>

### Option B — Reproduce the validated OpenRV 4.0.1 / CY2025 build

```bash
./scripts/build-openrv.sh
```

This optional script:

- clones the exact `v4.0.1` tag;
- initializes submodules;
- applies the four validated patches idempotently;
- sets `RV_VFX_PLATFORM=CY2025` before sourcing `rvcmds.sh`;
- runs `rvcfg` with the validated decoder list;
- runs `rvbootstrap`; and
- verifies the staged arm64 executable and its runtime paths.

It does not run `rvbuild` after `rvbootstrap`, because `rvbootstrap` already invokes the build.

Useful partial execution modes of the same validated build script:

```bash
./scripts/build-openrv.sh --prepare-source
./scripts/build-openrv.sh --configure-only
./scripts/build-openrv.sh --source /path/to/OpenRV
```

- `--prepare-source` stops after cloning/verifying the OpenRV source, initializing submodules, and applying the validated patches.
- `--configure-only` continues through the validated `rvcfg` configuration and CMake cache checks, then stops before `rvbootstrap`.
- `--source DIR` uses an OpenRV checkout at `DIR` instead of the default `~/OpenRV`. It can be combined with the partial execution modes above.

These modes use the same preparation and configuration code paths as the full automated build. They are useful for inspecting the prepared source, validating patches, changing configuration, or continuing with a manual OpenRV build.

## Build configuration files

The repository keeps the main build inputs under `config/` so that common changes do not require editing the automation scripts themselves.

### `config/versions.env`

This is the central configuration file for the validated build. It defines the OpenRV version/tag and repository, VFX Platform year, expected macOS and architecture, Xcode and SDK versions, CMake version/download/checksum, Qt version, default OpenRV source directory, FFmpeg decoder list, and output package name.

For example, the validated `rvcfg` decoder list comes from:

```bash
FFMPEG_DECODERS="prores;hevc;aac;aac_at;aac_fixed;aac_latm;dnxhd"
```

`build-openrv.sh` passes that value to OpenRV as:

```bash
rvcfg -DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="${FFMPEG_DECODERS}"
```

This makes `config/versions.env` the first place to look when intentionally changing build inputs such as the VFX Platform year, Xcode/SDK location, CMake download, or decoder list. `CMAKE_SHA256` must be updated together with `CMAKE_URL`/`CMAKE_DMG` when intentionally changing the CMake installer. The provisioning script verifies the downloaded DMG before `hdiutil attach` or any `sudo` installation step.

Changes from the documented OpenRV 4.0.1 / CY2025 values create a different build configuration and should be validated separately.

For more extensive `rvcfg` customization, use `--prepare-source` or `--configure-only` as a stopping point and continue manually with the environment and OpenRV source tree prepared by the automation.

### `config/qt-modules.txt`

This file contains the Qt 6.5.3 modules installed by `aqtinstall`. The list is intentionally limited to the modules documented and validated for this build rather than installing every available Qt module.

If OpenRV requirements change, update this list instead of hard-coding additional Qt modules in the provisioning script. Changes to the module set should likewise be treated as a new build-environment configuration and tested before relying on the resulting package.

## Validated OpenRV source patches

The automated and manual CY2025 / OpenRV 4.0.1 workflows use four source patches from this repository. These patches preserve the fixes validated during the macOS Tahoe / Tart build work rather than requiring the same source edits to be repeated by hand.

### `0001-dependency-rpath-defaults.patch`

Adds the validated macOS RPATH defaults to OpenRV's dependency CMake configuration. This establishes the expected relocatable dependency behavior for the macOS build instead of leaving dependencies tied to build-machine locations.

### `0002-libpng-rpath.patch`

Adjusts libpng's macOS RPATH handling. This is part of the validated fix for the bare `libpng16.16.dylib` install-name/reference problem encountered in the staged application.

The packaging script still verifies and repairs staged libpng install names and consumers before `rvinst`; the source patch and packaging checks are intentionally complementary.

### `0003-aja-xcode-16.4-sdk.patch`

Ensures the AJA dependency is built using the SDK selected by the repository configuration. The patch file contains the `@OPENRV_MACOS_SDKROOT@` template token rather than a literal Xcode path. `apply-openrv-patches.sh` renders that token from `XCODE_APP` and `MACOS_SDK` in `config/versions.env` before checking or applying the patch.

For the validated configuration this resolves to Xcode 16.4's macOS 15.5 SDK. If those two settings are intentionally changed later, the AJA patch follows the same configured SDK path instead of silently retaining the old Xcode 16.4 path.

### `0004-disable-oiio-heif-jxl.patch`

Builds OpenImageIO with HEIF and JPEG XL support disabled. During validation, those optional features introduced unwanted Homebrew dependency chains into the installed application.

`package-openrv.sh` treats this as a hard requirement: it verifies that `USE_HEIF` and `USE_JXL` are both `OFF` and fails rather than packaging an application built with those dependencies enabled.

<details>
<summary><strong>Applying or checking the patches manually</strong></summary>

### Applying or checking the patches manually

Use the repository helper rather than applying the patch files individually:

```bash
./scripts/apply-openrv-patches.sh --source "$HOME/OpenRV"
```

By default, missing patches are applied. The helper is idempotent: it checks whether each patch needs to be applied, is already present, or cannot be applied cleanly.

To inspect patch status without modifying the OpenRV source tree:

```bash
./scripts/apply-openrv-patches.sh --check --source "$HOME/OpenRV"
```

`--dry-run` is an alias for `--check`:

```bash
./scripts/apply-openrv-patches.sh --dry-run --source "$HOME/OpenRV"
```

If the check reports `NEEDS APPLY`, rerun the command without `--check` or `--dry-run` to apply the missing patches.

The automated `build-openrv.sh` workflow performs the patch step automatically. The commands above are primarily useful when following the manual build workflow or when validating an existing OpenRV checkout.

</details>

## 3. Install, relocate, sign, and package

After a successful staged build:

```bash
./scripts/package-openrv.sh
```

Or point it at another checkout:

```bash
./scripts/package-openrv.sh --source /path/to/OpenRV
```

The packaging script performs the validated post-build sequence:

1. Repairs staged libpng install names and consumers.
2. Removes old install bundles and runs `rvinst`.
3. Renames `RV.app` to `OpenRV.app`.
4. Verifies OIIO was built without HEIF and JPEG XL support.
5. Bundles the validated Homebrew runtime libraries.
6. Builds and reuses cached Mach-O file indexes to avoid repeated full-bundle scans.
7. Rewrites Mach-O dependencies.
8. Normalizes bundled dylib install IDs that still point into the OpenRV build tree.
9. Fails if Homebrew or build-machine paths remain.
10. Applies an initial deep ad-hoc signature to the completed app bundle.
11. Re-signs each Mach-O file individually.
12. Re-applies the deep ad-hoc bundle signature after nested signatures change.
13. Verifies the final signature with `codesign --verify --deep --strict`.
14. Packages with `ditto` and tests the ZIP.
15. Creates a SHA-256 checksum and build manifest.

Final files are written under the OpenRV checkout's `_install` directory and copied to this repository's `output/` directory.

In the clean `macos-tahoe-base:latest` validation run, the optimized packaging stage completed in approximately 5 minutes 49 seconds on the Tart build VM.

<details>
<summary><strong>Using the packaging script with manual builds</strong></summary>

## Using the packaging script with manual builds

The packaging script can be used after a manual build of the same validated OpenRV v4.0.1 / CY2025 source/configuration. It is not intended as a generic packager for arbitrary OpenRV versions or VFX Platform years.

```bash
./scripts/provision-openrv-build-env.sh

bash
source ~/openrv_env.sh
cd ~/OpenRV
source rvcmds.sh

# Select CY2025 when prompted by rvcmds.sh, then use the validated rvcfg options.
rvcfg -DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="prores;hevc;aac;aac_at;aac_fixed;aac_latm;dnxhd"

rvbootstrap

/path/to/openrv-macos-tart-build-cy2025/scripts/package-openrv.sh \
  --source ~/OpenRV
```

The packaging script verifies that the checkout is the expected OpenRV repository/tag and that the configured build is CY2025 before creating the validated package name. It is intentionally strict and also stops if it detects unhandled Homebrew dependencies, HEIF/JPEG XL OIIO dependencies, build-machine paths, invalid signatures, or missing expected build products.

</details>

## Logs

Each top-level script writes a separate log under `logs/`:

```
logs/provision.log
logs/build-openrv.log
logs/package-openrv.log
```

The scripts use strict Bash error handling and report the failing stage, line, command, and return code.

## Clean validation Mac

The generated ZIP should still be tested on a separate Apple Silicon Mac without Homebrew. Extract it with `ditto`, verify the signature, and launch the executable from Terminal so loader errors are visible.

The generated `OpenRV.app` is **ad-hoc signed only**. The packaging step verifies that the bundle is internally consistent after its Mach-O changes; it does not Developer ID sign or notarize the application for general macOS distribution. Gatekeeper behavior on another Mac should therefore not be interpreted as equivalent to testing a notarized production application.

## Troubleshooting

The automation is designed to stop rather than continue past an unexpected build state. Each top-level script records the failing stage, line, command, and return code in its corresponding file under `logs/`.

Common failure points to check first:

- **`brew` or another base command is missing:** confirm that you started from the expected Tart/Cirrus Labs environment and that Homebrew/Tart prerequisites were prepared as described above.
- **Base VM disk is still 50 GB:** resize the working VM to 150 GB before provisioning; the Cirrus Labs Tahoe base image defaults to a 50 GB virtual disk.
- **`sudo -v` fails:** use an administrator account inside the guest. Provisioning intentionally stops before installing anything that requires elevated privileges.
- **`xip` is missing:** the guest is missing the macOS archive utility required to expand `Xcode_16.4.xip`; provisioning preflights this command before doing build-environment work.
- **CMake checksum failure:** do not bypass the check. Confirm that `CMAKE_URL`, `CMAKE_DMG`, and `CMAKE_SHA256` in `config/versions.env` describe the same intended CMake release and that the downloaded file is complete.
- **Guest macOS version/build warning:** `latest` may have advanced. Compare the detected guest with the tested-configuration table before deciding whether to continue validation on the newer image.
- **Xcode archive failure:** confirm `~/Downloads/Xcode_16.4.xip` exists and is the expected Apple Xcode 16.4 archive.
- **Insufficient disk space:** provisioning requires at least 40 GiB free before dependency installation and the OpenRV build.
- **Qt/`aqtinstall` download failure:** rerun after confirming network access; the provisioning script will reuse a valid existing Qt 6.5.3 installation.
- **Patch conflict:** run `apply-openrv-patches.sh --check --source <checkout>` and inspect whether the checkout differs from the expected OpenRV v4.0.1 source. The helper intentionally refuses ambiguous patch states.
- **CMake cache validation failure:** verify that the intended VFX Platform, Qt path, and `rvcfg` options were used. `build-openrv.sh --configure-only` is useful for stopping at this point.
- **Packaging reports Homebrew/build-tree paths:** treat this as a relocation failure rather than bypassing the check. Inspect `logs/package-openrv.log` for the exact Mach-O consumer.
- **`codesign` or clean-Mac launch failure:** remember that the package is ad-hoc signed, not notarized. First distinguish a loader/dependency problem from Gatekeeper policy by launching from Terminal and reviewing the reported error.


## Why no binaries

This project intentionally does not provide:

- OpenRV executables
- Qt binaries
- FFmpeg binaries
- Xcode
- other third-party dependencies

Xcode must be obtained directly from Apple and is not included or redistributed
by this repository.

The intent is to document a reproducible build process rather than redistribute
software owned by other projects.


## Limitations

- GUI validation must still be performed on macOS with graphics.
- The generated application is ad-hoc signed; it is not Developer ID signed or Apple-notarized.
- This is not an officially supported OpenRV build environment.
- Some dependencies may change over time as OpenRV evolves.
- The upstream Tart base image uses the moving `latest` tag, so its bundled macOS version may change over time.


## References

- https://tart.run/quick-start/

- https://github.com/AcademySoftwareFoundation/OpenRV

- https://aswf-openrv.readthedocs.io/en/latest/build_system/config_common_build.html

- https://developer.apple.com/download/all/?q=xcode%2016.4 (sign in with your Apple ID)


## License

The automation and documentation in this repository are provided under the MIT License. See `LICENSE`. OpenRV and the third-party software downloaded or built by these scripts retain their own upstream licenses; this repository's MIT license does not replace those licenses.

