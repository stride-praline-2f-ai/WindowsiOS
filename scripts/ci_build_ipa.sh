#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-me.ammaar.windowsios}"
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    echo 'Invalid BUNDLE_ID' >&2
    exit 1
fi

mkdir -p build/logs build/artifacts
make -j"$(sysctl -n hw.ncpu)" ios-lib 2>&1 | tee build/logs/ios-lib.log
xcodegen generate --spec ios/project.yml

# Runtime availability checks cannot hide a type absent from the build SDK.
# Probe the actual API shape so compatible SDKs retain automatic hinge updates.
python3 - <<'PY'
from pathlib import Path
source = Path('ios/Sources/HingeSensorView.swift').read_text()
body = source.split('        #if WINIOS_HAS_HINGE_API\n', 1)[1].split('        #endif', 1)[0]
Path('build/hinge-probe.swift').write_text(
    'import UIKit\n@MainActor final class HingeProbe: UIViewController {\n'
    'var onHingeUpdate: ((Int, Double?) -> Void)?\nfunc probe() {\n'
    + body.replace('WinIOSBridge.shared.updateHingeStatus(0, angleDegrees: -1.0)', '')
          .replace('WinIOSBridge.shared.updateHingeStatus(rawStatus, angleDegrees: deg)', '')
    + '\n}\n}\n')
PY

SWIFT_CONDITIONS='$(inherited)'
if xcrun --sdk iphoneos swiftc -typecheck \
    -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -target arm64-apple-ios17.0 build/hinge-probe.swift \
    > build/logs/hinge-probe.log 2>&1; then
    SWIFT_CONDITIONS="$SWIFT_CONDITIONS WINIOS_HAS_HINGE_API"
    HINGE_MODE='Automatic hinge API compiled; runtime availability still applies.'
else
    HINGE_MODE='SDK lacks the hinge API; use the existing Laptop / Studio posture controls.'
fi
echo "$HINGE_MODE"

xcodebuild \
    -project ios/WindowsiOS.xcodeproj \
    -scheme WindowsiOS -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedData \
    "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$SWIFT_CONDITIONS" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    build 2>&1 | tee build/logs/xcodebuild.log

APP=build/DerivedData/Build/Products/Release-iphoneos/WindowsiOS.app
test -f "$APP/WindowsiOS"
xcrun lipo -verify_arch arm64 "$APP/WindowsiOS"
mkdir -p build/ipa/Payload
ditto "$APP" build/ipa/Payload/WindowsiOS.app
(cd build/ipa && zip -qry ../artifacts/WindowsiOS-iPhone-Duo-unsigned.ipa Payload)

cat > build/artifacts/BUILD-INFO.txt <<EOF
Source: $(git rev-parse HEAD)
Bundle ID: $BUNDLE_ID
Architecture: ARM64 iPhoneOS (not Simulator)
Signing: unsigned, unless accompanied by a development.ipa
$HINGE_MODE
The Duo layout is included. Physical device compatibility has not been verified by CI.
Windows, firmware and drivers are not included.
Install with valid signing, then supply VM files and enable JIT on the device.
EOF
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat build/artifacts/BUILD-INFO.txt >> "$GITHUB_STEP_SUMMARY"
fi
