--- List manager model: state, derived rows and the reducer. Pure, so the
--- grouping, filtering, sorting, expansion and cursor/scroll rules are all
--- unit-tested on tables. ui/render.lua turns a state into lines, and
--- ui/list.lua is the only part that touches a window.
local manifest = require "devdocs.manifest"
local selection = require "devdocs.ui.selection"

local M = {}

--- @class DevDocsListState
--- @field docs DevDocsDoc[]            manifest
--- @field installed table<string, table> slug -> meta
--- @field jobs table<string, DevDocsJob>
--- @field disabled table<string, boolean>
--- @field filter string
--- @field sort "name"|"size"
--- @field expanded table<string, boolean>  base -> true
--- @field marked table<string, boolean>    slug -> true (selection)
--- @field release_dates table<string, { date: string, exact: boolean }>  slug -> release date
--- @field cursor integer   1-based index into rows()
--- @field top integer      first visible row
--- @field height integer   visible rows
--- @field width integer
--- @field loading boolean
--- @field error string|nil
--- @field fetched_at integer|nil

--- @class DevDocsListRow
--- @field kind "group"|"lang"|"doc"
--- @field label string|nil       group: "Installed" / "Available"
--- @field count integer|nil      group: languages in the section
--- @field base string|nil        lang/doc: "python"
--- @field name string|nil        lang: display name ("Python")
--- @field children DevDocsListRow[]|nil  lang: every version, newest first
--- @field visible DevDocsListRow[]|nil   lang: the children that pass the filter (all without one)
--- @field expanded boolean|nil   lang: versions shown below it (false when there is only one)
--- @field installed_count integer|nil  lang
--- @field installed_size integer|nil   lang: sum of the installed versions' db_size
--- @field size_hint integer|nil  lang: db_size of the newest version
--- @field slug string|nil        doc
--- @field doc DevDocsDoc|nil     doc
--- @field meta table|nil         doc: installed meta.json
--- @field job DevDocsJob|nil     doc
--- @field depth integer|nil      doc: 1 (a version under its language)
--- @field current boolean|nil    doc: the unversioned slug, DevDocs' rolling "current"
--- @field status "installing"|"error"|"installed"|"outdated"|"available"|"disabled"|nil

--- @param opts table|nil
--- @return DevDocsListState
function M.new(opts)
  local s = vim.tbl_extend("force", {
    docs = {},
    installed = {},
    jobs = {},
    disabled = {},
    filter = "",
    sort = "name",
    expanded = {},
    marked = {},
    release_dates = {},
    cursor = 1,
    top = 1,
    height = 20,
    width = 80,
    loading = false,
    error = nil,
    fetched_at = nil,
  }, opts or {})
  -- start on the first doc row, not the group header
  return M.reduce(s, { type = "data", data = {} })
end

local function matches(filter, doc)
  if filter == "" then
    return true
  end
  local f = filter:lower()
  return doc.slug:lower():find(f, 1, true) ~= nil
    or doc.name:lower():find(f, 1, true) ~= nil
    or (doc.alias and doc.alias:lower():find(f, 1, true) ~= nil)
end

local function job_active(job)
  return job and job.stage ~= "done" and job.stage ~= "error"
end

--- Status of one slug given the state.
--- @param state DevDocsListState
--- @param slug string
--- @param doc DevDocsDoc|nil
--- @return string
function M.status(state, slug, doc)
  local job = state.jobs[slug]
  if job_active(job) then
    return "installing"
  end
  if job and job.stage == "error" and not state.installed[slug] then
    return "error"
  end
  local meta = state.installed[slug]
  if meta then
    if state.disabled[slug] then
      return "disabled"
    end
    if doc and require("devdocs.installer").is_outdated(meta, doc) then
      return "outdated"
    end
    return "installed"
  end
  return "available"
end

--- What a language weighs for the size sort: what it takes on disk once
--- anything is installed, else what installing the newest version would take.
local function lang_size(lang)
  if lang.installed_count > 0 then
    return lang.installed_size
  end
  return lang.size_hint
end

