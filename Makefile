.PHONY: test integration smoke golden fmt check

# Both run against a throwaway XDG tree: a bug can never touch real user data,
# and nothing from the user's config or site dir (nvim-treesitter's parsers and
# queries, other plugins) leaks onto the runtimepath, so local runs match CI.
HERMETIC = tmp=$$(mktemp -d) && \
	  XDG_CONFIG_HOME=$$tmp/config XDG_DATA_HOME=$$tmp/data XDG_STATE_HOME=$$tmp/state \
	  XDG_CACHE_HOME=$$tmp/cache XDG_CONFIG_DIRS=$$tmp/config-dirs XDG_DATA_DIRS=$$tmp/data-dirs \
	  nvim --headless -u NONE -l tests/run.lua

test:
	@$(HERMETIC) spec; rc=$$?; rm -rf $$tmp; exit $$rc

integration:
	@$(HERMETIC) integration; rc=$$?; rm -rf $$tmp; exit $$rc

smoke:
	@for t in tests/smoke/*.sh; do [ -e "$$t" ] || continue; echo "== $$t"; bash "$$t" || exit 1; done

# Rewrite the converter goldens from tests/fixtures/*.html; review the diff.
golden:
	nvim --headless -u NONE -l tests/fixtures/regen.lua

fmt:
	stylua .

check:
	stylua --check .
