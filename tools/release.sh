#!/bin/zsh
# Builds a release DMG of Kidicom for GitHub Releases.
#
#   tools/release.sh                       DMG signed, notarized, and stapled
#   NOTARY_PROFILE= tools/release.sh       skip notarization
#
# For a DMG that opens on other Macs without a Gatekeeper warning you need:
#   1. A "Developer ID Application" certificate (Apple Developer Program,
#      Xcode > Settings > Accounts > Manage Certificates > +).
#   2. A notary profile in the keychain. This Mac has one named "notary",
#      shared by all apps of the same team. To make one:
#      xcrun notarytool store-credentials notary --apple-id <id> --team-id <team>
# Output: dist/Kidicom-<version>.dmg
set -euo pipefail
here=${0:A:h}
repo=${here:h}
cd "$repo"
NOTARY_PROFILE="${NOTARY_PROFILE-notary}"

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)}"
if [[ -z "$identity" ]]; then
  echo "No Developer ID Application certificate: the DMG will be signed for this Mac only."
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
  [[ -n "$identity" ]] || identity=-
fi

SIGN_IDENTITY="$identity" ./build.sh
app="$HOME/Applications/Kidicom.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

# Hardened runtime and a secure timestamp, required for notarization.
if [[ "$identity" == Developer\ ID* ]]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict --verbose=2 "$app"

mkdir -p dist
dmg="dist/Kidicom-$version.dmg"
rm -f "$dmg"
"$here/dmg/make_dmg.sh" "$app" "$dmg" "Kidicom"
# Only a Developer ID signature helps a DMG. Signed with Apple Development,
# Gatekeeper rejects the disk itself on other Macs and it won't even open;
# unsigned, the disk opens and only the app asks for Open Anyway.
if [[ "$identity" == Developer\ ID* ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
fi

if [[ -n "${NOTARY_PROFILE:-}" && "$identity" != Developer\ ID* ]]; then
  echo "NOTARY_PROFILE is set but there is no Developer ID Application certificate: cannot notarize." >&2
  exit 1
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
shasum -a 256 "$dmg"
echo "wrote $dmg"