local function sorter(state)
  if state.sort == "size" then
    return function(a, b)
      local sa, sb = lang_size(a.lang), lang_size(b.lang)
      if sa ~= sb then
        return sa > sb
      end
      return a.lang.base < b.lang.base
    end
  end
  return function(a, b)
    local na, nb = a.lang.name:lower(), b.lang.name:lower()
    if na ~= nb then
      return na < nb
    end
    return a.lang.base < b.lang.base
  end
end

--- A manifest-shaped doc for a slug the manifest does not list (installed
--- from an older manifest, or a job for a slug it dropped).
local function synthetic_doc(slug, meta)
  return {
    slug = slug,
    name = meta.name or slug,
    version = meta.doc_version or (slug:match "~(.+)$" or ""),
    release = meta.release or "",
    db_size = meta.db_size or 0,
    mtime = meta.mtime or 0,
  }
end

local AGGREGATE_RANK = { installing = 1, error = 2, outdated = 3, installed = 4 }

--- installing > error > outdated > installed > disabled (every install off) > available
--- @param children DevDocsListRow[]
--- @return string
local function aggregate(children)
  local best, disabled
  for _, c in ipairs(children) do
    local rank = AGGREGATE_RANK[c.status]
    if rank and (not best or rank < AGGREGATE_RANK[best]) then
      best = c.status
    end
    disabled = disabled or c.status == "disabled"
  end
  return best or (disabled and "disabled") or "available"
end

local function newest_first(a, b)
  local c = manifest.compare_versions(a.doc.version or "", b.doc.version or "")
  if c ~= 0 then
    return c > 0
  end
  return a.slug < b.slug
end

