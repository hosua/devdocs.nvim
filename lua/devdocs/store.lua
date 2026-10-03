--- Store: the on-disk records (state.json, meta.json, entries.tsv, anchors.json).
--- All writes are atomic (temp file + rename) and every JSON record carries a
--- `version`; a file written by a newer plugin is never overwritten.
--- Reads of per-doc data are cached for the session; installer.lua calls
--- invalidate() after it changes docs on disk.
local paths = require "devdocs.paths"

local M = {}

M.VERSIONS = { state = 1, meta = 1, anchors = 1, projects = 1 }

local cache = { meta = {}, entries = {}, names = {}, anchors = {}, installed = nil, state = nil }
local subscribers = {}

--- Call `fn` whenever installed docs or state change (detect.lua drops its
--- per-buffer profiles then).
--- @param fn fun()
function M.on_invalidate(fn)
  subscribers[#subscribers + 1] = fn
end

local function notify_subscribers()
  for _, fn in ipairs(subscribers) do
    pcall(fn)
  end
end

--- Drop every cached record (one slug, or all).
--- @param slug string|nil
function M.invalidate(slug)
  if slug then
    cache.meta[slug], cache.entries[slug], cache.names[slug], cache.anchors[slug] = nil, nil, nil, nil
  else
    cache = { meta = {}, entries = {}, names = {}, anchors = {}, installed = nil, state = nil }
  end
  cache.installed = nil
  cache.state = nil
  notify_subscribers()
end

--- @param file string
--- @return string|nil content, string|nil err
function M.read_file(file)
  local f, err = io.open(file, "rb")
  if not f then
    return nil, err
  end
  local content = f:read "*a"
  f:close()
  return content
end

--- Write `content` to `file` atomically: same directory temp file, then rename.
--- @param file string
--- @param content string
--- @return boolean ok, string|nil err
function M.write_file(file, content)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local tmp = ("%s.%d.%d.tmp"):format(file, vim.uv.os_getpid(), vim.uv.hrtime() % 1000000)
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, err
  end
  local ok, werr = f:write(content)
  f:close()
  if not ok then
    os.remove(tmp)
    return false, werr
  end
  local rok, rerr = vim.uv.fs_rename(tmp, file)
  if not rok then
    os.remove(tmp)
    return false, rerr
  end
  return true
end

--- @param file string
--- @return table|nil tbl, string|nil err ("missing" when the file does not exist)
function M.read_json(file)
  local content, err = M.read_file(file)
  if not content then
    return nil, vim.uv.fs_stat(file) and err or "missing"
  end
  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return nil, ("corrupt JSON in %s: %s"):format(file, tostring(decoded))
  end
  return decoded
end

--- Refuse to write over a record whose version is newer than this plugin knows.
--- @param file string
--- @param kind "state"|"meta"|"anchors"|"projects"
--- @return boolean ok, string|nil err
local function version_guard(file, kind)
  local existing = M.read_json(file)
  if existing and type(existing.version) == "number" and existing.version > M.VERSIONS[kind] then
    return false,
      ("%s was written by a newer devdocs.nvim (version %d > %d); refusing to overwrite"):format(
        file,
        existing.version,
        M.VERSIONS[kind]
      )
  end
  return true
end

--- @param file string
--- @param tbl table
--- @param kind "state"|"meta"|"anchors"|"projects"
--- @return boolean ok, string|nil err
function M.write_json(file, tbl, kind)
  local ok, err = version_guard(file, kind)
  if not ok then
    return false, err
  end
  local record = vim.tbl_extend("force", tbl, { version = M.VERSIONS[kind] })
  return M.write_file(file, vim.json.encode(record))
end

-- ---------------------------------------------------------------- state

local function default_state()
  return { version = M.VERSIONS.state, enabled = {}, recent = {} }
end

--- Read once per session (detect.lua asks on every buffer); update_state and
--- invalidate() refresh it. Callers get a copy.
--- @return table state (never nil; a missing or corrupt file yields the defaults)
--- @return string|nil err set when the file exists but could not be read
function M.state()
  if not cache.state then
    local st, err = M.read_json(paths.state_file())
    if not st then
      -- a read error is not cached: the next call tries again
      return default_state(), err ~= "missing" and err or nil
    end
    cache.state = vim.tbl_deep_extend("keep", st, default_state())
  end
  return vim.deepcopy(cache.state)
end

--- Re-read, apply `fn` (which returns the new state), write. Never mutates
--- the table it hands to `fn`'s caller.
--- @param fn fun(state: table): table
--- @return boolean ok, string|nil err
function M.update_state(fn)
  cache.state = nil
  local st = M.state()
  local new = fn(st)
  local ok, err = M.write_json(paths.state_file(), new, "state")
  cache.state = nil
  notify_subscribers()
  return ok, err
end

-- ---------------------------------------------------------------- meta / installed

--- @param slug string
--- @return table|nil meta
function M.meta(slug)
  if cache.meta[slug] == nil then
    cache.meta[slug] = M.read_json(paths.meta_file(slug)) or false
  end
  return cache.meta[slug] or nil
end

--- Slugs with a readable meta.json, sorted.
--- @return string[]
function M.installed()
  if cache.installed then
    return vim.deepcopy(cache.installed)
  end
  local out = {}
  local dir = paths.docs_dir()
  if vim.uv.fs_stat(dir) then
    for name, kind in vim.fs.dir(dir) do
      if kind == "directory" and paths.valid_slug(name) and M.meta(name) then
        out[#out + 1] = name
      end
    end
  end
  table.sort(out)
  cache.installed = out
  return vim.deepcopy(out)
end

--- @param slug string
--- @return boolean
function M.is_installed(slug)
  return paths.valid_slug(slug) and M.meta(slug) ~= nil
end

-- ---------------------------------------------------------------- entries / anchors

--- @class DevDocsEntry
--- @field name string   "std::cout", "os.path.join()"
--- @field path string   "io/basic_ostream" or "library/os.path#os.path.join"
--- @field type string   the index.json type, e.g. "Standard Libraries"

--- Parse entries.tsv into a list. Cached per slug.
--- @param slug string
--- @return DevDocsEntry[] entries
function M.entries(slug)
  if cache.entries[slug] then
    return cache.entries[slug]
  end
  local content = M.read_file(paths.entries_file(slug)) or ""
  local out = {}
  for line in vim.gsplit(content, "\n", { plain = true }) do
    if line ~= "" then
      local name, path, typ = line:match "^([^\t]*)\t([^\t]*)\t?(.*)$"
      if name and path then
        out[#out + 1] = { name = name, path = path, type = typ or "" }
      end
    end
  end
  cache.entries[slug] = out
  return out
end

--- Normalized entry names of a doc, index-aligned with entries(slug). Cached.
--- @param slug string
--- @return string[]
function M.names(slug)
  if not cache.names[slug] then
    cache.names[slug] = require("devdocs.rank").normalized_names(M.entries(slug))
  end
  return cache.names[slug]
end

--- @param entries DevDocsEntry[]
--- @return string tsv
function M.encode_entries(entries)
  local lines = {}
  for i, e in ipairs(entries) do
    lines[i] = table.concat({ e.name, e.path, e.type or "" }, "\t")
  end
  return table.concat(lines, "\n") .. "\n"
end

--- @param slug string
--- @return table<string, table<string, integer>> page -> fragment -> 1-based line
function M.anchors(slug)
  if cache.anchors[slug] == nil then
    local rec = M.read_json(paths.anchors_file(slug))
    cache.anchors[slug] = rec and rec.pages or {}
  end
  return cache.anchors[slug]
end

-- ---------------------------------------------------------------- recent

M.RECENT_MAX = 50

--- Push a page onto the recent list (most recent first, de-duplicated).
--- @param slug string
--- @param path string
--- @param name string|nil
function M.push_recent(slug, path, name)
  return M.update_state(function(st)
    local recent = { { slug = slug, path = path, name = name, at = os.time() } }
    for _, r in ipairs(st.recent) do
      if (r.slug ~= slug or r.path ~= path) and #recent < M.RECENT_MAX then
        recent[#recent + 1] = r
      end
    end
    st.recent = recent
    return st
  end)
end

return M
