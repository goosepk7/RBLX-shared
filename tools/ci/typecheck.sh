#!/usr/bin/env bash
# Strict Luau type check of everything in the repo with luau-lsp.
# src/ is checked against Roblox API types; tests/, sims/ and tools/ also see the lune
# typedefs (installed by `lune setup`, aliased as @lune in the generated .luaurc).
set -euo pipefail

defs=".ci/globalTypes.d.luau"
if [[ ! -f "$defs" ]]; then
	mkdir -p .ci
	curl -sSfL -o "$defs" https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.70.0/scripts/globalTypes.d.luau
fi

if [[ ! -f sourcemap.json ]]; then
	rojo sourcemap dev.project.json --output sourcemap.json
fi

# Merge the repo's .luaurc with the @lune alias that `lune setup` points at.
lune_typedefs="$(ls -d "$HOME"/.lune/.typedefs/*/ 2>/dev/null | sort -V | tail -n1 || true)"
if [[ -z "$lune_typedefs" ]]; then
	echo "lune typedefs not found; run 'lune setup' first" >&2
	exit 1
fi
python3 - "$lune_typedefs" > .ci/luaurc.json <<'PY'
import json, sys
config = json.load(open(".luaurc"))
config.setdefault("aliases", {})["lune"] = sys.argv[1]
print(json.dumps(config))
PY

# luau-lsp repeats diagnostics for modules reached through several requires; dedupe them.
set +e
luau-lsp analyze \
	--platform=roblox \
	--definitions=@roblox="$defs" \
	--sourcemap=sourcemap.json \
	--base-luaurc=.ci/luaurc.json \
	--no-strict-dm-types \
	src tests sims tools 2>&1 | awk '!seen[$0]++'
status=${PIPESTATUS[0]}
exit "$status"
