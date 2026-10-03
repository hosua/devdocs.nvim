--- Detect: which installed docs a buffer should use, in which order, and
--- which docs it is missing (for install_as_needed).
---
--- A buffer's language comes from langmap.resolve (filetype, extension,
--- shebang, rc dotfile). Its version is only worked out for docs with more
--- than one installed version: an attached language server, the shebang
--- ("python3.12"), the project's files, then the installed tool. The result
--- is cached per buffer for the session, project-file answers per git root
--- on disk (projects.lua), so a lookup normally costs no file reads at all.
local config = require "devdocs.config"
local langmap = require "devdocs.langmap"
local manifest = require "devdocs.manifest"
local projects = require "devdocs.projects"
local store = require "devdocs.store"
local version = require "devdocs.version"

local M = {}

-- Nearest of these below the git root is where version files are read
-- first (a package in a monorepo); without a git root the nearest one is
-- the project.
local ROOT_MARKERS = {
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

-- bufnr -> { key = name .. ft, value = DevDocsBufferDocs }
local bufcache = {}
-- session: base -> installed versions (newest first); newest slug per base
local by_base, newest
-- session: tool base -> version|false
local tools = {}

function M.reset_cache()
  bufcache, by_base, newest, tools = {}, nil, nil, {}
  projects.reset_session()
end

-- installs, uninstalls and enable/disable all change what a buffer resolves to
store.on_invalidate(function()
  bufcache, by_base, newest = {}, nil, nil
end)

--- Drop one buffer's cached profile (FileType, rename, LSP attach).
--- @param bufnr integer
function M.forget_buffer(bufnr)
  bufcache[bufnr] = nil
end

local function home()
  return vim.fs.normalize(vim.uv.os_homedir() or "")
end

--- A directory that can be a project: never `/` or $HOME, so a dotfiles
--- repo in $HOME does not turn every file under it into one project.
local function usable(dir)
  return dir ~= nil and dir ~= "/" and dir ~= home()
end

local function source_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" and not name:match "^%a+://" then
    return name
  end
  return nil
end

--- Project root of a buffer: the enclosing git root, else the nearest
--- marker directory, else nil (not in a project: no project files are read).
--- @param bufnr integer
--- @return string|nil
function M.root(bufnr)
  local file = source_path(bufnr) or ((vim.uv.cwd() or ".") .. "/_")
  local git = vim.fs.root(file, ".git")
  if usable(git) then
    return git
  end
  local marker = vim.fs.root(file, ROOT_MARKERS)
  if usable(marker) and (not git or #marker > #git) then
    return marker
  end
  return nil
end

--- Directories version files are read from, nearest first.
--- @param bufnr integer
--- @return string[]
function M.version_dirs(bufnr)
  local root = M.root(bufnr)
  if not root then
    return {}
  end
  local file = source_path(bufnr) or ((vim.uv.cwd() or ".") .. "/_")
  local near = vim.fs.root(file, ROOT_MARKERS)
  if near and near ~= root and vim.startswith(near, root .. "/") then
    return { near, root }
  end
  return { root }
end

--- The installed tool's version for `base`, once per session and binary.
--- @param base string
--- @return string|nil version, string|nil source "tool:<cmd>"
local function tool_version(base)
  local cmd = version.tools[base]
  if not cmd then
    return nil
  end
  if tools[base] == nil then
    local exe = vim.fn.exepath(cmd[1])
    local function run()
      return version.tool_version(base)
    end
    -- a missing binary costs nothing to ask again; only real paths persist
    tools[base] = (exe ~= "" and projects.tool(exe, run) or run()) or false
  end
  if tools[base] then
    return tools[base], "tool:" .. cmd[1]
  end
  return nil
end

--- Version of `base` used by the project whose version files live in `dirs`
--- (nearest first): project files (cached on disk), else the tool.
--- @param base string
--- @param dirs string[]
--- @return string|nil version, string|nil source
local function project_version(base, dirs)
  if #dirs > 0 then
    -- keyed by the nearest dir: two packages of one repo may pin different versions
    local v, source = projects.version(dirs[1], base, function()
      return version.detect_with_files(base, dirs)
    end)
    if v then
      return v, source
    end
  end
  return tool_version(base)
end

--- Version of `base` the project at `root` uses (files, then tool; cached).
--- @param base string
--- @param root string|nil
--- @return string|nil
function M.detected_version(base, root)
  return (project_version(base, root and { root } or {}))
end

--- Installed docs of a base as manifest-like docs (from meta.json), newest first.
--- @param base string
--- @return DevDocsDoc[]
function M.installed_versions(base)
  if not by_base then
    local groups = {}
    for _, slug in ipairs(store.installed()) do
      local b = manifest.base(slug)
      local meta = store.meta(slug) or {}
      groups[b] = groups[b] or {}
      table.insert(
        groups[b],
        { slug = slug, version = meta.doc_version or "", name = meta.name or slug, mtime = meta.mtime }
      )
    end
    for b, list in pairs(groups) do
      groups[b] = manifest.sort_newest(list)
    end
    by_base = groups
  end
  return vim.deepcopy(by_base[base] or {})
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
--- @field root string|nil     project root (nil: not in a project)
--- @field ft string
--- @field how string          how the bases were found: filetype|extension|shebang|rc|none
--- @field scoped boolean      the language is known: lookups stay in `slugs`
--- @field versions table<string, { version: string|nil, source: string }> per base with a choice

--- Version of `base` for a buffer: LSP, shebang hint, project files, tool.
local function buffer_version(base, bufnr, dirs, hint)
  local clients = vim.lsp.get_clients and vim.lsp.get_clients { bufnr = bufnr } or {}
  local v, source = version.from_lsp(base, clients)
  if v then
    return v, source
  end
  if hint and hint.base == base then
    return hint.version, "shebang"
  end
  return project_version(base, dirs)
end

--- @param bufnr integer|nil
--- @return DevDocsBufferDocs
function M.buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local name = vim.api.nvim_buf_get_name(bufnr)
  local ft = vim.bo[bufnr].filetype
  local key = name .. "\0" .. ft
  local hit = bufcache[bufnr]
  if hit and hit.key == key then
    return hit.value
  end

  local cfg = config.get()
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  local bases, how, hint = langmap.resolve {
    ft = ft,
    name = name,
    first_line = first,
    extra = cfg.extra_filetypes,
    shell = vim.env.SHELL,
  }
  local root = M.root(bufnr)
  local dirs = root and M.version_dirs(bufnr) or {}
  local off = disabled()
  local slugs, missing, versions = {}, {}, {}
  for _, base in ipairs(bases) do
    local installed = vim.tbl_filter(function(d)
      return not off[d.slug]
    end, M.installed_versions(base))
    if #installed == 0 then
      missing[#missing + 1] = base
    else
      local v, source = nil, "newest"
      -- only a choice between versions is worth a lookup
      if #installed > 1 and not cfg.import.recent_only then
        v, source = buffer_version(base, bufnr, dirs, hint)
        source = source or "newest"
        versions[base] = { version = v, source = source }
      end
      slugs[#slugs + 1] = version.pick(installed, v, { recent_only = cfg.import.recent_only }).slug
    end
  end
  local value = {
    bases = bases,
    slugs = slugs,
    missing = missing,
    root = root,
    ft = ft,
    how = how,
    scoped = #bases > 0,
    versions = versions,
  }
  bufcache[bufnr] = { key = key, value = value }
  return value
end

--- Every installed doc that is not disabled, sorted.
--- @return string[]
function M.enabled_slugs()
  local off = disabled()
  return vim.tbl_filter(function(slug)
    return not off[slug]
  end, store.installed())
end

--- The newest enabled version of each installed doc, sorted.
--- @return string[]
function M.newest_slugs()
  if not newest then
    local off, seen, out = disabled(), {}, {}
    for _, slug in ipairs(store.installed()) do
      local base = manifest.base(slug)
      if not seen[base] then
        seen[base] = true
        for _, d in ipairs(M.installed_versions(base)) do
          if not off[d.slug] then
            out[#out + 1] = d.slug
            break
          end
        end
      end
    end
    table.sort(out)
    newest = out
  end
  return vim.deepcopy(newest)
end

--- The buffer's docs (tier 1) followed by `rest` (tier 2).
local function ordered(b, rest)
  local out, tiers = {}, {}
  for _, slug in ipairs(b.slugs) do
    out[#out + 1] = slug
    tiers[slug] = 1
  end
  for _, slug in ipairs(rest) do
    if not tiers[slug] then
      out[#out + 1] = slug
      tiers[slug] = 2
    end
  end
  return out, tiers
end

--- Slugs a symbol lookup searches. When the buffer's language is known,
--- only its docs (lookup.scope = "buffer"); otherwise the newest version of
--- every doc. lookup.scope = "all" adds every enabled doc after the buffer's.
--- @param bufnr integer|nil
--- @return string[] slugs, table<string, integer> tiers
function M.lookup_order(bufnr)
  local b = M.buffer(bufnr)
  if config.get().lookup.scope == "all" then
    return ordered(b, M.enabled_slugs())
  end
  if b.scoped then
    return ordered(b, {})
  end
  return ordered(b, M.newest_slugs())
end

--- Slugs a search covers: the buffer's docs first, then the newest version
--- of every other doc (every enabled doc with lookup.scope = "all"). An
--- "@slug" prefix in the query still reaches any installed version.
--- @param bufnr integer|nil
--- @return string[] slugs, table<string, integer> tiers
function M.search_order(bufnr)
  local b = M.buffer(bufnr)
  return ordered(b, config.get().lookup.scope == "all" and M.enabled_slugs() or M.newest_slugs())
end

--- Human-readable lines for :DevDocs detect / resync.
--- @param b DevDocsBufferDocs
--- @return string[]
function M.describe(b)
  local lines = {
    ("root: %s"):format(b.root or "none (not in a project)"),
    ("language: %s via %s (filetype %q)"):format(
      #b.bases > 0 and table.concat(b.bases, ", ") or "unknown",
      b.how,
      b.ft
    ),
  }
  if not b.scoped then
    lines[#lines + 1] = "lookups: newest version of every installed doc"
  end
  local slug_of = {}
  for _, slug in ipairs(b.slugs) do
    slug_of[manifest.base(slug)] = slug
  end
  for _, base in ipairs(b.bases) do
    local v = b.versions[base]
    if slug_of[base] then
      lines[#lines + 1] = ("  %s -> %s%s"):format(
        base,
        slug_of[base],
        v and (" (%s%s)"):format(v.source, v.version and (" " .. v.version) or "") or ""
      )
    else
      lines[#lines + 1] = ("  %s -> not installed"):format(base)
    end
  end
  return lines
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
  local cfg = config.get()
  local detected = (#versions > 1 and not cfg.import.recent_only) and M.detected_version(base, root) or nil
  return version.pick(versions, detected, { recent_only = cfg.import.recent_only })
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
