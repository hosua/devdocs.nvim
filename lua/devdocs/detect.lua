--- Detect: which installed docs a buffer should use, in which order, and
--- which docs it is missing (for install_as_needed). Combines langmap
--- (filetype -> bases), version (project version -> doc version) and the
--- store (what is installed). Version detection results are cached per
--- project root for a minute so a FileType storm never re-reads files.
local config = require "devdocs.config"
local langmap = require "devdocs.langmap"
local manifest = require "devdocs.manifest"
local store = require "devdocs.store"
local version = require "devdocs.version"

local M = {}

local ROOT_MARKERS = {
  ".git",
  "package.json",
  "pyproject.toml",
  "go.mod",
  "Cargo.toml",
  "composer.json",
  "Gemfile",
  "mix.exs",
  "build.gradle",
  "pom.xml",
  "CMakeLists.txt",
  "project.godot",
  ".luarc.json",
}

local CACHE_TTL = 60
local cache = {}

function M.reset_cache()
  cache = {}
end

--- Project root of a buffer (nearest marker directory), else its directory, else cwd.
--- @param bufnr integer
--- @return string
function M.root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" and not name:match "^%a+://" then
    local root = vim.fs.root(name, ROOT_MARKERS)
    if root then
      return root
    end
    return vim.fs.dirname(name)
  end
  return vim.uv.cwd() or "."
end

--- Version of `base` the project at `root` uses (file-based, cached).
--- @param base string
--- @param root string
--- @return string|nil
function M.detected_version(base, root)
  local key = root .. "\0" .. base
  local hit = cache[key]
  local now = os.time()
  if hit and now - hit.at < CACHE_TTL then
    return hit.version
  end
  local v = version.detect(base, root)
  cache[key] = { at = now, version = v }
  return v
end

--- Installed docs of a base as manifest-like docs (from meta.json), newest first.
--- @param base string
--- @return DevDocsDoc[]
function M.installed_versions(base)
  local out = {}
  for _, slug in ipairs(store.installed()) do
    if manifest.base(slug) == base then
      local meta = store.meta(slug) or {}
      out[#out + 1] = { slug = slug, version = meta.doc_version or "", name = meta.name or slug, mtime = meta.mtime }
    end
  end
  return manifest.sort_newest(out)
end

--- Docs the user disabled in the manager (state.enabled[slug] == false).
local function disabled()
  local st = store.state()
  local out = {}
  for slug, on in pairs(st.enabled) do
    if on == false then
      out[slug] = true
    end
  end
  return out
end

--- @class DevDocsBufferDocs
--- @field bases string[]      doc bases for the buffer, most specific first
--- @field slugs string[]      installed slug per base (one each), same order
--- @field missing string[]    bases with no installed version
--- @field root string
--- @field ft string

--- @param bufnr integer|nil
--- @return DevDocsBufferDocs
function M.buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cfg = config.get()
  local ft = vim.bo[bufnr].filetype
  local bases = langmap.bases_for(ft, vim.api.nvim_buf_get_name(bufnr), cfg.extra_filetypes)
  local root = M.root(bufnr)
  local off = disabled()
  local slugs, missing = {}, {}
  for _, base in ipairs(bases) do
    local versions = vim.tbl_filter(function(d)
      return not off[d.slug]
    end, M.installed_versions(base))
    if #versions == 0 then
      missing[#missing + 1] = base
    else
      local detected = cfg.import.all and M.detected_version(base, root) or M.detected_version(base, root)
      local pick = version.pick(versions, detected, { recent_only = cfg.import.recent_only })
      slugs[#slugs + 1] = pick.slug
    end
  end
  return { bases = bases, slugs = slugs, missing = missing, root = root, ft = ft }
end

--- Every installed doc that is not disabled, sorted.
--- @return string[]
function M.enabled_slugs()
  local off = disabled()
  return vim.tbl_filter(function(slug)
    return not off[slug]
  end, store.installed())
end

--- Slugs to search for a buffer: its own docs first, then every other enabled doc.
--- @param bufnr integer|nil
--- @return string[] slugs, table<string, integer> tiers
function M.lookup_order(bufnr)
  local b = M.buffer(bufnr)
  local out, tiers, seen = {}, {}, {}
  for _, slug in ipairs(b.slugs) do
    seen[slug] = true
    out[#out + 1] = slug
    tiers[slug] = 1
  end
  for _, slug in ipairs(M.enabled_slugs()) do
    if not seen[slug] then
      out[#out + 1] = slug
      tiers[slug] = 2
    end
  end
  return out, tiers
end

--- The manifest slug to install for `base` in the project at `root`
--- (project version, else newest). Needs a cached manifest.
--- @param base string
--- @param root string
--- @param docs DevDocsDoc[]
--- @return DevDocsDoc|nil
function M.slug_to_install(base, root, docs)
  local versions = manifest.versions(docs, base)
  if #versions == 0 then
    return nil
  end
  return version.pick(versions, M.detected_version(base, root), { recent_only = config.get().import.recent_only })
end

--- The docs a buffer is missing, resolved against the manifest.
--- @param bufnr integer|nil
--- @param docs DevDocsDoc[]
--- @return DevDocsDoc[]
function M.missing_docs(bufnr, docs)
  local b = M.buffer(bufnr)
  local out = {}
  for _, base in ipairs(b.missing) do
    local d = M.slug_to_install(base, b.root, docs)
    if d and not store.is_installed(d.slug) then
      out[#out + 1] = d
    end
  end
  return out
end

return M
