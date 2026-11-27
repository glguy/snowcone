#!/bin/sh

# Usage: scripts/luals-check.sh
#
# Runs the Lua Language Server's checks over the repository with its
# .luarc.json, prints what it finds, and exits nonzero when it finds
# anything. It checks the whole repository: the server takes the
# directory it checks as the workspace, so a part of it alone would lose
# hub/types.lua and the modules it requires. See "Type checks" in
# docs/hub-design.md.
#
# The server is $LUALS if set, else lua-language-server on PATH, else
# the newest one in a VS Code Lua extension (sumneko.lua).

set -e

if [ "$#" -ne 0 ]; then
  echo "Usage: $0" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)

server=${LUALS:-}
if [ -z "$server" ]; then
  server=$(command -v lua-language-server || true)
fi
if [ -z "$server" ]; then
  for candidate in "$HOME"/.vscode/extensions/sumneko.lua-*/server/bin/lua-language-server; do
    [ -x "$candidate" ] && server=$candidate
  done
fi
if [ -z "$server" ]; then
  echo "lua-language-server not found; set LUALS to its path" >&2
  exit 2
fi

logs=$(mktemp -d "${TMPDIR:-/tmp}/luals-check.XXXXXX")
trap 'rm -rf "$logs"' EXIT

status=0
"$server" --check="$root" --configpath="$root/.luarc.json" --checklevel=Information \
  --check_format=pretty --logpath="$logs" >"$logs/out" 2>/dev/null || status=$?

# the progress bar redraws its line with carriage returns
tr '\r' '\n' <"$logs/out" | grep -v -E -e '^ *$' -e '^Initializing' -e '^[>=]+ +[0-9]+/[0-9]+' \
  -e '^Diagnosis complete' || true
if [ "$status" -eq 0 ]; then
  echo "LuaLS: no problems"
else
  echo "LuaLS: problems found" >&2
fi
exit "$status"
