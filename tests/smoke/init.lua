-- Minimal init for tmux smoke tests: this checkout only, docs from $DEVDOCS_DATA.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)
vim.o.termguicolors = true
-- telescope + plenary from a lazy.nvim install, when present (search picker smoke)
for _, name in ipairs { "plenary.nvim", "telescope.nvim" } do
  local dir = vim.fn.stdpath "data" .. "/lazy/" .. name
  if os.getenv "DEVDOCS_LAZY" then
    dir = os.getenv "DEVDOCS_LAZY" .. "/" .. name
  end
  if vim.uv.fs_stat(dir) then
    vim.opt.runtimepath:append(dir)
  end
end
vim.o.winborder = "rounded"
require("devdocs").setup {
  data_dir = os.getenv "DEVDOCS_DATA" or (vim.fn.stdpath "data" .. "/devdocs"),
  install_as_needed = false,
  import = { import_only = true },
}
