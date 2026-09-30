#!/usr/bin/env bash
# List manager smoke test: needs DEVDOCS_DATA with a cached manifest and cpp installed.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ -z "${DEVDOCS_DATA:-}" ] || [ ! -f "$DEVDOCS_DATA/manifest.json" ]; then
  echo "  skip  DEVDOCS_DATA with manifest.json not set"; exit 0
fi
source tests/smoke/lib.sh
work=$(mktemp -d)
smoke_start 120 40 env DEVDOCS_DATA="$DEVDOCS_DATA" XDG_DATA_HOME="$work/xdg" nvim --clean -u tests/smoke/init.lua
smoke_keys ':DevDocs list' Enter
sleep 0.8
smoke_expect 'DevDocs  [0-9]+ installed'
smoke_expect 'Installed \([0-9]+\)'
smoke_expect '✓ C\+\+'
smoke_expect 'Available \([0-9]+\)'
smoke_reject 'E[0-9]+:'
smoke_keys '}'                      # next group
smoke_keys 'G'                      # bottom of the list
smoke_keys 'gg'
smoke_keys '/'                      # live filter
smoke_type 'pyth'
sleep 0.4
smoke_expect 'filter: pyth'
smoke_expect 'Python'
smoke_keys Enter
smoke_keys 'j' 'j'
smoke_keys Tab                      # expand versions
sleep 0.4
smoke_expect '3\.1[0-4]'
smoke_keys '?'
sleep 0.4
smoke_expect 'DevDocs manager keys'
smoke_keys 'q'
smoke_resize 80 24
sleep 0.5
smoke_expect 'DevDocs'
smoke_reject 'E[0-9]+:'
smoke_screen | head -22
smoke_keys 'q'
smoke_stop; rm -rf "$work"
echo "list smoke: ok"
