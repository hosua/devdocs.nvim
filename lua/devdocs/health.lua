--- :checkhealth devdocs
local M = {}

local function version_of(bin)
  local res = vim.system({ bin, "--version" }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  return vim.trim((res.stdout or ""):match "[^\n]*" or "")
end

local function dir_size(dir)
  local res = vim.system({ "du", "-sh", dir }, { text = true }):wait()
  if res.code ~= 0 then
    return "?"
  end
  return (res.stdout or ""):match "^(%S+)" or "?"
end

function M.check()
  local h = vim.health
  local config = require "devdocs.config"
  local paths = require "devdocs.paths"
  local store = require "devdocs.store"
  local manifest = require "devdocs.manifest"
  local cfg = config.get()

  h.start "devdocs"
  if vim.fn.has "nvim-0.11" == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error "Neovim >= 0.11 is required"
  end
  -- Which copy is loaded matters when a dev checkout and a lazy clone coexist.
  local src = debug.getinfo(require("devdocs").setup, "S").source:gsub("^@", "")
  h.info("loaded from " .. vim.fn.fnamemodify(src, ":~"))

  h.start "tools"
  for _, t in ipairs {
    { cfg.install.curl, "downloads docs", true },
    { cfg.install.tar, "extracts doc tarballs", true },
    { cfg.search.rg, "full-text search (:DevDocs search)", true },
    { cfg.mirror.git, ":DevDocs mirror", false },
    { cfg.mirror.docker, ":DevDocs mirror", false },
  } do
    local bin, what, required = t[1], t[2], t[3]
    if vim.fn.executable(bin) == 1 then
      h.ok(("%s: %s"):format(bin, version_of(bin) or "found"))
    elseif required then
      h.error(("%s is not installed (%s)"):format(bin, what))
    else
      h.warn(("%s is not installed (only needed for %s)"):format(bin, what))
    end
  end
  if pcall(require, "telescope") then
    h.ok "telescope.nvim: search and candidate pickers use it"
  else
    h.info "telescope.nvim not found: search greps into the quickfix list, candidates use vim.ui.select"
  end
  if pcall(vim.treesitter.language.add, "markdown") then
    h.ok "treesitter markdown parser: viewer highlighting"
  else
    h.warn "no treesitter markdown parser: the viewer shows plain text"
  end

  h.start "data"
  local root = paths.data_dir()
  if vim.fn.isdirectory(root) == 1 then
    if vim.fn.filewritable(root) == 2 then
      h.ok(("%s (%s)"):format(vim.fn.fnamemodify(root, ":~"), dir_size(root)))
    else
      h.error(root .. " is not writable")
    end
  else
    h.info(root .. " does not exist yet (created on first install)")
  end
  local installed = store.installed()
  if #installed == 0 then
    h.info "no docs installed (:DevDocs install, :DevDocs list)"
  else
    local names = {}
    for _, slug in ipairs(installed) do
      local m = store.meta(slug) or {}
      names[#names + 1] = ("%s (%d pages%s)"):format(
        slug,
        m.page_count or 0,
        (m.skipped and #m.skipped > 0) and (", " .. #m.skipped .. " skipped") or ""
      )
    end
    h.ok(("%d docs installed: %s"):format(#installed, table.concat(names, ", ")))
  end
  local st, serr = store.state()
  if serr then
    h.warn("state.json: " .. serr)
  else
    local off = 0
    for _, on in pairs(st.enabled) do
      if on == false then
        off = off + 1
      end
    end
    h.ok(("state.json v%d, %d disabled, %d recent pages"):format(st.version, off, #st.recent))
  end
  local docs, at = manifest.cached()
  if docs then
    local age = os.time() - (at or 0)
    h.ok(
      ("docs list: %d docs, fetched %s ago%s"):format(
        #docs,
        age < 3600 and (math.floor(age / 60) .. " min") or (math.floor(age / 3600) .. " h"),
        manifest.is_fresh() and "" or " (stale; refreshed on next use)"
      )
    )
  else
    h.info("docs list not fetched yet (" .. cfg.install.manifest_url .. ")")
  end
  h.info(
    ("source: %s from %s"):format(
      cfg.install.source,
      cfg.install.source == "tarball" and cfg.install.tarball_url or cfg.install.doc_url
    )
  )
  local jobs = require("devdocs.installer").status()
  if #jobs > 0 then
    h.info(("%d install jobs known (:DevDocs status)"):format(#jobs))
  end
end

return M
