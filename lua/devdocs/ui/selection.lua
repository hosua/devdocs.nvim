--- Bulk selection for the list manager: marks (slug -> true), visual ranges
--- and the "keep only the current version" prune rule. Pure functions over
--- plain tables; every function returns a new table and never mutates its
--- input. ui/model.lua's reducer delegates here, ui/list.lua runs the deletes.
local manifest = require "devdocs.manifest"

local M = {}

local function copy(marked)
  local out = {}
  for slug, on in pairs(marked or {}) do
    if on then
      out[slug] = true
    end
  end
  return out
end

--- Installed slugs a row stands for: a doc row its own slug, a lang row its
--- installed children; nothing for group rows and docs that are not installed.
--- @param row table|nil
--- @return string[]
function M.row_slugs(row)
  if not row then
    return {}
  end
  if row.kind == "doc" then
    return row.meta and { row.slug } or {}
  end
  if row.kind == "lang" then
    local out = {}
    for _, c in ipairs(row.children or {}) do
      if c.kind == "doc" and c.meta then
        out[#out + 1] = c.slug
      end
    end
    return out
  end
  return {}
end

-- Mark every slug, or unmark them all when every one is already marked.
local function flip(marked, slugs)
  local out = copy(marked)
  if #slugs == 0 then
    return out
  end
  local all = true
  for _, s in ipairs(slugs) do
    if not out[s] then
      all = false
      break
    end
  end
  for _, s in ipairs(slugs) do
    out[s] = (not all) or nil
  end
  return out
end

--- Toggle the mark of one row. A lang row marks all of its installed
--- versions, or unmarks them when they are all marked already.
--- @param marked table<string, boolean>|nil
--- @param row table|nil
--- @return table<string, boolean>
function M.toggle(marked, row)
  return flip(marked, M.row_slugs(row))
end

--- Installed slugs in rows[from..to] (either order, clamped), sorted.
--- @param rows table[]
--- @param from integer
--- @param to integer
--- @return string[]
function M.range_targets(rows, from, to)
  local lo, hi = math.min(from, to), math.max(from, to)
  lo, hi = math.max(1, lo), math.min(#rows, hi)
  local seen, out = {}, {}
  for i = lo, hi do
    for _, s in ipairs(M.row_slugs(rows[i])) do
      if not seen[s] then
        seen[s] = true
        out[#out + 1] = s
      end
    end
  end
  table.sort(out)
  return out
end

--- Mark every installed row in a range; unmark the range when it is all
--- marked already, so pressing `m` on the same selection twice undoes it.
--- @param marked table<string, boolean>|nil
--- @param rows table[]
--- @param from integer
--- @param to integer
--- @return table<string, boolean>
function M.mark_range(marked, rows, from, to)
  return flip(marked, M.range_targets(rows, from, to))
end

--- Marked slugs, sorted.
--- @param marked table<string, boolean>|nil
--- @return string[]
function M.targets(marked)
  local out = {}
  for slug, on in pairs(marked or {}) do
    if on then
      out[#out + 1] = slug
    end
  end
  table.sort(out)
  return out
end

--- @param marked table<string, boolean>|nil
--- @return integer
function M.count(marked)
  return #M.targets(marked)
end

--- Drop marks for slugs that are not installed any more.
--- @param marked table<string, boolean>|nil
--- @param installed table<string, table>
--- @return table<string, boolean>
function M.cleanup(marked, installed)
  local out = {}
  for slug, on in pairs(marked or {}) do
    if on and installed[slug] then
      out[slug] = true
    end
  end
  return out
end

local function as_set(bases)
  if bases == nil then
    return nil
  end
  if type(bases) == "string" then
    return { [bases] = true }
  end
  local set = {}
  for k, v in pairs(bases) do
    if type(k) == "number" then
      set[v] = true
    elseif v then
      set[k] = true
    end
  end
  return set
end

--- Installed versions to delete so that every language keeps exactly one:
--- the manifest's newest version of that base (the unversioned slug counts
--- as newest) when it is installed, else the newest installed version. A
--- base with one installed version is never touched, so pruning can not
--- remove a language. Disabled docs are installed docs here.
--- @param installed table<string, table>|nil slug -> meta
--- @param docs DevDocsDoc[]|nil manifest
--- @param bases string|string[]|table<string, boolean>|nil only these bases
--- @return string[] slugs to delete, sorted
function M.prune_targets(installed, docs, bases)
  local only = as_set(bases)
  local by_slug = manifest.by_slug(docs or {})

  local groups = {}
  for slug, meta in pairs(installed or {}) do
    local base = manifest.base(slug)
    if not only or only[base] then
      local d = by_slug[slug]
      local version = (d and d.version) or meta.doc_version or slug:match "~(.*)$" or ""
      groups[base] = groups[base] or {}
      table.insert(groups[base], { slug = slug, version = version })
    end
  end

  local current = {}
  for _, d in ipairs(docs or {}) do
    local base = manifest.base(d.slug)
    if groups[base] then
      current[base] = current[base] or {}
      table.insert(current[base], d)
    end
  end

  local out = {}
  for base, versions in pairs(groups) do
    if #versions > 1 then
      local keep
      local newest = current[base] and manifest.sort_newest(current[base])[1]
      if newest and installed[newest.slug] then
        keep = newest.slug
      else
        keep = manifest.sort_newest(versions)[1].slug
      end
      for _, v in ipairs(versions) do
        if v.slug ~= keep then
          out[#out + 1] = v.slug
        end
      end
    end
  end
  table.sort(out)
  return out
end

local function size(bytes)
  if bytes >= 1e9 then
    return ("%.1f GB"):format(bytes / 1e9)
  elseif bytes >= 1e6 then
    return ("%.1f MB"):format(bytes / 1e6)
  end
  return ("%d kB"):format(math.floor(bytes / 1e3))
end

--- The text of the one confirmation every bulk delete goes through: how
--- many, how much disk, where, and every slug (wrapped at 72 columns).
--- @param slugs string[]
--- @param bytes number|nil disk usage, nil when unknown
--- @param dir string the docs directory
--- @return string
function M.confirm_message(slugs, bytes, dir)
  local head = ("Delete %d doc%s"):format(#slugs, #slugs == 1 and "" or "s")
  if bytes and bytes > 0 then
    head = head .. (" (%s)"):format(size(bytes))
  end
  head = head .. " from " .. dir .. "?"
  local lines, line = { head }, ""
  for i, s in ipairs(slugs) do
    local item = s .. (i < #slugs and "," or "")
    if line ~= "" and #line + 1 + #item > 72 then
      lines[#lines + 1] = line
      line = "  " .. item
    else
      line = line == "" and ("  " .. item) or (line .. " " .. item)
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

return M
