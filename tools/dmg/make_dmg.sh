#!/bin/zsh
# Makes a drag-to-install DMG with a drawn background, the app on the left,
# a link to Applications (named Aplicativos) on the right, and the K as the volume icon.
# Usage: tools/dmg/make_dmg.sh <app> <out.dmg> <volume name>
set -euo pipefail
here=${0:A:h}
app=$1; out=$2; volume=$3
work=$(mktemp -d)
mounted=""
cleanup() {
  [[ -n "$mounted" ]] && hdiutil detach "$mounted" -quiet -force 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# Background at 1x and 2x in one TIFF, so it is sharp on Retina screens.
swift "$here/background.swift" "$work/bg.png" 1
swift "$here/background.swift" "$work/bg@2x.png" 2
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$work/background.tiff" 2>/dev/null

stage="$work/stage"
mkdir -p "$stage/.background"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Aplicativos"
cp "$work/background.tiff" "$stage/.background/background.tiff"
icns="$app/Contents/Resources/AppIcon.icns"

# A writable image first, so the Finder can save the window layout.
hdiutil create -quiet -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$work/rw.dmg"
# The Finder finds the disk by name, so no other disk may carry it; then read
# the exact mount point from hdiutil instead of guessing it.
[[ -d "/Volumes/$volume" ]] && hdiutil detach "/Volumes/$volume" -quiet -force || true
mounted=$(hdiutil attach -readwrite -noverify -noautoopen -plist "$work/rw.dmg" \
  | plutil -extract system-entities xml1 -o - - \
  | grep -A1 "<key>mount-point</key>" | grep -o "<string>.*</string>" | sed -e 's/<[^>]*>//g')
[[ -d "$mounted" && "$mounted" == "/Volumes/$volume" ]] || { echo "make_dmg: mounted at '$mounted', expected /Volumes/$volume" >&2; exit 1; }
appName=${app:t}

osascript <<OSA
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 840, 562}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$appName" of container window to {170, 186}
    set position of item "Aplicativos" of container window to {470, 186}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

# The K as the disk icon. It goes in after the Finder step: on macOS 26 the
# Finder deletes .VolumeIcon.icns when it opens the disk to save the layout.
if [[ -f "$icns" ]]; then
  cp "$icns" "$mounted/.VolumeIcon.icns"
  SetFile -a C "$mounted" || true
fi
chmod -Rf go-w "$mounted" 2>/dev/null || true
sync
hdiutil detach "$mounted" -quiet
mounted=""
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out"
