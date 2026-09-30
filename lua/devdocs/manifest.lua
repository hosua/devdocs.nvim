--- Manifest: the list of every doc devdocs offers (docs.json), cached on
--- disk with a TTL. Also the pure helpers that reason about it: find a doc by
--- slug/alias/name, list the versions of a base, order versions newest first.
local config = require "devdocs.config"
local fetch = require "devdocs.fetch"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local M = {}

M.VERSION = 1

--- @class DevDocsDoc
--- @field name string      "Python"
--- @field slug string      "python~3.12"
--- @field type string      scraper type, e.g. "sphinx"
--- @field version string   "3.12" ("" when unversioned)
--- @field release string   "3.12.9"
--- @field mtime integer
--- @field db_size integer
--- @field links {home?: string, code?: string}|nil
--- @field alias string|nil

-- ---------------------------------------------------------------- pure helpers

--- "python~3.12" -> "python"; "css" -> "css"
--- @param slug string
--- @return string
function M.base(slug)
  return (slug:match "^([^~]+)") or slug
end

--- Split a version string into comparable parts: "22 LTS" -> {22}, "3.12" -> {3,12},
--- "2.13_library" -> {2,13}. Unversioned ("") sorts as newest.
--- @param v string
--- @return integer[]
local function parts(v)
  local out = {}
  for n in tostring(v):gmatch "%d+" do
    out[#out + 1] = tonumber(n)
  end
  return out
end

--- Compare two version strings. Returns 1 when a is newer, -1 when older, 0 when equal.
--- @param a string
--- @param b string
--- @return integer
function M.compare_versions(a, b)
  if a == b then
    return 0
  end
  if a == "" then
    return 1
  end
  if b == "" then
    return -1
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then
      return x > y and 1 or -1
    end
  end
  return 0
end

--- A new list of `docs` ordered newest version first (ties by slug).
--- @param docs DevDocsDoc[]
--- @return DevDocsDoc[]
function M.sort_newest(docs)
  local out = vim.list_slice(docs)
  table.sort(out, function(a, b)
    local c = M.compare_versions(a.version or "", b.version or "")
    if c ~= 0 then
      return c > 0
    end
    return a.slug < b.slug
  end)
  return out
end

--- Every doc whose slug is `base` or `base~...`, newest first.
--- @param docs DevDocsDoc[]
--- @param base string
--- @return DevDocsDoc[]
function M.versions(docs, base)
  local out = {}
  for _, d in ipairs(docs) do
    if d.slug == base or vim.startswith(d.slug, base .. "~") then
      out[#out + 1] = d
    end
  end
  return M.sort_newest(out)
end

--- Distinct bases in manifest order of first appearance.
--- @param docs DevDocsDoc[]
--- @return string[]
function M.bases(docs)
  local seen, out = {}, {}
  for _, d in ipairs(docs) do
    local b = M.base(d.slug)
    if not seen[b] then
      seen[b] = true
      out[#out + 1] = b
    end
  end
  return out
end

--- @param docs DevDocsDoc[]
--- @return table<string, DevDocsDoc>
function M.by_slug(docs)
  local out = {}
  for _, d in ipairs(docs) do
    out[d.slug] = d
  end
  return out
end

--- Find a doc by exact slug, then alias, then case-insensitive name/slug/base
--- (newest version of a base when the query names the base).
--- @param docs DevDocsDoc[]
--- @param query string
--- @return DevDocsDoc|nil
function M.find(docs, query)
  if not query or query == "" then
    return nil
  end
  for _, d in ipairs(docs) do
    if d.slug == query then
      return d
    end
  end
  local q = query:lower()
  local newest = M.versions(docs, q)
  if #newest > 0 then
    return newest[1]
  end
  local by_name = {}
  for _, d in ipairs(docs) do
    if (d.alias and d.alias:lower() == q) or d.name:lower() == q then
      by_name[#by_name + 1] = d
    end
  end
  if #by_name > 0 then
    return M.versions(by_name, M.base(by_name[1].slug))[1] or by_name[1]
  end
  return nil
end

--- Expand a user pattern ("python*", "Bootstrap", "node~22_lts") into docs.
--- `*` globs, matching is case-insensitive against slug, base, name and alias.
--- A pattern without `*` that names a base returns every version of it (the
--- caller applies recent_only/all).
--- @param docs DevDocsDoc[]
--- @param pattern string
--- @return DevDocsDoc[]
function M.glob(docs, pattern)
  local p = pattern:lower()
  if not p:find("*", 1, true) then
    local by_slug = M.by_slug(docs)[pattern]
    if by_slug then
      return { by_slug }
    end
    local out = {}
    for _, d in ipairs(docs) do
      if M.base(d.slug):lower() == p or d.name:lower() == p or (d.alias and d.alias:lower() == p) then
        out[#out + 1] = d
      end
    end
    return M.sort_newest(out)
  end
  local lua_pat = "^" .. vim.pesc(p):gsub("%%%*", ".*") .. "$"
  local out = {}
  for _, d in ipairs(docs) do
    if
      d.slug:lower():match(lua_pat)
      or M.base(d.slug):lower():match(lua_pat)
      or d.name:lower():match(lua_pat)
      or (d.alias and d.alias:lower():match(lua_pat))
    then
      out[#out + 1] = d
    end
  end
  return out
end

-- ---------------------------------------------------------------- cache on disk

--- @return DevDocsDoc[]|nil docs, integer|nil fetched_at
function M.cached()
  local rec = store.read_json(paths.manifest_file())
  if not rec or type(rec.docs) ~= "table" then
    return nil
  end
  return rec.docs, rec.fetched_at
end

--- @param now integer|nil
--- @return boolean
function M.is_fresh(now)
  local docs, at = M.cached()
  if not docs or not at then
    return false
  end
  return (now or os.time()) - at < config.get().install.manifest_ttl
end

--- Download docs.json and cache it. `cb(docs, err)`; on failure with a stale
--- cache present, `docs` is the stale list and `err` explains.
--- @param cb fun(docs: DevDocsDoc[]|nil, err: string|nil)
--- @param opts { url?: string, now?: integer }|nil
function M.fetch(cb, opts)
  opts = opts or {}
  local cfg = config.get()
  local tmp = paths.data_dir() .. "/manifest.download.json"
  fetch.download(opts.url or cfg.install.manifest_url, tmp, { curl = cfg.install.curl, timeout = 60 }, function(res)
    vim.schedule(function()
      if not res.ok then
        local stale = M.cached()
        cb(stale, ("could not fetch the docs list: %s"):format(res.err))
        return
      end
      local docs, err = store.read_json(tmp)
      os.remove(tmp)
      if not docs or not vim.islist(docs) then
        cb((M.cached()), "the docs list is not a JSON array: " .. tostring(err))
        return
      end
      local ok, werr = store.write_file(
        paths.manifest_file(),
        vim.json.encode { version = M.VERSION, fetched_at = opts.now or os.time(), docs = docs }
      )
      cb(docs, (not ok) and ("could not cache the docs list: " .. tostring(werr)) or nil)
    end)
  end)
end

--- The docs list: cached when fresh, fetched otherwise. `cb` is called
--- synchronously when the cache is fresh.
--- @param cb fun(docs: DevDocsDoc[]|nil, err: string|nil)
--- @param opts { force?: boolean, now?: integer, url?: string }|nil
function M.get(cb, opts)
  opts = opts or {}
  if not opts.force and M.is_fresh(opts.now) then
    cb((M.cached()))
    return
  end
  M.fetch(cb, opts)
end

return M
