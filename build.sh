#!/bin/zsh
# Builds Kidicom and installs it to ~/Applications/Kidicom.app, the only
# copy: it quits the running app, deletes other copies (like one in
# /Applications from the DMG), installs, and opens the new build again if
# the app was running.
# Build products live in ~/Library/Developer/Kidicom, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then open the new build even if the app was not running
set -euo pipefail
here=${0:A:h}
name="Kidicom"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error|warning|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error" | head -20
  exit 1
fi

# Strings: English and Portuguese from the String Catalog, compiled before the
# old app is removed, so a bad catalog never leaves a broken install.
strings="$scratch/strings"
rm -rf "$strings"; mkdir -p "$strings"
catalog="$here/Resources/Localization/Localizable.xcstrings"
if [[ -f "$catalog" ]]; then
  xcrun xcstringstool compile "$catalog" --output-directory "$strings" >/dev/null || { echo "build failed: $catalog does not compile"; exit 1; }
  # Portuguese for every region (pt, pt-PT), not only Brazil.
  [[ -d "$strings/pt-BR.lproj" ]] && cp -R "$strings/pt-BR.lproj" "$strings/pt.lproj"
fi

app="$HOME/Applications/$name.app"
bundle_id="com.salomao.kidicom"
was_running=0
if pgrep -xq "$name"; then
  was_running=1
  osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
  for _ in {1..20}; do pgrep -xq "$name" || break; sleep 0.25; done
  pkill -x "$name" 2>/dev/null || true
fi
# One copy only: remove installs elsewhere so the Dock and Spotlight can't open an old build.
for other in "/Applications/$name.app"; do
  [[ -d "$other" ]] && rm -rf "$other" && echo "removed old copy $other"
done
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
cp -R "$strings"/*.lproj "$app/Contents/Resources/" 2>/dev/null || true
xattr -cr "$app"
codesign --force --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (signed: ${identity})"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true
if (( was_running )) || [[ " $* " == *" --open "* ]]; then
  open "$app"
  echo "opened the new build"
fi
