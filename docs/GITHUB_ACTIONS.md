# Build an iPhone IPA in GitHub Actions

The **Build iPhone Duo IPA** workflow cross-compiles the dependencies and engine,
builds the ARM64 iPhoneOS app, and uploads an IPA and diagnostics. It uses the
Apple Silicon `xcode-27` runner after a Linux job builds and boots the pinned M4 firmware. No Apple credentials are required for an unsigned
build. The existing Laptop/Studio layout is included; CI cannot verify the
README's device, performance, or OS compatibility claims.

## Run

1. Add these changes to your WindowsiOS fork's default branch and enable Actions.
2. Open **Actions → Build iPhone Duo IPA → Run workflow**.
3. Leave **sign_ipa** disabled for an unsigned IPA.
4. Download **WindowsiOS-iPhone-Duo-<run number>** from the completed run's artifacts.

Builds also run on pushes affecting the app or build scripts. Unsigned builds
need signing before installation. The workflow disables the original author's
hardcoded signing settings at build time.

## Optional development signing

Create an Apple Development certificate with its private key and a development
provisioning profile matching your bundle ID. Register the target device in that
profile. Set these **repository Actions secrets** (never commit them):

| Secret | Contents |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | Base64-encoded exported development certificate/private key `.p12` |
| `IOS_CERTIFICATE_PASSWORD` | Password used to export the `.p12` (empty if none) |
| `IOS_PROFILE_BASE64` | Base64-encoded development `.mobileprovision` |

Run the workflow manually, choose your matching **bundle_id**, and enable
**sign_ipa**. Signing uses a temporary keychain deleted after signing. The profile
must allow `get-task-allow`, because the documented JIT launch attaches a debugger.
The signed IPA can only be installed on the profile's registered devices; signing
does not itself enable JIT. No App Store or TestFlight export is performed.

## Hinge SDK compatibility

`UIHingeInteraction` is referenced in the original code. An iOS runtime availability
check does not make it compile on SDKs missing that type. The build script probes
the actual SDK API, then sets `WINIOS_HAS_HINGE_API` only when that probe succeeds.
Otherwise automatic hinge callbacks are excluded; existing geometry fallback and
manual Laptop/Studio posture controls remain available. `BUILD-INFO.txt` records
which path was built. For local Xcode builds using a compatible SDK, add
`WINIOS_HAS_HINGE_API` to Swift Active Compilation Conditions or use the CI script.

## What still requires your device and Windows media

The IPA includes the app and the 1600 × 1200 ArmVirt firmware for the 13-inch M4 iPad Pro with 16 GB. Windows, writable EFI variables, stock firmware for other devices, and guest drivers come from provisioning. The original provisioning scripts require separately supplied Windows
11 ARM64 installation media and other inputs, launch an interactive macOS VM,
and create a large disk image. That process is not part of this IPA workflow.

Follow the README's provisioning instructions, then copy `windows11.hvsparse`,
`code.fd`, and `vars.fd` into the app's `Documents/Machines/Win11` directory.
Install the signed app, enable Developer Mode as required, and enable JIT using
the supported debugger setup. The repo documents `scripts/launch_on_duo.sh` for a
Mac connected to the device. GitHub-hosted runners cannot access your phone to
install, attach a debugger, or verify Windows boots.

## M4 firmware and performance verification

For a local Xcode build, first run `bash scripts/ci_build_m4_firmware.sh` on Linux with the tools from the firmware workflow job, or download its `m4-armvirt` artifact. Place the resulting files under `build/firmware/` before generating the Xcode project. At boot, `boot_status.txt` records the selected profile, firmware, actual framebuffer dimensions, RAM in MiB, and why the allocator selected that size. With the bundled firmware the existing Windows disk and writable `vars.fd` stay in the machine directory. Setting the launch environment variable `HV_M4_STOCK_FIRMWARE=1` selects the provisioned `code.fd` for comparison.

On the 16 GB 13-inch M4, check the firmware name and `fb_size: 1600x1200` after Windows boots. Check Windows Display settings, four logical processors, and installed memory against the boot snapshot. With more than 6 GiB assigned, run a 64-bit Windows memory test that writes and verifies a working set larger than 4 GiB. Repeat after a warm restart. Rotate the iPad and resize the window, then tap near all four guest corners to check input alignment.

To collect a workload trace, put one phase name in `Documents/vm-trace-phase.txt`: `desktop`, `edge-idle`, or `speedometer`. The app appends process CPU time, per-thread CPU time, per-vCPU waits, timer deadlines, periodic kicks and thermal state to `Documents/vm-perf.jsonl` at its normal diagnostics interval. Delete the marker to stop. Process core equivalents are the change in process CPU seconds divided by elapsed wall seconds between samples from the same boot and phase.

For an A/B run, use the same Windows disk, Edge ARM64 version, window size, guest resolution, power mode, charging state and starting thermal state. Measure desktop and Edge idle CPU for five minutes each. Run Speedometer 3.1 three times on each build and compare medians. On the Duo, `HV_LEGACY_KICKER=1` selects periodic exits on every vCPU. Compare kicks, CPU use and time to serious thermal state at the same guest load. On the M4, measure the 1600 × 1200 default separately from the stock-resolution A/B.
