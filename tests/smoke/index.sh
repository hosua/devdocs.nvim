#!/usr/bin/env bash
# Index (glossary) smoke test: needs DEVDOCS_DATA pointing at a data dir with
# lua~5.4 installed (make smoke skips otherwise). Drives a real TUI:
# :DevDocs open lua~5.4 -> expand a type -> filter -> open an entry -> I (back
# to the index with the current entry marked) -> <BS> -> I I -> G stays native
# -> a small window keeps `? help` and `q close` in the footer.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ -z "${DEVDOCS_DATA:-}" ] || [ ! -d "$DEVDOCS_DATA/docs/lua~5.4" ]; then
  echo "  skip  DEVDOCS_DATA with lua~5.4 not set"; exit 0
fi
source tests/smoke/lib.sh
work=$(mktemp -d)
smoke_start 120 40 env DEVDOCS_DATA="$DEVDOCS_DATA" XDG_DATA_HOME="$work/xdg" nvim --clean -u tests/smoke/init.lua
smoke_keys ':DevDocs open lua~5.4' Enter    # no entry: the index
sleep 0.6
smoke_expect '▾ Lua'                          # doc row, open
smoke_expect '› index'                        # title
smoke_expect '▸ '                             # collapsed types
smoke_expect '⏎ open'
smoke_expect 'I page'
smoke_reject 'E[0-9]+:'
smoke_keys 'j' 'l'                           # first type: expand
smoke_expect '  ▾ '
smoke_keys 'zM'                              # collapse every type
smoke_reject '  ▾ '
smoke_keys 'zR'                              # expand every type
smoke_expect '  ▾ '
smoke_keys '/'
smoke_type 'table.insert'
smoke_keys Enter                             # keep the filter
sleep 0.4
smoke_expect 'table\.insert'
smoke_expect '[0-9]+/[0-9]+'                 # matches/total on the type
smoke_keys Enter                             # open the entry
sleep 0.6
smoke_expect 'table\.insert'
smoke_expect 'I index'
smoke_reject '› index'
smoke_keys 'I'                               # back to the index
sleep 0.4
smoke_expect '› index'
smoke_expect '●'                             # the entry we came from
smoke_keys BSpace                            # undo I: the page again
sleep 0.4
smoke_reject '› index'
smoke_keys 'I'
smoke_keys 'I'                               # I I: index, then the page again
sleep 0.4
smoke_reject '› index'
smoke_keys 'I'                               # and the index once more, entry marked
sleep 0.4
smoke_expect '› index'
smoke_expect '●'
smoke_keys 'q'
smoke_keys ':DevDocs open lua~5.4 assert' Enter   # an entry still opens its page
sleep 0.6
smoke_reject '› index'
smoke_keys 'G'                               # native: bottom of the page, not the index
smoke_reject '› index'
smoke_keys 'q'
smoke_keys ':DevDocs open lua~5.4' Enter
sleep 0.6
smoke_resize 80 24
sleep 0.4
smoke_expect '? help'
smoke_expect 'q close'
smoke_keys '?'
smoke_expect 'DevDocs index keys'
smoke_keys BSpace
smoke_expect '▾ Lua'
smoke_reject 'E[0-9]+:'
smoke_keys 'q'
smoke_screen | head -30
smoke_stop; rm -rf "$work"
echo "index smoke: ok"
