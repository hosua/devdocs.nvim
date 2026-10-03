--- :DevDocs <sub> [args] dispatcher and its completion.
local M = {}

local function api()
  return require "devdocs"
end

--- @type table<string, fun(args: string[], bang: boolean)>
M.subcommands = {
  definition = function(args)
    api().definition { text = #args > 0 and table.concat(args, " ") or nil }
  end,
  example = function(args)
    api().example { text = #args > 0 and table.concat(args, " ") or nil }
  end,
  open = function(args)
    api().open(args[1], #args > 1 and table.concat(vim.list_slice(args, 2), " ") or nil)
  end,
  search = function(args)
    api().search(#args > 0 and table.concat(args, " ") or nil)
  end,
  install = function(args, bang)
    api().install(args[1], { force = bang })
  end,
  ["install-all"] = function(_, bang)
    api().install_all { yes = bang }
  end,
  uninstall = function(args, bang)
    api().uninstall(args[1], { yes = bang })
  end,
  update = function(args)
    api().update(args[1])
  end,
  prune = function(args, bang)
    api().prune { base = args[1], yes = bang }
  end,
  sync = function()
    api().sync()
  end,
  status = function()
    api().status()
  end,
  resync = function(_, bang)
    api().resync { all = bang }
  end,
  detect = function()
    api().detect()
  end,
  recent = function()
    api().recent()
  end,
  list = function()
    local ok, list = pcall(require, "devdocs.ui.list")
    if ok then
      list.open()
    else
      local store = require "devdocs.store"
      vim.notify("devdocs: installed: " .. table.concat(store.installed(), ", "), vim.log.levels.INFO)
    end
  end,
  mirror = function(args, bang)
    local ok, mirror = pcall(require, "devdocs.mirror")
    if ok then
      mirror.run { force = bang or vim.tbl_contains(args, "--force"), scrape = vim.tbl_contains(args, "--scrape") }
    else
      vim.notify("devdocs: the mirror command lands in a later release", vim.log.levels.WARN)
    end
  end,
}

--- @param fargs string[]
--- @param bang boolean
function M.dispatch(fargs, bang)
  local sub = fargs[1]
  local fn = sub and M.subcommands[sub]
  if not fn then
    local names = vim.tbl_keys(M.subcommands)
    table.sort(names)
    vim.notify(
      ("devdocs: unknown subcommand %q (have: %s)"):format(tostring(sub), table.concat(names, ", ")),
      vim.log.levels.ERROR
    )
    return
  end
  fn(vim.list_slice(fargs, 2), bang)
end

--- Slugs for completion: installed first, then the cached manifest.
--- @param installed_only boolean
--- @return string[]
local function slugs(installed_only)
  local store = require "devdocs.store"
  local out = store.installed()
  if installed_only then
    return out
  end
  local seen = {}
  for _, s in ipairs(out) do
    seen[s] = true
  end
  local docs = require("devdocs.manifest").cached()
  for _, d in ipairs(docs or {}) do
    if not seen[d.slug] then
      out[#out + 1] = d.slug
    end
  end
  return out
end

--- @return string[]
function M.complete(arglead, cmdline, _)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  -- "DevDocs ins|" -> completing the subcommand; "DevDocs install cs|" -> its argument
  local completing_sub = #words <= 1 or (#words == 2 and not cmdline:match "%s$")
  if completing_sub then
    local names = vim.tbl_keys(M.subcommands)
    table.sort(names)
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, names)
  end
  local sub = words[2]
  local candidates = {}
  if sub == "install" then
    candidates = slugs(false)
  elseif sub == "uninstall" or sub == "update" or sub == "open" then
    candidates = slugs(true)
  elseif sub == "prune" then
    -- languages with more than one installed version
    local count, bases = {}, {}
    for _, s in ipairs(slugs(true)) do
      local b = require("devdocs.manifest").base(s)
      count[b] = (count[b] or 0) + 1
      if count[b] == 2 then
        bases[#bases + 1] = b
      end
    end
    table.sort(bases)
    candidates = bases
  elseif sub == "search" and arglead:sub(1, 1) == "@" then
    candidates = vim.tbl_map(function(s)
      return "@" .. s
    end, slugs(true))
  elseif sub == "mirror" then
    candidates = { "--force", "--scrape" }
  end
  return vim.tbl_filter(function(n)
    return vim.startswith(n, arglead)
  end, candidates)
end

return M
