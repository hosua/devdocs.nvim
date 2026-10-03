-- Editor for the README screenshots (docs/tapes/capture.sh): this plugin
-- tree, stock colorscheme, docs from $DEVDOCS_DATA, telescope from
-- $DEVDOCS_LAZY when present.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)
for _, name in ipairs { "plenary.nvim", "telescope.nvim" } do
  local dir = (os.getenv "DEVDOCS_LAZY" or "") .. "/" .. name
  if vim.uv.fs_stat(dir) then
    vim.opt.runtimepath:append(dir)
  end
end
vim.o.termguicolors = true
vim.o.winborder = "rounded"
vim.o.number = true
vim.o.laststatus = 2
vim.o.shortmess = vim.o.shortmess .. "I"
require("devdocs").setup {
  data_dir = assert(os.getenv "DEVDOCS_DATA", "DEVDOCS_DATA is not set"),
  install_as_needed = false,
}
