#!/bin/zsh
# Refreshes Resources/Localization/Localizable.xcstrings from the code and
# merges the Portuguese in tools/translations_pt.py. Prints keys with no
# translation. Run after adding or changing user-facing strings.
set -euo pipefail
here=${0:A:h}
repo=${here:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swift build --package-path "$repo" --scratch-path "$HOME/Library/Developer/Kidicom/l10n-build" --product Kidicom \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$work" 2>&1 | grep -E "error" || true
catalog="$repo/Resources/Localization/Localizable.xcstrings"
xcrun xcstringstool sync "$catalog" --stringsdata "$work"/*.stringsdata
python3 -I - "$catalog" "$here/translations_pt.py" <<'PY'
import json, sys, runpy
catalog, table = sys.argv[1], sys.argv[2]
pt = runpy.run_path(table)["PT"]
d = json.load(open(catalog))
for key, value in pt.items():
    d["strings"].setdefault(key, {})
missing = []
for key, entry in d["strings"].items():
    if key in pt:
        entry.setdefault("localizations", {})["pt-BR"] = {"stringUnit": {"state": "translated", "value": pt[key]}}
    elif key.strip():
        missing.append(key)
json.dump(d, open(catalog, "w"), ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(pt)} translated; missing: {missing}")
PY
