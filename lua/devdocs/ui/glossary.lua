--- Glossary: the index of one doc as a tree (doc row, its types, their
--- entries), like devdocs.io's sidebar. Pure: build() groups a doc's
--- entries, rows() flattens the tree for a state (what is expanded, the
--- filter) and reduce() applies one key's action to a state and cursor. The
--- viewer shows it (mode "index"); glossary_render.lua draws the rows.
local paths = require "devdocs.paths"

local M = {}

M.OTHER = "Other"

--- @class DevDocsGlossaryGroup
--- @field name string
--- @field entries DevDocsEntry[]
--- @field lower string[]  lowercased entry names, index-aligned with entries

--- @class DevDocsGlossary
--- @field slug string
--- @field name string
--- @field version string
--- @field groups DevDocsGlossaryGroup[]
--- @field flat boolean   at most one type: the entries sit under the doc row
--- @field total integer

--- @class DevDocsGlossaryState
--- @field expanded table<string, boolean>  type name -> shown open
--- @field doc_open boolean
--- @field filter string

--- @class DevDocsGlossaryRow
--- @field kind "doc"|"group"|"entry"
--- @field group integer|nil   index into tree.groups
--- @field entry DevDocsEntry|nil
--- @field ei integer|nil      index of the entry in its group
--- @field depth integer       0 doc, 1 type (or entry of a flat doc), 2 entry
--- @field count integer       entries shown below (matches when filtering)
--- @field total integer       entries below
--- @field expanded boolean|nil

