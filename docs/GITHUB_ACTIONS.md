# Build an iPhone IPA in GitHub Actions

The **Build iPhone Duo IPA** workflow cross-compiles the dependencies and engine,
builds the ARM64 iPhoneOS app, and uploads an IPA and diagnostics. It uses the
Intel `macos-15-intel` runner to avoid ARM64 runner capacity constraints. Xcode and
the dependency script still cross-compile the app and its libraries for ARM64
iPhoneOS. Homebrew and Python paths are discovered from the build host rather
than assuming `/opt/homebrew`. No Apple credentials are required for an unsigned
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

The IPA contains the app only. It does not contain Windows, UEFI firmware, or
drivers. The original provisioning scripts require separately supplied Windows
11 ARM64 installation media and other inputs, launch an interactive macOS VM,
and create a large disk image. That process is not part of this IPA workflow.

Follow the README's provisioning instructions, then copy `windows11.hvsparse`,
`code.fd`, and `vars.fd` into the app's `Documents/Machines/Win11` directory.
Install the signed app, enable Developer Mode as required, and enable JIT using
the supported debugger setup. The repo documents `scripts/launch_on_duo.sh` for a
Mac connected to the device. GitHub-hosted runners cannot access your phone to
install, attach a debugger, or verify Windows boots.
