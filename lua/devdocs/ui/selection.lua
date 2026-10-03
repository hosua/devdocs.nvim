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
--- installed children that pass the filter (`visible`, set by model.rows;
--- every child when it is absent); nothing for group rows and docs that are
--- not installed. So X / m on a language never reach a version the filter hides.
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
    for _, c in ipairs(row.visible or row.children or {}) do
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

--- Slugs (of `slugs`) that no row of the current view shows: not a doc row
--- and not a visible child of a lang row. Sorted.
--- @param slugs string[]
--- @param rows table[] model.rows()
--- @return string[]
function M.hidden(slugs, rows)
  local shown = {}
  for _, r in ipairs(rows or {}) do
    if r.kind == "doc" then
      shown[r.slug] = true
    elseif r.kind == "lang" then
      for _, c in ipairs(r.visible or r.children or {}) do
        shown[c.slug] = true
      end
    end
  end
  local out = vim.tbl_filter(function(s)
    return not shown[s]
  end, slugs or {})
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

local function installed_version(slug, meta, by_slug)
  local d = by_slug[slug]
  return (d and d.version) or (meta and meta.doc_version) or slug:match "~(.*)$" or ""
end

--- Installed versions to delete so that every language keeps one. Per base,
--- of its installed versions (version strings from the manifest, else
--- meta.doc_version, else the slug suffix; the unversioned slug is newest):
---   keep the newest one that is enabled (not in opts.disabled), or the
---   newest one when every installed version is disabled;
---   never delete a version in opts.pinned (a project uses it).
--- A base with one installed version is never touched, so pruning can not
--- remove a language.
--- @param installed table<string, table>|nil slug -> meta
--- @param docs DevDocsDoc[]|nil manifest
--- @param bases string|string[]|table<string, boolean>|nil only these bases
--- @param opts { disabled?: table<string, boolean>, pinned?: table<string, string[]> }|nil
--- @return string[] slugs to delete, sorted
--- @return string[] held pinned slugs that would otherwise go, sorted
function M.prune_targets(installed, docs, bases, opts)
  opts = opts or {}
  local disabled, pinned = opts.disabled or {}, opts.pinned or {}
  local only = as_set(bases)
  local by_slug = manifest.by_slug(docs or {})

  local groups = {}
  for slug, meta in pairs(installed or {}) do
    local base = manifest.base(slug)
    if not only or only[base] then
      groups[base] = groups[base] or {}
      table.insert(groups[base], { slug = slug, version = installed_version(slug, meta, by_slug) })
    end
  end

  local out, held = {}, {}
  for _, versions in pairs(groups) do
    if #versions > 1 then
      local sorted = manifest.sort_newest(versions)
      local keep = sorted[1].slug
      for _, v in ipairs(sorted) do
        if not disabled[v.slug] then
          keep = v.slug
          break
        end
      end
      for _, v in ipairs(sorted) do
        if v.slug ~= keep then
          local list = pinned[v.slug]
          if list and (type(list) ~= "table" or #list > 0) then
            held[#held + 1] = v.slug
          else
            out[#out + 1] = v.slug
          end
        end
      end
    end
  end
  table.sort(out)
  table.sort(held)
  return out, held
end

--- Installed slugs that projects pin: each pin ({ root, base, version }, from
--- projects.pins()) resolves to the installed version of its base the
--- project would use (version.pick: same major.minor, else the newest one
--- not newer). A pin no installed version fits pins nothing.
--- @param installed table<string, table>|nil slug -> meta
--- @param docs DevDocsDoc[]|nil manifest
--- @param pins { root: string, base: string, version: string }[]|nil
--- @return table<string, string[]> slug -> project roots, sorted
function M.pinned_slugs(installed, docs, pins)
  local version = require "devdocs.version"
  local by_slug = manifest.by_slug(docs or {})
  local by_base = {}
  for slug, meta in pairs(installed or {}) do
    local base = manifest.base(slug)
    by_base[base] = by_base[base] or {}
    table.insert(by_base[base], { slug = slug, version = installed_version(slug, meta, by_slug) })
  end
  local out = {}
  for _, pin in ipairs(pins or {}) do
    local list = by_base[pin.base]
    local d = list and version.pick(manifest.sort_newest(list), pin.version)
    if d and d.version ~= "" then
      local p, want = version.parts(d.version), version.parts(pin.version)
      local same = p[1] == want[1] and (p[2] == nil or want[2] == nil or p[2] == want[2])
      if same or manifest.compare_versions(d.version, pin.version) <= 0 then
        out[d.slug] = out[d.slug] or {}
        if not vim.tbl_contains(out[d.slug], pin.root) then
          table.insert(out[d.slug], pin.root)
        end
      end
    end
  end
  for _, roots in pairs(out) do
    table.sort(roots)
  end
  return out
end

--- The confirm note for pinned versions prune keeps, or nil when none.
--- @param held string[]
--- @param pinned table<string, string[]>
--- @return string|nil
function M.prune_note(held, pinned)
  if not held or #held == 0 then
    return nil
  end
  local roots, seen = {}, {}
  for _, slug in ipairs(held) do
    for _, r in ipairs(pinned[slug] or {}) do
      if not seen[r] then
        seen[r] = true
        roots[#roots + 1] = vim.fn.fnamemodify(r, ":~")
      end
    end
  end
  return ("kept (pinned by project %s): %s"):format(table.concat(roots, ", "), table.concat(held, ", "))
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
--- @param notes string[]|nil extra lines after the slug list
--- @return string
function M.confirm_message(slugs, bytes, dir, notes)
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
  vim.list_extend(lines, notes or {})
  return table.concat(lines, "\n")
end

return M
