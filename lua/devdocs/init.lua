--- devdocs: public API.
---
--- setup() is optional: every entry point resolves the config on first use,
--- so the plugin works with `opts = {}` or with no setup call at all. What
--- setup() adds is the background behaviour: install_as_needed on FileType
--- and the import.docs sync shortly after startup.
local M = {}

local function notify(msg, level)
  vim.notify("devdocs: " .. msg, level or vim.log.levels.INFO)
end

local function cfg()
  return require("devdocs.config").get()
end

-- ---------------------------------------------------------------- lookups

--- Definition of the symbol under the cursor (or the visual selection).
--- @param opts { text?: string }|nil
function M.definition(opts)
  require("devdocs.lookup").run("section", opts)
end

--- Only the examples of the entry under the cursor.
--- @param opts { text?: string }|nil
function M.example(opts)
  require("devdocs.lookup").run("examples", opts)
end

--- Open a doc (and optionally an entry in it) by name.
--- @param doc string
--- @param entry string|nil
function M.open(doc, entry)
  require("devdocs.lookup").open(doc, entry)
end

--- Full-text search across installed docs (the picker lands in a later PR;
--- until then this greps and lists the hits in the viewer-less quickfix).
--- @param query string|nil
function M.search(query)
  local ok, ui = pcall(require, "devdocs.ui.search")
  if ok then
    ui.open(query)
    return
  end
  local search = require "devdocs.search"
  local detect = require "devdocs.detect"
  query = query or vim.fn.input "DevDocs search: "
  if not query or query == "" then
    return
  end
  local slug_filter, text = search.parse_query(query)
  local order = slug_filter and { slug_filter } or detect.lookup_order()
  search.grep(text, order, nil, function(hits, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    local paths = require "devdocs.paths"
    local items = {}
    for _, h in ipairs(hits) do
      items[#items + 1] = {
        filename = paths.page_file(h.slug, h.page),
        lnum = h.line,
        col = h.col,
        text = ("[%s] %s: %s"):format(h.slug, h.page, h.text),
      }
    end
    vim.fn.setqflist({}, " ", { title = "DevDocs: " .. text, items = items })
    vim.cmd "copen"
  end)
end

-- ---------------------------------------------------------------- installing

--- Install docs. With no slug: the docs the current buffer is missing.
--- @param slug string|nil
--- @param opts { force?: boolean }|nil
function M.install(slug, opts)
  opts = opts or {}
  local installer = require "devdocs.installer"
  local manifest = require "devdocs.manifest"
  local detect = require "devdocs.detect"
  manifest.get(function(docs, err)
    if not docs then
      notify(err or "no docs list", vim.log.levels.ERROR)
      return
    end
    if err then
      notify(err, vim.log.levels.WARN)
    end
    local targets = {}
    if slug and slug ~= "" then
      local d = manifest.find(docs, slug)
      if not d then
        notify(("unknown doc %q (:DevDocs list shows every name)"):format(slug), vim.log.levels.ERROR)
        return
      end
      targets[1] = d
    else
      targets = detect.missing_docs(nil, docs)
      if #targets == 0 then
        local b = detect.buffer()
        if #b.slugs > 0 then
          notify(("docs for this buffer are installed: %s"):format(table.concat(b.slugs, ", ")))
        else
          notify(("no devdocs entry for filetype %q"):format(b.ft), vim.log.levels.WARN)
        end
        return
      end
    end
    local slugs, by_slug, total = {}, {}, 0
    for _, d in ipairs(targets) do
      slugs[#slugs + 1] = d.slug
      by_slug[d.slug] = d
      total = total + (d.db_size or 0)
    end
    notify(("installing %s (%.1f MB)"):format(table.concat(slugs, ", "), total / 1e6))
    installer.install_many(slugs, { force = opts.force, docs = by_slug }, function(summary)
      if summary.failed > 0 then
        for s, e in pairs(summary.errors) do
          notify(("%s: %s"):format(s, e), vim.log.levels.ERROR)
        end
      end
    end)
  end)
end

--- Install every doc devdocs offers. Asks first: it is several gigabytes.
--- @param opts { yes?: boolean, update?: boolean }|nil
function M.install_all(opts)
  opts = opts or {}
  local installer = require "devdocs.installer"
  local manifest = require "devdocs.manifest"
  local store = require "devdocs.store"
  manifest.get(function(docs, err)
    if not docs then
      notify(err or "no docs list", vim.log.levels.ERROR)
      return
    end
    local installed = {}
    for _, s in ipairs(store.installed()) do
      installed[s] = store.meta(s)
    end
    local plan = installer.plan(
      vim.tbl_map(function(d)
        return d.slug
      end, docs),
      manifest.by_slug(docs),
      installed,
      { update = opts.update ~= false }
    )
    local slugs, by_slug, total = {}, {}, 0
    for _, p in ipairs(plan) do
      if p.action == "install" or p.action == "update" then
        slugs[#slugs + 1] = p.slug
        by_slug[p.slug] = manifest.by_slug(docs)[p.slug]
        total = total + (by_slug[p.slug].db_size or 0)
      end
    end
    if #slugs == 0 then
      notify "every doc is installed and current"
      return
    end
    local msg = ("Install %d docs (%.1f GB of HTML to download and convert)? Already installed ones are skipped."):format(
      #slugs,
      total / 1e9
    )
    if not opts.yes and not require("devdocs.ui.float").confirm(msg) then
      return
    end
    notify(
      ("installing %d docs with %d parallel jobs; :DevDocs status shows progress"):format(
        #slugs,
        cfg().install.max_jobs
      )
    )
    installer.install_many(slugs, { docs = by_slug }, function(summary)
      notify(
        ("install-all finished: %d ok, %d failed"):format(summary.ok, summary.failed),
        summary.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
      )
    end)
  end)
end

--- Remove an installed doc after confirming.
--- @param slug string
--- @param opts { yes?: boolean }|nil
function M.uninstall(slug, opts)
  local paths = require "devdocs.paths"
  local installer = require "devdocs.installer"
  if not slug or slug == "" then
    notify("usage: :DevDocs uninstall <slug>", vim.log.levels.ERROR)
    return
  end
  if not require("devdocs.store").is_installed(slug) then
    notify(("%s is not installed"):format(slug), vim.log.levels.WARN)
    return
  end
  if
    not (opts and opts.yes) and not require("devdocs.ui.float").confirm(("Delete %s?"):format(paths.doc_dir(slug)))
  then
    return
  end
  local ok, err = installer.uninstall(slug)
  if ok then
    notify(("removed %s"):format(slug))
  else
    notify(err, vim.log.levels.ERROR)
  end
end

--- Update one doc, or every installed doc that the manifest lists as newer.
--- @param slug string|nil
function M.update(slug)
  local installer = require "devdocs.installer"
  local manifest = require "devdocs.manifest"
  manifest.get(function(docs, err)
    if not docs then
      notify(err or "no docs list", vim.log.levels.ERROR)
      return
    end
    local slugs = slug and slug ~= "" and { slug } or installer.outdated(docs)
    if #slugs == 0 then
      notify "every installed doc is current"
      return
    end
    notify(("updating %s"):format(table.concat(slugs, ", ")))
    installer.install_many(slugs, { force = true, docs = manifest.by_slug(docs) }, function(summary)
      notify(("updated %d, failed %d"):format(summary.ok, summary.failed))
    end)
  end, { force = true })
end

--- One line per running/finished install job.
function M.status()
  local jobs = require("devdocs.installer").status()
  if #jobs == 0 then
    notify "no install jobs"
    return
  end
  local lines = {}
  for _, j in ipairs(jobs) do
    lines[#lines + 1] = ("%-24s %-9s %3d%%%s"):format(
      j.slug,
      j.stage,
      math.floor(j.progress * 100),
      j.err and ("  " .. j.err) or ""
    )
  end
  notify(table.concat(lines, "\n"))
end

--- Statusline text while installs run, "" otherwise.
--- @return string
function M.statusline()
  local installer = require "devdocs.installer"
  if not installer.is_busy() then
    return ""
  end
  local running = vim.tbl_filter(function(j)
    return j.stage ~= "done" and j.stage ~= "error" and j.stage ~= "queued"
  end, installer.status())
  if #running == 0 then
    return ("devdocs ↓ %d queued"):format(#installer.queue)
  end
  local j = running[1]
  local more = #running + #installer.queue - 1
  return ("devdocs ↓ %s %d%%%s"):format(j.slug, math.floor(j.progress * 100), more > 0 and (" +" .. more) or "")
end

--- Recently viewed pages.
function M.recent()
  local st = require("devdocs.store").state()
  if #st.recent == 0 then
    notify "no pages viewed yet"
    return
  end
  local viewer = require "devdocs.ui.viewer"
  local index = require "devdocs.index"
  vim.ui.select(st.recent, {
    prompt = "DevDocs recent",
    format_item = function(r)
      return ("%s  [%s]"):format(r.name or r.path, r.slug)
    end,
  }, function(r)
    if r then
      viewer.open { slug = r.slug, path = r.path, entry = index.entry_for_path(r.slug, r.path), mode = "section" }
    end
  end)
end

-- ---------------------------------------------------------------- background behaviour

local function maybe_install_for(bufnr)
  local c = cfg()
  if c.install_as_needed == false or c.import.import_only then
    return
  end
  if vim.bo[bufnr].buftype ~= "" then
    return
  end
  local detect = require "devdocs.detect"
  local b = detect.buffer(bufnr)
  if #b.missing == 0 then
    return
  end
  local manifest = require "devdocs.manifest"
  manifest.get(function(docs)
    if not docs then
      return
    end
    local targets = detect.missing_docs(bufnr, docs)
    local installer = require "devdocs.installer"
    targets = vim.tbl_filter(function(d)
      return not installer.is_running(d.slug) and not M._declined[d.slug]
    end, targets)
    if #targets == 0 then
      return
    end
    local slugs, by_slug, total = {}, {}, 0
    for _, d in ipairs(targets) do
      slugs[#slugs + 1] = d.slug
      by_slug[d.slug] = d
      total = total + (d.db_size or 0)
    end
    local function go()
      notify(("installing %s (%.1f MB) for this %s buffer"):format(table.concat(slugs, ", "), total / 1e6, b.ft))
      installer.install_many(slugs, { docs = by_slug })
    end
    if c.install_as_needed == "prompt" then
      vim.schedule(function()
        if
          require("devdocs.ui.float").confirm(
            ("Install devdocs %s (%.1f MB) for this buffer?"):format(table.concat(slugs, ", "), total / 1e6)
          )
        then
          go()
        else
          for _, s in ipairs(slugs) do
            M._declined[s] = true
          end
        end
      end)
    else
      go()
    end
  end)
end
M._declined = {}

--- Install everything import.docs (or the Mason-derived defaults) asks for
--- and is not installed yet.
--- @param cb fun(slugs: string[])|nil called with what was queued
function M.sync(cb)
  local c = cfg()
  local manifest = require "devdocs.manifest"
  local langmap = require "devdocs.langmap"
  local store = require "devdocs.store"
  manifest.get(function(docs, err)
    if not docs then
      if err then
        notify(err, vim.log.levels.WARN)
      end
      return
    end
    local patterns = c.import.docs
    if #patterns == 0 and not c.import.import_only then
      patterns = langmap.bases_for_mason(langmap.mason_installed(), c.extra_mason)
    end
    local slugs, unmatched = langmap.expand_import(docs, patterns, { all = c.import.all })
    if #unmatched > 0 then
      notify(("import.docs: no doc matches %s"):format(table.concat(unmatched, ", ")), vim.log.levels.WARN)
    end
    slugs = vim.tbl_filter(function(s)
      return not store.is_installed(s)
    end, slugs)
    if #slugs == 0 then
      if cb then
        cb {}
      end
      return
    end
    local by_slug = manifest.by_slug(docs)
    local total = 0
    for _, s in ipairs(slugs) do
      total = total + (by_slug[s].db_size or 0)
    end
    notify(("importing %d docs (%.1f MB): %s"):format(#slugs, total / 1e6, table.concat(slugs, ", ")))
    require("devdocs.installer").install_many(slugs, { docs = by_slug })
    if cb then
      cb(slugs)
    end
  end)
end

--- @param opts table|nil user overrides, merged over config.defaults
function M.setup(opts)
  local c = require("devdocs.config").resolve(opts)
  local group = vim.api.nvim_create_augroup("devdocs", { clear = true })
  if c.install_as_needed and not c.import.import_only then
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      callback = function(ev)
        -- defer so the first buffer of a session never pays for the manifest fetch
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            maybe_install_for(ev.buf)
          end
        end, 500)
      end,
    })
  end
  if #c.import.docs > 0 or not c.import.import_only then
    vim.defer_fn(function()
      M.sync()
    end, 2000)
  end
end

return M
