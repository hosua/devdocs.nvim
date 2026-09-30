# devdocs.nvim

Offline DevDocs (devdocs.io) in Neovim: per-language auto-install, symbol lookup, examples, ripgrep search, Mason-like manager.

## Install

Requires Neovim >= 0.11. With lazy.nvim:

```lua
{ "hosua/devdocs.nvim", cmd = { "DevDocs" }, opts = {} }
```

## Commands

| Command | What it does |
|---|---|

## Default keymaps

None are installed unless `keymaps = true`. Suggested:

| Key | Command |
|---|---|

## Configuration

Every option, with its default:

```lua
require("devdocs").setup {
  notify = true,
}
```

## Health

`:checkhealth devdocs`

## Development

```bash
make test         # headless unit tests, no dependencies
make integration  # against a throwaway XDG tree
make check        # stylua --check
```
