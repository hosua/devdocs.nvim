--- Lookup: the symbol under the cursor -> a doc page. Candidates from
--- symbols.lua, ranked over the buffer's docs first (detect.lua), then a
--- decisive hit opens straight away, several hits go to the picker, and
--- none falls back per config.lookup.fallback.
local config = require "devdocs.config"
local detect = require "devdocs.detect"
local index = require "devdocs.index"
local manifest = require "devdocs.manifest"
local picker = require "devdocs.ui.picker"
local rank = require "devdocs.rank"
local store = require "devdocs.store"
local symbols = require "devdocs.symbols"
local viewer = require "devdocs.ui.viewer"

local M = {}

local function notify(msg, level)
  vim.notify("devdocs: " .. msg, level or vim.log.levels.INFO)
end

--- Text of the current visual selection, or nil.
--- @return string|nil
function M.visual_text()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local ok, lines = pcall(vim.fn.getregion, vim.fn.getpos "v", vim.fn.getpos ".", { type = mode })
  if not ok or not lines then
    return nil
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  return vim.trim(table.concat(lines, " "))
end

--- Explain why nothing could be looked up and offer the install.
local function no_docs(bufdocs)
  if #bufdocs.bases == 0 then
    notify(
      ("no devdocs entry for filetype %q (add it with extra_filetypes, or :DevDocs open <doc>)"):format(bufdocs.ft),
      vim.log.levels.WARN
    )
    return
  end
  local docs = manifest.cached()
  local names = {}
  for _, base in ipairs(bufdocs.missing) do
    local d = docs and detect.slug_to_install(base, bufdocs.root, docs)
    names[#names + 1] = d and d.slug or base
  end
  notify(
    ("no docs installed for this buffer; :DevDocs install (%s) fetches %s"):format(
      "<leader>di in the suggested maps",
      table.concat(names, ", ")
    ),
    vim.log.levels.WARN
  )
end

local function fallback(cands, bufdocs)
  local how = config.get().lookup.fallback
  local word = cands[#cands] or cands[1] or ""
  if how == "lsp_hover" and #vim.lsp.get_clients { bufnr = 0 } > 0 then
    vim.lsp.buf.hover()
    return
  end
  if how == "search" and word ~= "" then
    local prefix = bufdocs.slugs[1] and ("@" .. bufdocs.slugs[1] .. " ") or ""
    require("devdocs").search(prefix .. word)
    return
  end
  local where = #bufdocs.slugs > 0 and (" in " .. table.concat(bufdocs.slugs, ", ")) or ""
  notify(
    ("no doc entry for %s%s (:DevDocs search covers every doc)"):format(table.concat(cands, ", "), where),
    vim.log.levels.WARN
  )
end

--- @param mode "section"|"examples"|"page"
--- @param opts { text?: string, bufnr?: integer }|nil
function M.run(mode, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local text = opts.text or M.visual_text()
  local cands = symbols.candidates(bufnr, { text = text })
  if #cands == 0 then
    notify("nothing under the cursor to look up", vim.log.levels.WARN)
    return
  end
  local bufdocs = detect.buffer(bufnr)
  local order, tiers = detect.lookup_order(bufnr)
  local sources = index.sources(order, tiers)
  if #sources == 0 then
    no_docs(bufdocs)
    return
  end
  local hits = rank.lookup(cands, sources, { limit = 25 })
  if #hits == 0 then
    fallback(cands, bufdocs)
    return
  end
  local function open(hit)
    viewer.open { slug = hit.slug, path = hit.entry.path, entry = hit.entry, mode = mode }
  end
  if rank.decisive(hits) then
    open(hits[1])
    return
  end
  picker.pick_hits(hits, ("DevDocs: %s"):format(cands[1]), open)
end

--- Open a doc by name and optional entry name: `:DevDocs open python os.path.join`.
--- @param doc string slug, base, alias or name
--- @param entry_query string|nil
function M.open(doc, entry_query)
  local installed = store.installed()
  local slug
  if store.is_installed(doc) then
    slug = doc
  else
    local candidates = vim.tbl_filter(function(s)
      return manifest.base(s) == doc or (store.meta(s) or {}).name == doc
    end, installed)
    if #candidates == 0 then
      local d = manifest.cached() and manifest.find(manifest.cached(), doc)
      if d then
        notify(("%s is not installed (:DevDocs install %s)"):format(d.slug, d.slug), vim.log.levels.WARN)
      else
        notify(("unknown doc %q"):format(doc), vim.log.levels.WARN)
      end
      return
    end
    slug = manifest.sort_newest(vim.tbl_map(function(s)
      return { slug = s, version = (store.meta(s) or {}).doc_version or "" }
    end, candidates))[1].slug
  end
  if not entry_query or entry_query == "" then
    local first = store.entries(slug)[1]
    viewer.open { slug = slug, path = first and first.path or "index", entry = nil, mode = "page" }
    return
  end
  local hits = rank.lookup({ entry_query }, index.sources({ slug }, { [slug] = 1 }), { limit = 25 })
  if #hits == 0 then
    notify(("no entry matching %q in %s"):format(entry_query, slug), vim.log.levels.WARN)
    return
  end
  local function open(hit)
    viewer.open { slug = hit.slug, path = hit.entry.path, entry = hit.entry, mode = "section" }
  end
  if rank.decisive(hits) then
    open(hits[1])
  else
    picker.pick_hits(hits, ("DevDocs %s: %s"):format(slug, entry_query), open)
  end
end

return M
