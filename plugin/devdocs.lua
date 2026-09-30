-- Defines :DevDocs at startup without loading the plugin's Lua modules.
-- Everything heavy is required inside the callbacks, so a lazy.nvim
-- `cmd = { "DevDocs" }` stub and this file agree on the same entry point.
if vim.g.loaded_devdocs then
  return
end
vim.g.loaded_devdocs = true

vim.api.nvim_create_user_command("DevDocs", function(args)
  require("devdocs.commands").dispatch(args.fargs, args.bang)
end, {
  nargs = "*",
  bang = true,
  desc = "devdocs",
  complete = function(arglead, cmdline, pos)
    return require("devdocs.commands").complete(arglead, cmdline, pos)
  end,
})
