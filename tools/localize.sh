#!/bin/zsh
# Refreshes Resources/Localization/Localizable.xcstrings from the code and
# merges the Portuguese in tools/translations_pt.py. Prints keys with no
# translation. Run after adding or changing user-facing strings.
set -euo pipefail
here=${0:A:h}
repo=${here:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if ! swift build --package-path "$repo" --scratch-path "$HOME/Library/Developer/Kidicom/l10n-build" --product Kidicom \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$work" > "$work/build.log" 2>&1; then
  grep -E "error" "$work/build.log" | head -20
  echo "localize: the build failed, catalog left unchanged" >&2
  exit 1
fi
setopt nullglob
data=("$work"/*.stringsdata)
(( ${#data} > 0 )) || { echo "localize: no strings were extracted" >&2; exit 1; }
catalog="$repo/Resources/Localization/Localizable.xcstrings"
xcrun xcstringstool sync "$catalog" --stringsdata "${data[@]}"
python3 -I - "$catalog" "$here/translations_pt.py" <<'PY'
import json, sys, runpy
catalog, table = sys.argv[1], sys.argv[2]
pt = runpy.run_path(table)["PT"]
d = json.load(open(catalog))
# Keys the code no longer uses are marked stale by sync: drop them.
stale = [k for k, e in d["strings"].items() if e.get("extractionState") == "stale"]
for key in stale:
    del d["strings"][key]
missing = []
for key, entry in d["strings"].items():
    if key in pt:
        entry.setdefault("localizations", {})["pt-BR"] = {"stringUnit": {"state": "translated", "value": pt[key]}}
    elif key.strip():
        missing.append(key)
json.dump(d, open(catalog, "w"), ensure_ascii=False, indent=2, sort_keys=True)
unused = sorted(set(pt) - set(d["strings"]))
print(f"{len(d['strings'])} strings; removed {len(stale)} stale; missing: {missing}; unused translations: {unused}")
PY