--- The tree of a doc: types in meta.types order (entry types meta does not
--- list follow in first-seen order, the untyped entries last as "Other"),
--- a type meta lists stays even when it has no entries.
--- @param slug string
--- @param meta table|nil meta.json
--- @param entries DevDocsEntry[]
--- @return DevDocsGlossary
function M.build(slug, meta, entries)
  meta = meta or {}
  local by_name, groups = {}, {}
  local function group(name)
    local g = by_name[name]
    if not g then
      g = { name = name, entries = {}, lower = {} }
      by_name[name] = g
      groups[#groups + 1] = g
    end
    return g
  end
  for _, t in ipairs(meta.types or {}) do
    if t.name and t.name ~= "" and t.name ~= M.OTHER then
      group(t.name)
    end
  end
  for _, e in ipairs(entries) do
    local g = group(e.type ~= "" and e.type or M.OTHER)
    g.entries[#g.entries + 1] = e
    g.lower[#g.lower + 1] = e.name:lower()
  end
  -- "Other" (the untyped entries) goes last
  local out, other = {}, nil
  for _, g in ipairs(groups) do
    if g.name == M.OTHER then
      other = g
    else
      out[#out + 1] = g
    end
  end
  out[#out + 1] = other
  local version = meta.release
  if not version or version == "" then
    version = meta.doc_version or ""
  end
  return {
    slug = slug,
    name = meta.name or slug,
    version = version,
    groups = out,
    flat = #out <= 1,
    total = #entries,
  }
end

--- A fresh state: the doc row open, every type closed, no filter.
--- @param opts { expanded?: table<string, boolean>, doc_open?: boolean, filter?: string }|nil
--- @return DevDocsGlossaryState
function M.new(opts)
  opts = opts or {}
  return {
    expanded = opts.expanded or {},
    doc_open = opts.doc_open ~= false,
    filter = opts.filter or "",
  }
end

--- The entries of a group that match the (lowercased) filter, as indexes.
local function matches(g, f)
  local out = {}
  for i, name in ipairs(g.lower) do
    if name:find(f, 1, true) then
      out[#out + 1] = i
    end
  end
  return out
end

--- The visible rows: the doc row, then (when it is open) its types, each
--- followed by its entries when open. A filter keeps entries whose name
--- contains it (case-insensitive, plain), hides types without a match and
--- shows the rest open with their match count. A flat doc lists its
--- entries under the doc row.
--- @param tree DevDocsGlossary
--- @param state DevDocsGlossaryState
--- @return DevDocsGlossaryRow[]
function M.rows(tree, state)
  local f = state.filter:lower()
  local filtering = f ~= ""
  local rows = {}
  local shown = 0
  local body = {}
  for gi, g in ipairs(tree.groups) do
    local idx = filtering and matches(g, f) or nil
    local n = idx and #idx or #g.entries
    if n > 0 or not filtering then
      shown = shown + n
      local open = filtering or state.expanded[g.name] == true
      if not tree.flat then
        body[#body + 1] = {
          kind = "group",
          group = gi,
          depth = 1,
          count = n,
          total = #g.entries,
          expanded = open,
        }
      end
      if open or tree.flat then
        for k = 1, n do
          local ei = idx and idx[k] or k
          body[#body + 1] = {
            kind = "entry",
            group = gi,
            entry = g.entries[ei],
            ei = ei,
            depth = tree.flat and 1 or 2,
            count = 0,
            total = 0,
          }
        end
      end
    end
  end
  local doc_open = state.doc_open or filtering
  rows[1] = { kind = "doc", depth = 0, count = shown, total = tree.total, expanded = doc_open }
  if doc_open then
    for _, r in ipairs(body) do
      rows[#rows + 1] = r
    end
  end
  return rows
end

--- The entry of a row, nil for the doc and type rows.
--- @param row DevDocsGlossaryRow|nil
--- @return DevDocsEntry|nil
function M.target(row)
  return row and row.kind == "entry" and row.entry or nil
end

--- Where a page is in the tree: the entry with exactly this path (the one
--- named `name` when several share it), else the first entry on the same
--- page (a path differing only in its fragment).
--- @param tree DevDocsGlossary
--- @param path string
--- @param name string|nil
--- @return integer|nil group, integer|nil entry
function M.find(tree, path, name)
  local page = paths.split_fragment(path)
  local exact, same_page
  for gi, g in ipairs(tree.groups) do
    for ei, e in ipairs(g.entries) do
      if e.path == path then
        if name == nil or e.name == name then
          return gi, ei
        end
        exact = exact or { gi, ei }
      elseif not same_page and e.path:sub(1, #page) == page and paths.split_fragment(e.path) == page then
        same_page = { gi, ei }
      end
    end
  end
  local hit = exact or same_page
  if hit then
    return hit[1], hit[2]
  end
  return nil
end

--- The row index of an item in `rows`, falling back to its type, then the doc.
local function locate(rows, kind, gi, ei)
  local fallback
  for i, r in ipairs(rows) do
    if kind == "doc" then
      return 1
    end
    if r.group == gi then
      if r.kind == kind and (kind == "group" or r.ei == ei) then
        return i
      end
      if r.kind == "group" then
        fallback = i
      end
    end
  end
  return fallback or 1
end

local function copy(state, fields)
  local s = { expanded = state.expanded, doc_open = state.doc_open, filter = state.filter }
  for k, v in pairs(fields) do
    s[k] = v
  end
  return s
end

local function with_expanded(state, name, value)
  local e = {}
  for k, v in pairs(state.expanded) do
    e[k] = v
  end
  e[name] = value
  return e
end

local function clamp(cursor, rows)
  return math.max(1, math.min(cursor, #rows))
end

--- Open the doc and one type, clearing a filter that hides the entry.
--- Returns the new state and the row of the entry (1 when it is not in the
--- tree).
--- @param tree DevDocsGlossary
--- @param state DevDocsGlossaryState
--- @param path string
--- @param name string|nil
--- @return DevDocsGlossaryState state, integer row
function M.reveal(tree, state, path, name)
  local gi, ei = M.find(tree, path, name)
  if not gi then
    return state, 1
  end
  local g = tree.groups[gi]
  local fields = { doc_open = true, expanded = with_expanded(state, g.name, true) }
  if state.filter ~= "" and not g.lower[ei]:find(state.filter:lower(), 1, true) then
    fields.filter = ""
  end
  local s = copy(state, fields)
  return s, locate(M.rows(tree, s), "entry", gi, ei)
end

--- Apply one action to a state and cursor row (neither is changed). Actions
--- ({ type = ... }): toggle (<Tab>, and <CR> on a type or the doc), expand
--- (l: open a closed type or doc, else step into it), collapse (h: fold the
--- type of an entry; an open type or doc closes; a closed type goes to the
--- doc row), expand_all (zR), collapse_all (zM), filter ({ text }, the
--- cursor on its first entry), next_group / prev_group (} and {, staying at
--- the edges). The cursor is kept on what it was on where that still shows.
--- @param tree DevDocsGlossary
--- @param state DevDocsGlossaryState
--- @param cursor integer
--- @param action { type: string, text?: string }
--- @return DevDocsGlossaryState state, integer cursor
function M.reduce(tree, state, cursor, action)
  local rows = M.rows(tree, state)
  cursor = clamp(cursor, rows)
  local row = rows[cursor]
  local kind, gi, ei = row.kind, row.group, row.ei
  local function after(s, k, g, e)
    local r = M.rows(tree, s)
    return s, locate(r, k or kind, g or gi, e or ei)
  end
  local t = action.type
  if t == "toggle" or t == "expand" or t == "collapse" then
    if kind == "doc" then
      if t == "expand" and state.doc_open then
        return state, clamp(2, rows)
      end
      local open = t == "toggle" and not state.doc_open or t == "expand"
      return after(copy(state, { doc_open = open }), "doc")
    end
    local g = tree.groups[gi]
    if kind == "group" then
      local open = state.expanded[g.name] == true
      if t == "expand" and open then
        return state, clamp(cursor + 1, rows)
      elseif t == "collapse" and not open then
        return state, 1
      end
      local value = t == "toggle" and not open or t == "expand"
      return after(copy(state, { expanded = with_expanded(state, g.name, value) }), "group", gi)
    end
    -- an entry: only h acts, folding its type (or the doc when flat)
    if t == "collapse" then
      if tree.flat then
        return after(copy(state, { doc_open = false }), "doc")
      end
      return after(copy(state, { expanded = with_expanded(state, g.name, false) }), "group", gi)
    end
    return state, cursor
  elseif t == "expand_all" or t == "collapse_all" then
    local expanded = {}
    if t == "expand_all" then
      for _, g in ipairs(tree.groups) do
        expanded[g.name] = true
      end
    end
    local s = copy(state, { expanded = expanded, doc_open = true })
    if t == "collapse_all" and kind == "entry" then
      return after(s, "group", gi)
    end
    return after(s)
  elseif t == "filter" then
    local s = copy(state, { filter = action.text or "", doc_open = true })
    local r = M.rows(tree, s)
    if s.filter ~= "" then
      for i, x in ipairs(r) do
        if x.kind == "entry" then
          return s, i
        end
      end
      return s, 1
    end
    return after(s)
  elseif t == "next_group" then
    for i = cursor + 1, #rows do
      if rows[i].kind == "group" then
        return state, i
      end
    end
    return state, cursor
  elseif t == "prev_group" then
    for i = cursor - 1, 1, -1 do
      if rows[i].kind == "group" then
        return state, i
      end
    end
    return state, cursor
  end
  return state, cursor
end

return M
