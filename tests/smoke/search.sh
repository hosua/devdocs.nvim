#!/usr/bin/env bash
# Search picker smoke test: needs DEVDOCS_DATA (cpp installed) and telescope
# under DEVDOCS_LAZY or ~/.local/share/nvim/lazy (skips otherwise).
set -euo pipefail
cd "$(dirname "$0")/../.."
lazy=${DEVDOCS_LAZY:-$HOME/.local/share/nvim/lazy}
if [ -z "${DEVDOCS_DATA:-}" ] || [ ! -d "$DEVDOCS_DATA/docs/cpp" ] || [ ! -d "$lazy/telescope.nvim" ]; then
  echo "  skip  needs DEVDOCS_DATA with cpp and telescope.nvim under $lazy"; exit 0
fi
source tests/smoke/lib.sh
work=$(mktemp -d)
printf '#include <iostream>\nint main() { std::cout << 1; }\n' > "$work/main.cpp"
smoke_start 140 40 env DEVDOCS_DATA="$DEVDOCS_DATA" DEVDOCS_LAZY="$lazy" XDG_DATA_HOME="$work/xdg" nvim --clean -u tests/smoke/init.lua "$work/main.cpp"
smoke_keys ':DevDocs search sync_with_stdio' Enter
sleep 1.5
smoke_expect 'DevDocs grep'
smoke_expect '\[C\+\+\]'
smoke_reject 'E[0-9]+:'
smoke_keys C-t                              # entry-name mode keeps the prompt
sleep 1
smoke_expect 'DevDocs entries'
smoke_expect 'sync_with_stdio'
smoke_keys Enter                            # open the top hit in the viewer
sleep 0.8
smoke_expect 'sync_with_stdio'
smoke_expect '⏎ follow'
smoke_reject 'E[0-9]+:'
smoke_screen | head -24
smoke_stop; rm -rf "$work"
echo "search smoke: ok"
