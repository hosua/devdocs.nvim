#!/usr/bin/env bash
# Viewer smoke test: needs DEVDOCS_DATA pointing at a data dir with cpp and
# lua~5.4 installed (make smoke skips otherwise).
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ -z "${DEVDOCS_DATA:-}" ] || [ ! -d "$DEVDOCS_DATA/docs/cpp" ]; then
  echo "  skip  DEVDOCS_DATA with cpp + lua~5.4 not set"; exit 0
fi
source tests/smoke/lib.sh
work=$(mktemp -d)
printf '#include <iostream>\nusing namespace std;\nint main() { cout << "hi"; return 0; }\n' > "$work/main.cpp"
smoke_start 120 40 env DEVDOCS_DATA="$DEVDOCS_DATA" XDG_DATA_HOME="$work/xdg" nvim --clean -u tests/smoke/init.lua "$work/main.cpp"
smoke_keys '3G' '0' '14l'                    # onto "cout"
smoke_keys ':DevDocs definition' Enter
sleep 0.6
smoke_expect 'std::cout'
smoke_expect 'extern std::ostream cout'
smoke_expect '⏎ follow'
smoke_reject 'E[0-9]+:'
smoke_keys 'e'                               # examples only
sleep 0.4
smoke_expect 'examples'
smoke_keys 'p'                               # whole page
smoke_keys '?'                               # help
smoke_expect 'DevDocs viewer keys'
smoke_keys BSpace                            # back
smoke_resize 80 24
sleep 0.4
smoke_expect 'std::cout'
smoke_reject 'E[0-9]+:'
smoke_keys 'q'
smoke_keys ':DevDocs open lua~5.4 assert' Enter
sleep 0.6
smoke_expect 'assert'
smoke_reject 'E[0-9]+:'
smoke_keys 'p'                               # whole page, scrolled to assert
sleep 0.4
smoke_expect 'assert \(v'
smoke_expect 'collectgarbage'                # the next section: this is the page
smoke_reject 'Reference Manual'              # not page line 1
smoke_reject 'E[0-9]+:'
smoke_keys BSpace                            # back to the section
smoke_reject 'collectgarbage'
smoke_keys 'q'
smoke_keys ':DevDocs definition' Enter        # cursor back in main.cpp on cout
sleep 0.6
smoke_expect 'std::cout'
smoke_screen | head -30
smoke_stop; rm -rf "$work"
echo "viewer smoke: ok"
