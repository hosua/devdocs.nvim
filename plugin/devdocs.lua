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
  range = true,
  desc = "devdocs",
  complete = function(arglead, cmdline, pos)
    return require("devdocs.commands").complete(arglead, cmdline, pos)
  end,
})

-- Flat aliases for people who prefer one command per action. Each is a thin
-- wrapper over the matching subcommand and completes the same way.
local ALIASES = {
  DevDocsInstall = "install",
  DevDocsInstallAll = "install-all",
  DevDocsShowDefinition = "definition",
  DevDocsShowExample = "example",
  DevDocsSearch = "search",
  DevDocsList = "list",
  DevDocsOpen = "open",
  DevDocsUpdate = "update",
  DevDocsUninstall = "uninstall",
  DevDocsForceCloneAndScrape = "mirror",
}
for name, sub in pairs(ALIASES) do
  vim.api.nvim_create_user_command(name, function(args)
    local fargs = { sub }
    vim.list_extend(fargs, args.fargs)
    if name == "DevDocsForceCloneAndScrape" then
      fargs[#fargs + 1] = "--force"
    end
    require("devdocs.commands").dispatch(fargs, args.bang)
  end, {
    nargs = "*",
    bang = true,
    range = true,
    desc = "devdocs " .. sub,
    complete = function(arglead, _, _)
      return require("devdocs.commands").complete(arglead, "DevDocs " .. sub .. " " .. arglead, 0)
    end,
  })
end
