#!/usr/bin/env bash
# Verify an IPA's identity and print the data-preservation checklist.
#
# Usage:
#   ./scripts/verify_ipa_identity.sh <ipa> [expected-bundle-id]
#
# Exits non-zero on a bundle-id mismatch, which is the one identity change
# that always makes iOS treat an install as a different app (fresh empty
# container, previous data orphaned).

set -euo pipefail

IPA="${1:?usage: $0 <ipa> [expected-bundle-id]}"
EXPECTED="${2:-com.mesutcydev.ondevicecore}"

[[ -f "$IPA" ]] || { echo "error: IPA not found: $IPA" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-ipa.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

unzip -q "$IPA" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "error: no .app found inside Payload/" >&2; exit 2; }

BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"

echo "bundle id: $BUNDLE"
echo "version:   $VERSION ($BUILD)"

if [[ "$BUNDLE" != "$EXPECTED" ]]; then
  echo "FAIL: bundle id mismatch (expected $EXPECTED)" >&2
  exit 1
fi

if find "$WORK" -name embedded.mobileprovision -print -quit | grep -q .; then
  echo "signing:   profile-preserving (install/update in place with Xcode or devicectl)"
else
  echo "signing:   profile-less ad-hoc (your installer must re-sign it)"
fi

echo "entitlements:"
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - | sed 's/^/  /'

cat <<'EOF'

DATA-PRESERVATION CHECKLIST (an update must NOT uninstall):
  1. Keep the same bundle id (checked above) AND the same Apple ID/team for
     re-signing, so TeamIdentifier.BundleIdentifier (application-identifier)
     stays constant.
  2. Update the existing app in place. Preferred paths:
       - Xcode: Product > Run against the connected device
       - xcrun devicectl device install app --device <UDID> <signed .app>
     Never run `devicectl device uninstall` or delete the app first.
  3. If your sideloader deletes the app before installing, iOS removes the
     whole data container by design — downloaded multi-GB models included.
     Use that tool's update path (install over), or switch the signing
     identity to match the installed app so an in-place update is accepted.
  4. Verify preservation after installing:
       app > Diagnostics > Deployment Persistence > Check sentinel.

Recovery if data was already lost: keep one copy of a model folder in the
Files app / iCloud Drive and re-import it (Models > Import) instead of
re-downloading.
EOF

echo "OK: identity matches $EXPECTED"
