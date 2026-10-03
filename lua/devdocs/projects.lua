--- Projects: what each project (git root) was found to use, kept across
--- sessions in <data_dir>/projects.json, outside every project. A root's
--- record carries a fingerprint of every file its detectors looked at
--- (present or absent); the first time a session touches the root, those
--- files are stat'ed once and any change drops the record, so editing
--- .nvmrc or adding one is picked up on the next start without a resync.
--- Tool versions (`fish --version`) are kept the same way, keyed by the
--- binary's path and stamped with its size and mtime.
---
--- {
---   version = 1,
---   roots = { [root] = { bases = { [base] = { v = "3.12"|false, source = "file:.python-version" } },
---                        files = { [path] = stamp } } },
---   tools = { [exe] = { v = "4.0.2"|false, stamp = stamp } },
--- }
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local M = {}

local data -- decoded projects.json for this session
local validated = {} -- root/exe -> true once checked against the disk this session

function M.file()
  return paths.data_dir() .. "/projects.json"
end

--- size + mtime (with nanoseconds) of a file, "-" when it does not exist.
--- @param file string
--- @return string
function M.stamp(file)
  local st = vim.uv.fs_stat(file)
  if not st then
    return "-"
  end
  return ("%d:%d.%d"):format(st.size, st.mtime.sec, st.mtime.nsec)
end

local function load()
  if not data then
    local rec = store.read_json(M.file())
    data = {
      roots = rec and type(rec.roots) == "table" and rec.roots or {},
      tools = rec and type(rec.tools) == "table" and rec.tools or {},
    }
  end
  return data
end

local function save()
  -- a newer plugin's file is left alone (write_json refuses); we keep the
  -- answers in memory for this session either way
  store.write_json(M.file(), { roots = data.roots, tools = data.tools }, "projects")
end

--- Drop this session's view; the next call re-reads projects.json and
--- re-validates every fingerprint.
function M.reset_session()
  data = nil
  validated = {}
end

--- Forget one project (its root and every package dir under it) plus the
--- tool versions, or everything.
--- @param root string|nil
function M.forget(root)
  load()
  for dir in pairs(data.roots) do
    if not root or dir == root or vim.startswith(dir, root .. "/") then
      data.roots[dir] = nil
    end
  end
  data.tools = {}
  validated = {}
  save()
end

local function fresh_root(root)
  local rec = data.roots[root]
  if not rec or validated[root] then
    return rec
  end
  validated[root] = true
  for file, stamp in pairs(rec.files or {}) do
    if M.stamp(file) ~= stamp then
      data.roots[root] = nil
      return nil
    end
  end
  return rec
end

--- Version of `base` in the project at `root`: cached, else `compute()`.
--- @param root string
--- @param base string
--- @param compute fun(): string|nil, string[]|nil, string|nil version, files looked at, source
--- @return string|nil version, string|nil source
function M.version(root, base, compute)
  load()
  local rec = fresh_root(root)
  local hit = rec and rec.bases and rec.bases[base]
  if hit then
    return hit.v or nil, hit.source or nil
  end
  local v, files, source = compute()
  rec = rec or { bases = {}, files = {} }
  rec.bases[base] = { v = v or false, source = source or false }
  for _, file in ipairs(files or {}) do
    rec.files[file] = M.stamp(file)
  end
  data.roots[root] = rec
  validated[root] = true
  save()
  return v, source
end

--- Version of the tool at path `exe`: cached while the binary is unchanged.
--- @param exe string absolute path (vim.fn.exepath)
--- @param compute fun(): string|nil
--- @return string|nil
function M.tool(exe, compute)
  load()
  local key = "\0" .. exe
  local hit = data.tools[exe]
  if hit and (validated[key] or hit.stamp == M.stamp(exe)) then
    validated[key] = true
    return hit.v or nil
  end
  local v = compute()
  data.tools[exe] = { v = v or false, stamp = M.stamp(exe) }
  validated[key] = true
  save()
  return v
end

return M
