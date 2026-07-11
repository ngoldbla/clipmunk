#!/usr/bin/env bash
# Build the sandboxed AppStore configuration, archive it, and upload to
# App Store Connect (TestFlight) in one shot.
#
# Requirements:
#   - An App Store Connect API key (.p8) in ~/.appstoreconnect/private_keys/
#     with App Manager (or Admin) access — used for automatic signing AND upload.
#   - env ASC_KEY_ID     (e.g. 44V6J6H27J — matches AuthKey_<ID>.p8)
#   - env ASC_ISSUER_ID  (UUID from App Store Connect → Users and Access → Integrations)
#   - The app record must already exist in App Store Connect (bundle id
#     com.github.ngoldbla.Clipmunk); uploads cannot create it.
#
# Usage:  ASC_KEY_ID=… ASC_ISSUER_ID=… bash scripts/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:?set ASC_KEY_ID to the App Store Connect API key id}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the App Store Connect issuer id}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$KEY_PATH" ] || { echo "error: API key not found at $KEY_PATH" >&2; exit 1; }

AUTH_ARGS=(-authenticationKeyPath "$KEY_PATH"
           -authenticationKeyID "$ASC_KEY_ID"
           -authenticationKeyIssuerID "$ASC_ISSUER_ID")

command -v xcodegen >/dev/null || { echo "error: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
xcodegen generate

ARCHIVE="build/Clipmunk-AppStore.xcarchive"

# Archive the sandboxed AppStore config. -allowProvisioningUpdates lets Xcode
# register the bundle id / create profiles through the API key as needed.
# -scmProvider system: Xcode's builtin SCM hangs forever in
# waitForRemoteSourcePackagesToFinishLoading on this project; system git works.
xcodebuild -project Clipmunk.xcodeproj -scheme Clipmunk -configuration AppStore \
  -destination 'platform=macOS' -scmProvider system \
  -derivedDataPath build -skipMacroValidation -skipPackagePluginValidation \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH_ARGS[@]}" \
  HF_DOWNLOAD_TOKEN="${HF_DOWNLOAD_TOKEN:-}" \
  ARCHS=arm64 \
  archive

# The same structural guard the DMG release uses: MLX is dead without its
# precompiled Metal kernels, and that failure is invisible until first inference.
find "$ARCHIVE/Products/Applications/Clipmunk.app" -name '*.metallib' | grep -q . \
  || { echo "error: no .metallib in app bundle — Metal Toolchain missing at build time?" >&2; exit 1; }

# Sandbox guard: TestFlight rejects un-sandboxed Mac builds at upload time;
# fail here with a clear message instead.
codesign -d --entitlements :- "$ARCHIVE/Products/Applications/Clipmunk.app" 2>/dev/null \
  | grep -q 'com.apple.security.app-sandbox' \
  || { echo "error: app-sandbox entitlement missing from the signed app" >&2; exit 1; }

# Re-sign with Apple Distribution + Mac App Store provisioning and upload.
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions-AppStore.plist \
  -exportPath build/appstore-export \
  -allowProvisioningUpdates "${AUTH_ARGS[@]}"

echo "==> Uploaded. Watch processing in App Store Connect → TestFlight."
