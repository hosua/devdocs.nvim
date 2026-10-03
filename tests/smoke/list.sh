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
smoke_expect 'Name +Version +Size +Released +Pages +Notes'   # column header
smoke_expect 'Installed \([0-9]+\)'
smoke_expect '✓ +C\+\+ '                 # one row per language
smoke_expect '[0-9.]+ \(current\)'        # rolling slug shows its release
smoke_expect '≈?[0-9]{4}-[0-9]{2}-[0-9]{2}'
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
smoke_expect '[▸▾] Python'               # one row per language, with a chevron
smoke_reject '[├└] '                      # versions folded
smoke_keys Tab                      # expand the first match (every match has versions)
sleep 0.4
smoke_expect '[├└] [a-z_]+~?'
smoke_keys 'j' 'h'                  # h on a version folds its language
sleep 0.4
smoke_reject '[├└] '
# install marks: the first Available language is not installed at all
smoke_keys '/' Escape               # clear the filter
smoke_keys 'gg' '}' 'm'
sleep 0.3
smoke_expect '1 marked'
smoke_expect '^.{0,20}│● · '                 # the mark glyph on a row that is not installed
smoke_keys ':w' Enter               # the apply menu (S does the same)
sleep 0.6
smoke_expect 'Apply changes'
smoke_expect 'Install \(1\) +-[0-9.]+ [kMG]B'
smoke_reject 'Uninstall \('
smoke_expect 'y/⏎ apply   n/q/Esc cancel'
smoke_keys 'n'                      # cancel: nothing installs, the mark stays
sleep 0.3
smoke_reject 'Apply changes'
smoke_expect '1 marked'
smoke_keys 'M'
smoke_reject '[0-9]+ marked'
smoke_keys '?'
sleep 0.4
smoke_expect 'DevDocs manager keys'
smoke_keys 'q'
smoke_resize 80 24
sleep 0.5
smoke_expect 'DevDocs  [0-9]+ installed'   # the header stays on screen when the window shrinks
smoke_expect 'Name +Version'
smoke_reject 'E[0-9]+:'
smoke_screen | head -22
smoke_keys 'q'
smoke_stop; rm -rf "$work"
echo "list smoke: ok"