--- Every language, unfiltered and unsorted, as lang rows (expanded = false).
--- Versions come from the manifest plus installed docs and jobs it lacks.
--- @param state DevDocsListState
--- @return DevDocsListRow[]
local function languages(state)
  local by_base, order, seen = {}, {}, {}
  local function add(slug, doc)
    local b = manifest.base(slug)
    if not by_base[b] then
      by_base[b] = {}
      order[#order + 1] = b
    end
    table.insert(by_base[b], {
      kind = "doc",
      slug = slug,
      base = b,
      doc = doc,
      meta = state.installed[slug],
      job = state.jobs[slug],
      status = M.status(state, slug, doc),
      depth = 1,
      current = slug == b,
    })
  end
  for _, doc in ipairs(state.docs) do
    if not seen[doc.slug] then
      seen[doc.slug] = true
      add(doc.slug, doc)
    end
  end
  local extra = {}
  for slug in pairs(state.installed) do
    extra[slug] = not seen[slug] or nil
  end
  for slug in pairs(state.jobs) do
    extra[slug] = not seen[slug] or nil
  end
  local extra_slugs = vim.tbl_keys(extra)
  table.sort(extra_slugs)
  for _, slug in ipairs(extra_slugs) do
    add(slug, synthetic_doc(slug, state.installed[slug] or {}))
  end

  local out = {}
  for _, b in ipairs(order) do
    local children = by_base[b]
    table.sort(children, newest_first)
    local count, size = 0, 0
    for _, c in ipairs(children) do
      if c.meta then
        count = count + 1
        size = size + (c.meta.db_size or c.doc.db_size or 0)
      end
    end
    out[#out + 1] = {
      kind = "lang",
      base = b,
      name = children[1].doc.name or b,
      children = children,
      expanded = false,
      status = aggregate(children),
      installed_count = count,
      installed_size = size,
      size_hint = children[1].doc.db_size or 0,
    }
  end
  return out
end

--- The rows to display: section headers, one row per language and, under
--- an expanded language, one row per version.
--- @param state DevDocsListState
--- @return DevDocsListRow[]
function M.rows(state)
  local tilde = state.filter:find("~", 1, true) ~= nil
  local sections = { installed = {}, available = {} }
  for _, lang in ipairs(languages(state)) do
    local visible = vim.tbl_filter(function(c)
      return matches(state.filter, c.doc)
    end, lang.children)
    if #visible > 0 then
      lang.visible = visible
      lang.expanded = #lang.children > 1 and (state.expanded[lang.base] == true or tilde)
      local section = lang.status == "available" and sections.available or sections.installed
      section[#section + 1] = { lang = lang, visible = visible }
    end
  end

  local out = {}
  local function add_section(label, entries)
    if #entries == 0 then
      return
    end
    table.sort(entries, sorter(state))
    out[#out + 1] = { kind = "group", label = label, count = #entries }
    for _, e in ipairs(entries) do
      out[#out + 1] = e.lang
      if e.lang.expanded then
        vim.list_extend(out, e.lang.visible)
      end
    end
  end
  add_section("Installed", sections.installed)
  add_section("Available", sections.available)
  return out
end

--- The version row an action on `row` should use: a version row itself; for
--- a language, its installed current version (else the newest installed
--- one), else a version with a running or failed job, else the newest.
--- @param row DevDocsListRow|nil
--- @return DevDocsListRow|nil
function M.target(row)
  if not row or row.kind == "group" then
    return nil
  elseif row.kind == "doc" then
    return row
  end
  local installed, busy
  for _, c in ipairs(row.children) do
    if c.meta then
      if c.current then
        return c
      end
      installed = installed or c
    elseif c.status == "installing" or c.status == "error" then
      busy = busy or c
    end
  end
  return installed or busy or row.children[1]
end

--- Counts for the header: languages with / without an installed version,
--- plus versions installing and outdated.
--- @param state DevDocsListState
--- @return { installed: integer, installing: integer, outdated: integer, available: integer }
function M.counts(state)
  local c = { installed = 0, installing = 0, outdated = 0, available = 0 }
  for _, lang in ipairs(languages(state)) do
    if lang.installed_count > 0 then
      c.installed = c.installed + 1
    else
      c.available = c.available + 1
    end
    for _, v in ipairs(lang.children) do
      if v.status == "installing" then
        c.installing = c.installing + 1
      elseif v.status == "outdated" then
        c.outdated = c.outdated + 1
      end
    end
  end
  return c
end

local function clamp(state, rows)
  local n = #rows
  local s = vim.deepcopy(state)
  if n == 0 then
    s.cursor, s.top = 1, 1
    return s
  end
  s.cursor = math.max(1, math.min(s.cursor, n))
  -- never rest on a group header when a doc row is adjacent
  if rows[s.cursor].kind == "group" then
    if s.cursor < n then
      s.cursor = s.cursor + 1
    elseif s.cursor > 1 then
      s.cursor = s.cursor - 1
    end
  end
  local h = math.max(1, s.height)
  if s.cursor < s.top then
    s.top = s.cursor
  elseif s.cursor >= s.top + h then
    s.top = s.cursor - h + 1
  end
  -- keep the group header of the first visible doc row on screen
  if s.top == s.cursor and s.cursor > 1 and rows[s.cursor - 1].kind == "group" then
    s.top = s.cursor - 1
  end
  s.top = math.max(1, math.min(s.top, math.max(1, n - h + 1)))
  return s
end

--- Move the cursor by `delta` doc rows, skipping group headers.
local function move(state, rows, delta)
  local s = vim.deepcopy(state)
  local i, step = s.cursor, delta > 0 and 1 or -1
  for _ = 1, math.abs(delta) do
    local j = i + step
    while rows[j] and rows[j].kind == "group" do
      j = j + step
    end
    if not rows[j] then
      break
    end
    i = j
  end
  s.cursor = i
  return clamp(s, rows)
end

local function lang_index(rows, base)
  for i, r in ipairs(rows) do
    if r.kind == "lang" and r.base == base then
      return i
    end
  end
end

--- Expand / collapse / toggle the language under the cursor. On a version
--- row, toggle and collapse fold its language and move the cursor onto it.
local function set_expanded(state, rows, how)
  local row = rows[state.cursor]
  if not row or row.kind == "group" or (row.kind == "doc" and how == "expand") then
    return state
  end
  local lang = row.kind == "lang" and row or rows[lang_index(rows, row.base) or 0]
  if not lang or #lang.children < 2 then
    return state
  end
  local open = lang.expanded -- also true while a "~" filter forces it
  local want = false
  if row.kind == "lang" then
    want = how == "expand" or (how == "toggle_expand" and not open)
    if want == open then
      return state
    end
  end
  local s = vim.deepcopy(state)
  s.expanded[lang.base] = want or nil
  local new_rows = M.rows(s)
  local at = lang_index(new_rows, lang.base)
  s.cursor = at or s.cursor
  if want and at then
    -- scroll so the versions just shown are on screen (as many as fit
    -- below the language row, which stays visible)
    local last = at
    while new_rows[last + 1] and new_rows[last + 1].kind == "doc" do
      last = last + 1
    end
    local h = math.max(1, s.height)
    if last > s.top + h - 1 then
      s.top = math.min(at, last - h + 1)
    end
  end
  return clamp(s, new_rows)
end

--- @param state DevDocsListState
--- @param action table { type = ..., ... }
--- @return DevDocsListState
function M.reduce(state, action)
  local t = action.type
  if t == "data" then
    local s = vim.tbl_extend("force", vim.deepcopy(state), action.data)
    if s.marked then
      s.marked = selection.cleanup(s.marked, s.installed)
    end
    return clamp(s, M.rows(s))
  end
  local rows = M.rows(state)
  if t == "move" then
    return move(state, rows, action.n)
  elseif t == "page" then
    return move(state, rows, action.n * math.max(1, state.height - 1))
  elseif t == "top" then
    return clamp(vim.tbl_extend("force", vim.deepcopy(state), { cursor = 1 }), rows)
  elseif t == "bottom" then
    return clamp(vim.tbl_extend("force", vim.deepcopy(state), { cursor = #rows }), rows)
  elseif t == "goto" then
    return clamp(vim.tbl_extend("force", vim.deepcopy(state), { cursor = action.row }), rows)
  elseif t == "toggle_expand" or t == "expand" or t == "collapse" then
    return set_expanded(state, rows, t)
  elseif t == "filter" then
    local s = vim.tbl_extend("force", vim.deepcopy(state), { filter = action.text or "", cursor = 1, top = 1 })
    return clamp(s, M.rows(s))
  elseif t == "sort" then
    local s = vim.tbl_extend("force", vim.deepcopy(state), { sort = state.sort == "name" and "size" or "name" })
    return clamp(s, M.rows(s))
  elseif t == "resize" then
    local s = vim.tbl_extend("force", vim.deepcopy(state), { height = action.height, width = action.width })
    return clamp(s, rows)
  elseif t == "next_group" or t == "prev_group" then
    local s = vim.deepcopy(state)
    local step = t == "next_group" and 1 or -1
    local i = s.cursor + step
    -- going up, the header right above the cursor is this group's: skip it
    if step < 0 and rows[i] and rows[i].kind == "group" then
      i = i + step
    end
    while rows[i] and rows[i].kind ~= "group" do
      i = i + step
    end
    if rows[i] then
      s.cursor = i + 1
      return clamp(s, rows)
    end
    return state
  elseif t == "mark" then
    -- netrw/oil style: toggle the row under the cursor, then step down
    local s = vim.deepcopy(state)
    s.marked = selection.toggle(state.marked or {}, rows[state.cursor])
    return move(s, rows, 1)
  elseif t == "mark_range" then
    local s = vim.deepcopy(state)
    s.marked = selection.mark_range(state.marked or {}, rows, action.from, action.to)
    return s
  elseif t == "release_dates" then
    -- merge: an older, smaller answer never drops dates already known
    local s = vim.deepcopy(state)
    s.release_dates = vim.tbl_extend("force", s.release_dates or {}, vim.deepcopy(action.dates or {}))
    return s
  elseif t == "unmark_all" then
    return vim.tbl_extend("force", vim.deepcopy(state), { marked = {} })
  elseif t == "marked_cleanup" then
    return vim.tbl_extend("force", vim.deepcopy(state), { marked = selection.cleanup(state.marked, state.installed) })
  end
  return state
end

--- The language or version row under the cursor, or nil on a header /
--- empty list. model.target() turns it into the version to act on.
--- @param state DevDocsListState
--- @return DevDocsListRow|nil
function M.current(state)
  local row = M.rows(state)[state.cursor]
  if row and row.kind ~= "group" then
    return row
  end
  return nil
end

return M
