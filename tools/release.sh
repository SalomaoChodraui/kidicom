#!/bin/zsh
# Builds a release DMG of Kidicom for GitHub Releases.
#
#   tools/release.sh                       DMG signed with what the keychain has
#   NOTARY_PROFILE=kidicom tools/release.sh   also notarize and staple
#
# For a DMG that opens on other Macs without a Gatekeeper warning you need:
#   1. A "Developer ID Application" certificate (Apple Developer Program,
#      Xcode > Settings > Accounts > Manage Certificates > +).
#   2. A notary profile, made once:
#      xcrun notarytool store-credentials kidicom --apple-id <id> --team-id <team>
# Output: dist/Kidicom-<version>.dmg
set -euo pipefail
here=${0:A:h}
repo=${here:h}
cd "$repo"

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
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="dist/Kidicom-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "Kidicom $version" -srcfolder "$stage" -format UDZO -ov "$dmg" >/dev/null
if [[ "$identity" == Developer\ ID* ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
elif [[ "$identity" != "-" ]]; then
  codesign --force --sign "$identity" "$dmg"
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
