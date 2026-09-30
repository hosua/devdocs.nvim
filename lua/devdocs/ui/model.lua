--- List manager model: state, derived rows and the reducer. Pure, so the
--- grouping, filtering, sorting, expansion and cursor/scroll rules are all
--- unit-tested on tables. ui/render.lua turns a state into lines, and
--- ui/list.lua is the only part that touches a window.
local manifest = require "devdocs.manifest"

local M = {}

--- @class DevDocsListState
--- @field docs DevDocsDoc[]            manifest
--- @field installed table<string, table> slug -> meta
--- @field jobs table<string, DevDocsJob>
--- @field disabled table<string, boolean>
--- @field filter string
--- @field sort "name"|"size"
--- @field expanded table<string, boolean>  base -> true
--- @field cursor integer   1-based index into rows()
--- @field top integer      first visible row
--- @field height integer   visible rows
--- @field width integer
--- @field loading boolean
--- @field error string|nil
--- @field fetched_at integer|nil

--- @class DevDocsListRow
--- @field kind "group"|"doc"
--- @field label string|nil       group rows
--- @field count integer|nil      group rows
--- @field slug string|nil        doc rows
--- @field base string|nil
--- @field doc DevDocsDoc|nil
--- @field meta table|nil
--- @field job DevDocsJob|nil
--- @field status "installing"|"error"|"installed"|"outdated"|"available"|"disabled"|nil
--- @field versions integer|nil   collapsed base rows: how many versions are hidden
--- @field expanded boolean|nil

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

local function sorter(state)
  if state.sort == "size" then
    return function(a, b)
      local sa, sb = (a.doc and a.doc.db_size) or 0, (b.doc and b.doc.db_size) or 0
      if sa ~= sb then
        return sa > sb
      end
      return a.slug < b.slug
    end
  end
  return function(a, b)
    local na, nb = (a.doc and a.doc.name or a.slug):lower(), (b.doc and b.doc.name or b.slug):lower()
    if na ~= nb then
      return na < nb
    end
    return manifest.compare_versions((a.doc and a.doc.version) or "", (b.doc and b.doc.version) or "") > 0
  end
end

--- The rows to display for a state: group headers and doc rows.
--- @param state DevDocsListState
--- @return DevDocsListRow[]
function M.rows(state)
  local by_slug = manifest.by_slug(state.docs)
  local seen = {}
  local groups = { installing = {}, installed = {}, outdated = {}, available = {} }

  local function doc_row(slug, doc)
    local meta = state.installed[slug]
    return {
      kind = "doc",
      slug = slug,
      base = manifest.base(slug),
      doc = doc
        or (
          meta
          and { slug = slug, name = meta.name or slug, version = meta.doc_version or "", db_size = meta.db_size or 0 }
        ),
      meta = meta,
      job = state.jobs[slug],
      status = M.status(state, slug, doc),
    }
  end

  -- installed (and running/failed jobs) are listed per slug
  local per_slug = {}
  for slug in pairs(state.installed) do
    per_slug[slug] = true
  end
  for slug in pairs(state.jobs) do
    per_slug[slug] = true
  end
  for slug in pairs(per_slug) do
    local doc = by_slug[slug]
    if matches(state.filter, doc or { slug = slug, name = (state.installed[slug] or {}).name or slug }) then
      local row = doc_row(slug, doc)
      seen[slug] = true
      if row.status == "installing" or row.status == "error" then
        groups.installing[#groups.installing + 1] = row
      elseif row.status == "outdated" then
        groups.outdated[#groups.outdated + 1] = row
      else
        groups.installed[#groups.installed + 1] = row
      end
    end
  end

  -- available: one row per base (newest not-installed version), expandable
  local bases = {}
  local order = {}
  for _, doc in ipairs(state.docs) do
    if not seen[doc.slug] and matches(state.filter, doc) then
      local base = manifest.base(doc.slug)
      if not bases[base] then
        bases[base] = {}
        order[#order + 1] = base
      end
      table.insert(bases[base], doc)
    end
  end
  for _, base in ipairs(order) do
    local versions = manifest.sort_newest(bases[base])
    if state.expanded[base] or state.filter:find("~", 1, true) then
      for _, doc in ipairs(versions) do
        local row = doc_row(doc.slug, doc)
        row.expanded = true
        groups.available[#groups.available + 1] = row
      end
    else
      local row = doc_row(versions[1].slug, versions[1])
      row.versions = #versions
      groups.available[#groups.available + 1] = row
    end
  end

  local out = {}
  local function add_group(label, rows)
    if #rows == 0 then
      return
    end
    table.sort(rows, sorter(state))
    out[#out + 1] = { kind = "group", label = label, count = #rows }
    for _, r in ipairs(rows) do
      out[#out + 1] = r
    end
  end
  add_group("Installing", groups.installing)
  add_group("Outdated", groups.outdated)
  add_group("Installed", groups.installed)
  add_group("Available", groups.available)
  return out
end

--- Counts for the header line.
--- @param state DevDocsListState
--- @return { installed: integer, installing: integer, outdated: integer, available: integer }
function M.counts(state)
  local c = { installed = 0, installing = 0, outdated = 0, available = 0 }
  local by_slug = manifest.by_slug(state.docs)
  for slug in pairs(state.installed) do
    local s = M.status(state, slug, by_slug[slug])
    if s == "installing" then
      c.installing = c.installing + 1
    elseif s == "outdated" then
      c.outdated = c.outdated + 1
    else
      c.installed = c.installed + 1
    end
  end
  for slug, job in pairs(state.jobs) do
    if not state.installed[slug] and job_active(job) then
      c.installing = c.installing + 1
    end
  end
  local bases = {}
  for _, d in ipairs(state.docs) do
    if not state.installed[d.slug] then
      bases[manifest.base(d.slug)] = true
    end
  end
  c.available = vim.tbl_count(bases)
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

--- @param state DevDocsListState
--- @param action table { type = ..., ... }
--- @return DevDocsListState
function M.reduce(state, action)
  local t = action.type
  if t == "data" then
    local s = vim.tbl_extend("force", vim.deepcopy(state), action.data)
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
  elseif t == "toggle_expand" then
    local row = rows[state.cursor]
    if not row or row.kind ~= "doc" or row.status ~= "available" then
      return state
    end
    local s = vim.deepcopy(state)
    s.expanded[row.base] = not s.expanded[row.base] or nil
    -- keep the cursor on the same base after the rows shift
    local new_rows = M.rows(s)
    for i, r in ipairs(new_rows) do
      if r.kind == "doc" and r.base == row.base and r.status == "available" then
        s.cursor = i
        break
      end
    end
    return clamp(s, new_rows)
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
  end
  return state
end

--- The doc row under the cursor, or nil on a header / empty list.
--- @param state DevDocsListState
--- @return DevDocsListRow|nil
function M.current(state)
  local row = M.rows(state)[state.cursor]
  if row and row.kind == "doc" then
    return row
  end
  return nil
end

return M
