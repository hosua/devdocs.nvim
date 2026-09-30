-- Minimal init for tmux smoke tests: this checkout only, docs from $DEVDOCS_DATA.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)
vim.o.termguicolors = true
vim.o.winborder = "rounded"
require("devdocs").setup {
  data_dir = os.getenv "DEVDOCS_DATA" or (vim.fn.stdpath "data" .. "/devdocs"),
  install_as_needed = false,
  import = { import_only = true },
}
