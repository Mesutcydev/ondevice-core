#!/usr/bin/env bash
# Produce a signed local export for App Store Connect. Upload is a separate step.
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  echo "Usage: $0 [--preflight] [--enable-pcc] [--lfm3] TEAM_ID"
  echo "Select shipping Xcode with DEVELOPER_DIR; set ONDEVICE_DERIVED_DATA to reuse a cache."
  echo "Set ONDEVICE_SOURCE_PACKAGES to reuse the reviewed package checkout cache."
  echo "Optional API signing: ONDEVICE_ASC_KEY_PATH, ONDEVICE_ASC_KEY_ID, ONDEVICE_ASC_ISSUER_ID."
  echo "--lfm3 selects the separately bootstrapped experimental LFM3 runtime."
}
PREFLIGHT=NO
PCC=NO
LFM3=NO
TEAM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight) PREFLIGHT=YES ;;
    --enable-pcc) PCC=YES ;;
    --lfm3) LFM3=YES ;;
    --help|-h) usage; exit 0 ;;
    --*) usage; exit 2 ;;
    *) [[ -z "$TEAM" ]] || { usage; exit 2; }; TEAM="$1" ;;
  esac
  shift
done

python3 scripts/verify_appstore.py --source
if [[ "$LFM3" == YES ]]; then
  python3 scripts/bootstrap_lfm3_runtime.py --check
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# Verified against Apple's release page on 2026-10-09. Override only with a
# shipping/accepted RC build verified at developer.apple.com/news/releases/.
APPROVED_BUILD="${ONDEVICE_APPSTORE_XCODE_BUILD:-27A266a}"
SELECTED_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
FAILURES=0
block() { echo "BLOCKED: $*" >&2; FAILURES=$((FAILURES + 1)); }
SIGNING_ARGS=(-allowProvisioningUpdates)
if [[ -n "${ONDEVICE_ASC_KEY_PATH:-}${ONDEVICE_ASC_KEY_ID:-}${ONDEVICE_ASC_ISSUER_ID:-}" ]]; then
  if [[ -f "${ONDEVICE_ASC_KEY_PATH:-}" && -r "${ONDEVICE_ASC_KEY_PATH:-}" && \
        "${ONDEVICE_ASC_KEY_ID:-}" =~ ^[A-Z0-9]{10}$ && \
        "${ONDEVICE_ASC_ISSUER_ID:-}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    SIGNING_ARGS+=(-authenticationKeyPath "$ONDEVICE_ASC_KEY_PATH" \
      -authenticationKeyID "$ONDEVICE_ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ONDEVICE_ASC_ISSUER_ID")
  else
    block "API signing requires a readable key file, key ID and issuer ID together."
  fi
fi
[[ "$SELECTED_BUILD" == "$APPROVED_BUILD" ]] || block "Xcode $SELECTED_BUILD is not the verified distribution toolchain $APPROVED_BUILD. Select shipping Xcode 27."
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  # Shared platform setup (for example CoreSimulator) can remain pending even
  # when the shipping device SDK builds successfully. Archiving/exporting iOS
  # below must succeed independently; this script never accepts license terms.
  echo "NOTICE: Xcode shared platform setup is pending. Attempting the shipping iOS archive/export through xcodebuild."
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
[[ -f "$SDK/System/Library/Frameworks/CoreAI.framework/CoreAI.tbd" ]] || block "Selected iPhoneOS SDK has no CoreAI runtime."
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || block "Provide the restored Apple Developer Team ID."
if [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning)"
  if ! printf '%s\n' "$IDENTITIES" | grep -E '(Apple Distribution:|iPhone Distribution:)' | grep -F "($TEAM)" | grep -Ev 'REVOKED|EXPIRED|CSSMERR' >/dev/null; then
    # Automatic export can use Apple's cloud-managed distribution certificate.
    # It must still produce an owner-team, distribution-signed IPA that passes
    # the profile/entitlement verifier below. No local identity is a prerequisite
    # only for manual signing; this script explicitly uses automatic signing.
    echo "NOTICE: No local distribution identity for team $TEAM. Xcode automatic export will resolve distribution signing; authenticated team access is required."
  fi
fi
FREE_KB="$(df -k "$ROOT" | awk 'END {print $4}')"
DERIVED="${ONDEVICE_DERIVED_DATA:-$ROOT/build/appstore/DerivedData}"
SOURCE_PACKAGES="${ONDEVICE_SOURCE_PACKAGES:-$DERIVED/SourcePackages}"
MIN_FREE_KB=15728640
WARM_APP="$DERIVED/Build/Products/Release-iphoneos/TokenAI.app"
if [[ -f "$WARM_APP/Info.plist" ]]; then
  WARM_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :DTXcodeBuild' "$WARM_APP/Info.plist" 2>/dev/null || true)"
  WARM_SDK="$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$WARM_APP/Info.plist" 2>/dev/null || true)"
  if [[ "$WARM_BUILD" == "$SELECTED_BUILD" && "$WARM_SDK" == iphoneos* ]]; then
    # Preserve the verified shipping compiler cache. Budget two copies of the
    # existing build tree, three app copies (archive/export/verification), and
    # 1 GiB overhead, with a 6 GiB minimum; fresh builds still require 15 GiB.
    BUILD_KB="$(du -sk "$DERIVED/Build" | awk '{print $1}')"
    APP_KB="$(du -sk "$WARM_APP" | awk '{print $1}')"
    MIN_FREE_KB=$((2 * BUILD_KB + 3 * APP_KB + 1048576))
    [[ "$MIN_FREE_KB" -ge 6291456 ]] || MIN_FREE_KB=6291456
    echo "Reusing shipping SDK build cache; archive working-space budget: $MIN_FREE_KB KiB."
  fi
fi
[[ "$FREE_KB" -ge "$MIN_FREE_KB" ]] || block "Insufficient working space for archive/export: need $MIN_FREE_KB KiB; available $FREE_KB KiB."
if [[ "$FAILURES" -gt 0 ]]; then
  echo "$FAILURES local prerequisites remain. No archive/export was attempted." >&2
  exit 1
fi
if [[ "$PREFLIGHT" == YES ]]; then
  echo "Local preflight passed. Account agreements, App IDs, capability grants and profiles still require portal verification."
  exit 0
fi

VERSION="$(awk -F'"' '/CFBundleShortVersionString:/ {print $2; exit}' project.yml)"
BUILD="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
OUT="$ROOT/build/appstore/$VERSION-$BUILD"
ARCHIVE="$OUT/TokenAI.xcarchive"
ENTITLEMENTS="IOSLocalLLM/IOSLocalLLM-AppStore.entitlements"
[[ "$PCC" == NO ]] || ENTITLEMENTS="IOSLocalLLM/IOSLocalLLM-AppStore-PCC.entitlements"
[[ ! -e "$OUT" ]] || { echo "error: $OUT exists; preserve the previous artifact and choose a new build number." >&2; exit 1; }
mkdir -p "$OUT"
xcodegen generate > "$OUT/generate.log" 2>&1
pod install > "$OUT/pods.log" 2>&1
./scripts/validate_open_source.sh > "$OUT/repository-validation.log" 2>&1
./scripts/verify_zoo_catalog.sh --appstore > "$OUT/catalog.log" 2>&1
python3 scripts/verify_zoo_downloads.py > "$OUT/model-downloads.log" 2>&1

archive_with_runtime() {
xcodebuild archive -workspace TokenAI.xcworkspace -scheme TokenAI \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
  "${SIGNING_ARGS[@]}" DEVELOPMENT_TEAM="$TEAM" \
  ONDEVICE_APPSTORE=YES ONDEVICE_DISTRIBUTION_ENTITLEMENTS="$ENTITLEMENTS" \
  ONDEVICE_MODEL_POLICY=APP_STORE ONDEVICE_RESEARCH_BUILD=NO \
  ONDEVICE_PACKAGE_CHECKOUTS="$SOURCE_PACKAGES/checkouts" \
  "$@" \
  > "$OUT/archive.log" 2>&1 \
  || { tail -60 "$OUT/archive.log"; exit 1; }
}
if [[ "$LFM3" == YES ]]; then
  archive_with_runtime -jobs 4 SWIFT_COMPILATION_MODE=singlefile \
    ONDEVICE_LFM3_SWIFT_FLAG=LFM3_EXPERIMENTAL \
    "ONDEVICE_LLAMA_FRAMEWORK_DIR=$ROOT/build/LFM3Native" \
    "ONDEVICE_LLAMA_SOURCE=$ROOT/build/LFM3Native/cache/llama.cpp-19cce6919992fdffd92e0ac152caaf1e2b8f254e"
else
  archive_with_runtime
fi
APP="$ARCHIVE/Products/Applications/TokenAI.app"
python3 scripts/verify_appstore.py --app "$APP" \
  --expected-version "$VERSION" --expected-build "$BUILD" --expected-xcode-build "$SELECTED_BUILD"
./scripts/verify_foundationmodels_symbols.sh "$APP" FoundationModels "$SDK"

python3 - "$OUT/ExportOptions.plist" "$TEAM" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({"method": "app-store-connect", "destination": "export",
                  "teamID": sys.argv[2], "signingStyle": "automatic",
                  "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
                  "uploadSymbols": True}, output)
PY
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
  "${SIGNING_ARGS[@]}" > "$OUT/export.log" 2>&1 \
  || { tail -60 "$OUT/export.log"; exit 1; }
IPA="$OUT/export/TokenAI.ipa"
[[ -f "$IPA" ]] || { echo "error: App Store export produced no IPA" >&2; exit 1; }
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/ondevice-appstore.XXXXXX")"
trap 'rm -rf "$VERIFY"' EXIT
unzip -tq "$IPA" >/dev/null
unzip -q "$IPA" -d "$VERIFY"
python3 scripts/verify_appstore.py --app "$VERIFY/Payload/TokenAI.app" --team-id "$TEAM" --distribution \
  --expected-version "$VERSION" --expected-build "$BUILD" --expected-xcode-build "$SELECTED_BUILD"
shasum -a 256 "$IPA" > "$OUT/sha256.txt"
echo "Signed local App Store export: $IPA"
echo "Review $OUT and run physical-device acceptance before uploading."
