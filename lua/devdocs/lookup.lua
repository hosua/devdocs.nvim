--- Lookup: the symbol under the cursor -> a doc page. Candidates from
--- symbols.lua, ranked over the buffer's docs first (detect.lua), then a
--- decisive hit opens straight away, several hits go to the picker, and
--- none falls back per config.lookup.fallback. With config.lookup.smart a
--- project variable under the cursor (classify.lua) shows LSP hover instead,
--- and any other non-keyword the docs have no entry named exactly like
--- (rank.exact) shows hover before fuzzy matches or the fallback.
--- An empty hover (every client errored or said nothing) goes on as if there
--- had been no hover.
--- With config.lookup.explain a target with nothing to document (a string,
--- comment, number, whitespace, operator or punctuation; true/false/nil the
--- docs have no entry for; a variable hover has nothing on; a name declared in
--- this buffer that neither docs nor hover know) shows a small popup
--- (explain.lua) instead of the picker, the fallback or a wrong page.
local classify = require "devdocs.classify"
local config = require "devdocs.config"
local detect = require "devdocs.detect"
local explain = require "devdocs.explain"
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

--- Whether a client attached to `bufnr` implements textDocument/hover.
--- @param bufnr integer
--- @return boolean
function M.can_hover(bufnr)
  return #vim.lsp.get_clients { bufnr = bufnr, method = "textDocument/hover" } > 0
end

--- Markdown lines of every non-empty hover answer, in client order, separated
--- by a rule; empty when every client errored or had nothing to say.
--- @param results table<integer, { err?: table, result?: table }>|nil
--- @return string[]
function M.hover_lines(results)
  local ids = vim.tbl_keys(results or {})
  table.sort(ids)
  local lines = {}
  for _, id in ipairs(ids) do
    local r = results[id]
    local contents = not (r.err or r.error) and r.result and r.result.contents
    if contents then
      local md = vim.lsp.util.convert_input_to_markdown_lines(contents)
      if vim.trim(table.concat(md, "\n")) ~= "" then
        if #lines > 0 then
          vim.list_extend(lines, { "", "---", "" })
        end
        vim.list_extend(lines, md)
      end
    end
  end
  return lines
end

--- Ask the clients for hover at the cursor and show it like vim.lsp.buf.hover()
--- does; `on_empty` runs instead when no client has anything to say. False
--- when no client can hover (nothing was asked; the caller goes on).
--- @param bufnr integer
--- @param on_empty fun()
--- @return boolean
local function try_hover(bufnr, on_empty)
  if not M.can_hover(bufnr) then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  local function params(client)
    return vim.lsp.util.make_position_params(win, client.offset_encoding or "utf-16")
  end
  vim.lsp.buf_request_all(bufnr, "textDocument/hover", params, function(results)
    local lines = M.hover_lines(results)
    if #lines == 0 then
      on_empty()
      return
    end
    vim.lsp.util.open_floating_preview(lines, "markdown", { focus_id = "textDocument/hover" })
  end)
  return true
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

--- Classes looked up in the docs first that still hover when the docs have
--- no exact entry. "library" is among them: lua_ls marks Neovim's own vim.*
--- API defaultLibrary too, which no devdocs doc covers. Keywords and builtins
--- are the language's own words (the docs have them); a "variable" has had
--- its hover already; nil is an explicit lookup or lookup.smart = false.
local HOVER_UNLESS_EXACT = { symbol = true, library = true, unknown = true }

--- `then_` unless `class` may hover and hover answers first.
local function hover_or(class, bufnr, then_)
  if not (HOVER_UNLESS_EXACT[class or ""] and try_hover(bufnr, then_)) then
    then_()
  end
end

--- The popup to show for `target`, as a function, or nil when the target is
--- not one the popup covers: a trivial target, a variable, true/false/nil, or a
--- name this buffer declares (decl_line and kind known).
--- @param target DevDocsTarget
--- @return fun()|nil
local function note_for(target)
  local class = target.class
  local covered = class == "trivial"
    or class == "variable"
    or (class == "builtin" and (target.kind == "boolean" or target.kind == "nil"))
    or (HOVER_UNLESS_EXACT[class] and target.decl_line ~= nil and target.kind ~= nil)
  if not covered then
    return nil
  end
  return function()
    explain.show(target)
  end
end

--- The doc half of a lookup: rank `cands` over the buffer's docs and open
--- the hit, the picker, or the fallback. Without an exact entry for the name
--- (only fuzzy, suffix or bare-word matches, or none) a doc-first class shows
--- hover instead; an empty hover goes on to those hits. With a `note` the
--- popup replaces those hits, the fallback and the "no docs installed" notice.
--- @param class DevDocsTokenClass|nil nil: never hover
--- @param note fun()|nil
local function lookup_docs(mode, bufnr, cands, class, note)
  local bufdocs = detect.buffer(bufnr)
  local order, tiers = detect.lookup_order(bufnr)
  local sources = index.sources(order, tiers)
  if #sources == 0 then
    hover_or(class, bufnr, note or function()
      no_docs(bufdocs)
    end)
    return
  end
  local hits = rank.lookup(cands, sources, { limit = 25 })
  local function open(hit)
    viewer.open { slug = hit.slug, path = hit.entry.path, entry = hit.entry, mode = mode }
  end
  local function show()
    if #hits == 0 then
      fallback(cands, bufdocs)
    elseif rank.decisive(hits) then
      open(hits[1])
    else
      picker.pick_hits(hits, ("DevDocs: %s"):format(cands[1]), open)
    end
  end
  if rank.exact(hits, cands) then
    show()
  else
    hover_or(class, bufnr, note or show)
  end
end

--- @param mode "section"|"examples"|"page"
--- @param opts { text?: string, bufnr?: integer }|nil
function M.run(mode, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local text = opts.text or M.visual_text()
  -- An explicit selection or argument is a request for the docs; only the
  -- cursor's own word is second-guessed. Without lookup.explain that needs a
  -- client that can hover (without it every class ends at the docs, so
  -- classifying is wasted); with it the popup needs no client.
  local explicit = text ~= nil and text ~= ""
  local lcfg = config.get().lookup
  local explain_on = not explicit and lcfg.smart and lcfg.explain
  local smart = not explicit and lcfg.smart and (explain_on or M.can_hover(bufnr))
  local target = smart and classify.target(bufnr) or nil
  local class = target and target.class or nil
  local note = explain_on and target and note_for(target) or nil
  if class == "trivial" then
    if note then
      note()
      return
    end
    class = "unknown" -- lookup.explain = false: the old behaviour
  end
  local cands = symbols.candidates(bufnr, { text = text })
  if #cands == 0 then
    notify("nothing under the cursor to look up", vim.log.levels.WARN)
    return
  end
  local function docs()
    lookup_docs(mode, bufnr, cands, class, note)
  end
  if class == "variable" then
    if try_hover(bufnr, note or docs) then
      return
    end
    if note then
      note()
      return
    end
  end
  docs()
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
