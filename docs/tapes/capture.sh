#!/usr/bin/env bash
# Re-capture the README screenshots in docs/media/:
#
#   DEVDOCS_SRC=~/.local/share/nvim/devdocs DEVDOCS_LAZY=~/.local/share/nvim/lazy \
#     bash docs/tapes/capture.sh [shot...]
#
# Shots: viewer examples search list apply health (default: all).
# DEVDOCS_SRC is only read: manifest.json, releases/ and a few docs are copied
# into /tmp/devdocs-demo, together with this commit of the plugin
# (git archive), so the frames show /tmp/devdocs-demo paths and nothing from
# your home. Needs Xvfb, xterm, xdotool, ImageMagick; runs on display :99.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=${DEVDOCS_SRC:?set DEVDOCS_SRC to an installed devdocs data dir}
LAZY=${DEVDOCS_LAZY:-}
DEMO=/tmp/devdocs-demo
DPY=${DEMO_DISPLAY:-:99}
OUT=$PWD/docs/media
SLUGS=(cpp 'lua~5.4' 'lua~5.1' 'python~3.12' 'python~3.13' css javascript node)
shots=("$@")
[ ${#shots[@]} -eq 0 ] && shots=(viewer examples search list apply health)

rm -rf -- "$DEMO"
mkdir -p "$DEMO"/{repo,data/docs,home,work,xdg/{config,data,state,cache}} "$OUT"
git archive HEAD | tar -x -C "$DEMO/repo"
# the tapes themselves may not be committed yet
mkdir -p "$DEMO/repo/docs" && cp -r docs/tapes "$DEMO/repo/docs/"
cp "$SRC/manifest.json" "$DEMO/data/"
[ -d "$SRC/releases" ] && cp -r "$SRC/releases" "$DEMO/data/"
for s in "${SLUGS[@]}"; do cp -r "$SRC/docs/$s" "$DEMO/data/docs/"; done
cat >"$DEMO/work/main.cpp" <<'EOF'
#include <iostream>
#include <vector>

int main() {
  std::vector<int> v{3, 1, 2};
  std::cout << v.size() << '\n';
  return 0;
}
EOF

Xvfb "$DPY" -screen 0 1400x900x24 -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
term=
cleanup() {
  [ -n "$term" ] && kill "$term" 2>/dev/null || true
  kill "$xvfb" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

# start <file>: a fresh 120x34 editor, nothing shared with the last shot
start() {
  [ -n "$term" ] && kill "$term" 2>/dev/null && wait "$term" 2>/dev/null || true
  rm -rf "$DEMO/xdg/state" "$DEMO/xdg/cache" && mkdir -p "$DEMO/xdg/state" "$DEMO/xdg/cache"
  env -i DISPLAY="$DPY" PATH="$PATH" HOME="$DEMO/home" TERM=xterm-256color LANG=C.UTF-8 \
    XDG_CONFIG_HOME="$DEMO/xdg/config" XDG_DATA_HOME="$DEMO/xdg/data" \
    XDG_STATE_HOME="$DEMO/xdg/state" XDG_CACHE_HOME="$DEMO/xdg/cache" \
    DEVDOCS_DATA="$DEMO/data" DEVDOCS_LAZY="$LAZY" \
    xterm -T devdocs-demo -geometry 120x34+0+0 -fa 'DejaVu Sans Mono' -fs 11 \
    -bg '#14161b' -fg '#e0e2ea' -bw 0 +sb -e \
    nvim --clean -u "$DEMO/repo/docs/tapes/minimal_init.lua" "$DEMO/work/$1" &
  term=$!
  for _ in $(seq 50); do
    win=$(DISPLAY=$DPY xdotool search --name '^devdocs-demo$' 2>/dev/null | head -1) && [ -n "$win" ] && break
    sleep 0.1
  done
  sleep 1.5
}
keys() { DISPLAY=$DPY xdotool key --delay 60 "$@"; }
typ() { DISPLAY=$DPY xdotool type --delay 15 "$1"; }
cmd() { typ "$1" && keys Return; }
shot() {
  sleep "${2:-1}"
  DISPLAY=$DPY import -window "$win" "$OUT/$1.png"
  magick "$OUT/$1.png" -strip -define png:compression-level=9 "$OUT/$1.png"
  echo "  $OUT/$1.png"
}

for s in "${shots[@]}"; do
  case $s in
  viewer) # symbol lookup on `cout` opens its entry in the viewer float
    start main.cpp && keys 6 G 0 7 l && cmd ':DevDocs definition' && shot viewer-definition 1.5 ;;
  examples) # `e` in the viewer narrows to the section's examples
    start main.cpp && keys 6 G 0 7 l && cmd ':DevDocs definition' && sleep 1.5 && keys e && shot viewer-examples ;;
  search) # telescope grep across the buffer's docs
    start main.cpp && cmd ':DevDocs search push_back' && shot search-picker 2.5 ;;
  list) # the manager, grouped by language, Lua expanded
    start main.cpp && cmd ':DevDocs list' && sleep 1.5 && keys j j j Tab && shot list-manager 1.5 ;;
  apply) # mark python~3.14 (install) and python~3.13 (uninstall), then S
    start main.cpp && cmd ':DevDocs list' && sleep 1.5 && typ '/python' && keys Return Tab j m m S &&
      shot list-apply 1.2 ;;
  health)
    start main.cpp && cmd ':checkhealth devdocs' && shot checkhealth 2 ;;
  *) echo "unknown shot: $s" >&2; exit 2 ;;
  esac
done
