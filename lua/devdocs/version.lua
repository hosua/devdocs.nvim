--- Version: which version of a doc a buffer should get, and which available
--- doc version to pick for it. Sources, cheapest first: an attached language
--- server's settings (from_lsp), files in the project (detectors), and the
--- installed tool's `--version` (tool_version, a blocking subprocess run at
--- most once per binary; projects.lua persists it). detect.lua decides the
--- order and caches.
local manifest = require "devdocs.manifest"

local M = {}

--- First "x", "x.y" or "x.y.z" in a version spec: "^20.1.0" -> "20.1.0",
--- ">=3.10,<4" -> "3.10", "v22" -> "22", "lts/*" -> nil.
--- @param spec string|nil
--- @return string|nil
function M.first_version(spec)
  if type(spec) ~= "string" then
    return nil
  end
  return spec:match "(%d+%.%d+%.%d+)" or spec:match "(%d+%.%d+)" or spec:match "(%d+)"
end

--- @param v string
--- @return integer[] parts
function M.parts(v)
  local out = {}
  for n in tostring(v):gmatch "%d+" do
    out[#out + 1] = tonumber(n)
  end
  return out
end

--- "major.minor" of a version string ("3.12.3" -> "3.12", "22" -> "22").
--- @param v string
--- @return string
function M.major_minor(v)
  local p = M.parts(v)
  if #p == 0 then
    return v
  end
  return p[2] and (p[1] .. "." .. p[2]) or tostring(p[1])
end

--- Pick the doc for `detected` among `available` (newest first, as
--- manifest.versions returns). Exact major.minor first, then the newest
--- version not newer than the detected one, then the newest of all.
--- Unversioned docs ("" version) are "current" and win only when nothing
--- versioned fits or nothing was detected.
--- @param available DevDocsDoc[]
--- @param detected string|nil
--- @param opts { recent_only?: boolean }|nil
--- @return DevDocsDoc|nil
function M.pick(available, detected, opts)
  if #available == 0 then
    return nil
  end
  opts = opts or {}
  if not detected or opts.recent_only then
    return available[1]
  end
  local want = M.parts(detected)
  if #want == 0 then
    return available[1]
  end
  local versioned = vim.tbl_filter(function(d)
    return (d.version or "") ~= ""
  end, available)
  if #versioned == 0 then
    return available[1]
  end
  -- exact major.minor (or major when the doc only has a major)
  for _, d in ipairs(versioned) do
    local p = M.parts(d.version)
    if p[1] == want[1] and (p[2] == nil or want[2] == nil or p[2] == want[2]) then
      return d
    end
  end
  -- newest not newer than detected (list is newest first)
  for _, d in ipairs(versioned) do
    if manifest.compare_versions(d.version, detected) <= 0 then
      return d
    end
  end
  return available[1]
end

-- ---------------------------------------------------------------- project file detectors

-- detect_with_files() collects every file a detector tries, present or not,
-- so projects.lua can tell when a cached answer went stale.
local touched

local function read(file)
  if touched then
    touched[#touched + 1] = file
  end
  local f = io.open(file, "rb")
  if not f then
    return nil
  end
  local s = f:read(65536) -- version markers live near the top
  f:close()
  return s
end

local function json(file)
  local s = read(file)
  if not s then
    return nil
  end
  local ok, tbl = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and type(tbl) == "table" and tbl or nil
end

--- package.json: engines.<key> or (dev)dependencies.<key>.
local function package_json(root, key, section)
  local pkg = json(root .. "/package.json")
  if not pkg then
    return nil
  end
  if section == "engines" then
    return M.first_version(pkg.engines and pkg.engines[key])
  end
  local deps = vim.tbl_extend("keep", pkg.dependencies or {}, pkg.devDependencies or {}, pkg.peerDependencies or {})
  return M.first_version(deps[key])
end

--- requirements*.txt / pyproject.toml dependency lines: "Django==4.2.1", 'django>=4.2'.
local function python_dep(root, name)
  local pat = "%f[%w]" .. name:lower() .. "%s*[=><~!]+%s*([%d%.]+)"
  for _, file in ipairs { "requirements.txt", "requirements/base.txt", "pyproject.toml", "Pipfile", "setup.cfg" } do
    local s = read(root .. "/" .. file)
    if s then
      local v = s:lower():match(pat)
      if v then
        return M.first_version(v)
      end
    end
  end
  return nil
end

--- @type table<string, fun(root: string): string|nil>
M.detectors = {
  node = function(root)
    for _, file in ipairs { ".nvmrc", ".node-version" } do
      local v = M.first_version(read(root .. "/" .. file))
      if v then
        return v
      end
    end
    return package_json(root, "node", "engines")
  end,
  python = function(root)
    local v = M.first_version(read(root .. "/.python-version"))
    if v then
      return v
    end
    local py = read(root .. "/pyproject.toml")
    if py then
      v = M.first_version(py:match 'requires%-python%s*=%s*"([^"]*)"')
      if v then
        return v
      end
    end
    return M.first_version(read(root .. "/runtime.txt"))
  end,
  go = function(root)
    local s = read(root .. "/go.mod")
    return s and M.first_version(s:match "\ngo%s+([%d%.]+)" or s:match "^go%s+([%d%.]+)") or nil
  end,
  ruby = function(root)
    local v = M.first_version(read(root .. "/.ruby-version"))
    if v then
      return v
    end
    local g = read(root .. "/Gemfile")
    return g and M.first_version(g:match "\nruby%s+[\"']([^\"']+)") or nil
  end,
  rails = function(root)
    local g = read(root .. "/Gemfile")
    return g and M.first_version(g:match "gem%s+[\"']rails[\"']%s*,%s*[\"']([^\"']+)") or nil
  end,
  php = function(root)
    local c = json(root .. "/composer.json")
    return c and c.require and M.first_version(c.require.php) or nil
  end,
  laravel = function(root)
    local c = json(root .. "/composer.json")
    return c and c.require and M.first_version(c.require["laravel/framework"]) or nil
  end,
  lua = function(root)
    for _, file in ipairs { ".luarc.json", ".luarc.jsonc" } do
      local s = read(root .. "/" .. file)
      if s then
        local rt = s:match '"runtime"%s*:%s*{[^}]*"version"%s*:%s*"([^"]+)"'
          or s:match '"runtime%.version"%s*:%s*"([^"]+)"'
        if rt then
          if rt:lower():find "jit" then
            return "5.1"
          end
          return M.first_version(rt)
        end
      end
    end
    -- a Neovim config or plugin runs on LuaJIT
    if read(root .. "/init.lua") and (vim.uv.fs_stat(root .. "/lua") or vim.uv.fs_stat(root .. "/plugin")) then
      return "5.1"
    end
    if read(root .. "/.nvim.lua") or read(root .. "/.stylua.toml") then
      return "5.1"
    end
    return nil
  end,
  openjdk = function(root)
    local v = M.first_version(read(root .. "/.java-version"))
    if v then
      return v
    end
    local pom = read(root .. "/pom.xml")
    if pom then
      v = M.first_version(
        pom:match "<maven%.compiler%.release>([^<]+)"
          or pom:match "<maven%.compiler%.source>([^<]+)"
          or pom:match "<java%.version>([^<]+)"
      )
      if v then
        return v
      end
    end
    for _, file in ipairs { "build.gradle", "build.gradle.kts" } do
      local g = read(root .. "/" .. file)
      if g then
        v = M.first_version(g:match "sourceCompatibility[^\n]-(%d[%d%.]*)" or g:match "languageVersion[^\n]-(%d+)")
        if v then
          return v
        end
      end
    end
    return nil
  end,
  django = function(root)
    return python_dep(root, "django")
  end,
  numpy = function(root)
    return python_dep(root, "numpy")
  end,
  pandas = function(root)
    return python_dep(root, "pandas")
  end,
  matplotlib = function(root)
    return python_dep(root, "matplotlib")
  end,
  flask = function(root)
    return python_dep(root, "flask")
  end,
  react = function(root)
    return package_json(root, "react")
  end,
  vue = function(root)
    return package_json(root, "vue")
  end,
  angular = function(root)
    return package_json(root, "@angular/core")
  end,
  bootstrap = function(root)
    return package_json(root, "bootstrap")
  end,
  typescript = function(root)
    -- the compiler actually installed beats the range in package.json
    local installed = json(root .. "/node_modules/typescript/package.json")
    return (installed and M.first_version(installed.version)) or package_json(root, "typescript")
  end,
  jest = function(root)
    return package_json(root, "jest")
  end,
  vitest = function(root)
    return package_json(root, "vitest")
  end,
  vite = function(root)
    return package_json(root, "vite")
  end,
  webpack = function(root)
    return package_json(root, "webpack")
  end,
  tailwindcss = function(root)
    return package_json(root, "tailwindcss")
  end,
  express = function(root)
    return package_json(root, "express")
  end,
  redux = function(root)
    return package_json(root, "redux")
  end,
  svelte = function(root)
    return package_json(root, "svelte")
  end,
  lodash = function(root)
    return package_json(root, "lodash")
  end,
  yarn = function(root)
    local pkg = json(root .. "/package.json")
    return pkg and M.first_version(pkg.packageManager and pkg.packageManager:match "yarn@([%d%.]+)") or nil
  end,
  cmake = function(root)
    local s = read(root .. "/CMakeLists.txt")
    return s and M.first_version(s:match "cmake_minimum_required%s*%(%s*VERSION%s+([%d%.]+)") or nil
  end,
  godot = function(root)
    local s = read(root .. "/project.godot")
    if not s then
      return nil
    end
    local feat = s:match 'config/features%s*=%s*PackedStringArray%s*%(%s*"([%d%.]+)"'
    return M.first_version(feat) or (s:match "config_version%s*=%s*4" and "3.5") or nil
  end,
  elixir = function(root)
    local s = read(root .. "/mix.exs")
    return s and M.first_version(s:match 'elixir:%s*"([^"]+)"') or nil
  end,
  scala = function(root)
    local s = read(root .. "/build.sbt")
    return s and M.first_version(s:match 'scalaVersion%s*:?=%s*"([^"]+)"') or nil
  end,
  dart = function(root)
    local s = read(root .. "/pubspec.yaml")
    return s and M.first_version(s:match "sdk:%s*[\"']?([^\"'\n]+)") or nil
  end,
  kotlin = function(root)
    for _, file in ipairs { "build.gradle.kts", "build.gradle" } do
      local g = read(root .. "/" .. file)
      if g then
        local v = M.first_version(
          g:match 'kotlin%("jvm"%)%s*version%s*"([^"]+)"' or g:match "kotlin_version%s*=%s*[\"']([^\"']+)"
        )
        if v then
          return v
        end
      end
    end
    return nil
  end,
  postgresql = function(root)
    for _, file in ipairs { "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml" } do
      local s = read(root .. "/" .. file)
      if s then
        local v = M.first_version(s:match "image:%s*[\"']?postgres:([%w%.%-]+)")
        if v then
          return v
        end
      end
    end
    return nil
  end,
}

--- Detect the version of `base` used by the project at `root`, from files only.
--- @param base string
--- @param root string
--- @return string|nil
function M.detect(base, root)
  local fn = M.detectors[base]
  if not fn or not root or root == "" then
    return nil
  end
  local ok, v = pcall(fn, root)
  return ok and v or nil
end

--- Detect from files, trying each dir in order (nearest package first, then
--- the repo root), and return every file path that was looked at.
--- @param base string
--- @param dirs string[]
--- @return string|nil version, string[] files, string|nil source "file:<name>"
function M.detect_with_files(base, dirs)
  local files = {}
  if not M.detectors[base] then
    return nil, files, nil
  end
  for _, dir in ipairs(dirs) do
    touched = {}
    local v = M.detect(base, dir)
    local tried = touched
    touched = nil
    vim.list_extend(files, tried)
    if v then
      -- the last file read is the one that answered
      return v, files, "file:" .. vim.fn.fnamemodify(tried[#tried] or "", ":t")
    end
  end
  return nil, files, nil
end

-- ---------------------------------------------------------------- subprocesses

--- Run a command, return stdout..stderr or nil. Replaced in tests.
--- @param cmd string[]
--- @return string|nil
function M._run(cmd)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil
  end
  local ok, obj = pcall(vim.system, cmd, { text = true })
  if not ok then
    return nil
  end
  local res = obj:wait(1000)
  if not res or res.code ~= 0 then
    return nil
  end
  return (res.stdout or "") .. (res.stderr or "")
end

--- base -> command that prints the installed tool's version.
--- @type table<string, string[]>
M.tools = {
  bash = { "bash", "--version" },
  zsh = { "zsh", "--version" },
  fish = { "fish", "--version" },
  node = { "node", "--version" },
  python = { "python3", "--version" },
  lua = { "lua", "-v" },
  ruby = { "ruby", "--version" },
  go = { "go", "version" },
  php = { "php", "--version" },
  perl = { "perl", "-e", "print $^V" },
  elixir = { "elixir", "--short-version" },
  openjdk = { "java", "-version" },
  deno = { "deno", "--version" },
  kotlin = { "kotlin", "-version" },
  dart = { "dart", "--version" },
  postgresql = { "psql", "--version" },
  cmake = { "cmake", "--version" },
  godot = { "godot", "--version" },
  julia = { "julia", "--version" },
}

--- Version of the installed tool for `base` (blocking, up to 1 s), or nil.
--- @param base string
--- @return string|nil
function M.tool_version(base)
  local cmd = M.tools[base]
  if not cmd then
    return nil
  end
  local out = M._run(cmd)
  if not out then
    return nil
  end
  -- "go version go1.23.2" / "fish, version 4.0.2" / "v22.11.0": first x.y[.z]
  return out:match "(%d+%.%d+%.%d+)" or out:match "(%d+%.%d+)"
end

-- ---------------------------------------------------------------- language servers

local function settings_of(client)
  return client.settings or (client.config and client.config.settings) or {}
end

--- base -> fun(client): version|nil, for clients whose settings name it.
--- @type table<string, fun(client: table): string|nil>
M.lsp_detectors = {
  lua = function(client)
    if not client.name:find("lua", 1, true) then
      return nil
    end
    local rt = vim.tbl_get(settings_of(client), "Lua", "runtime", "version")
    if type(rt) ~= "string" then
      return nil
    end
    return rt:lower():find "jit" and "5.1" or M.first_version(rt)
  end,
  python = function(client)
    if not client.name:find "pyright" and client.name ~= "pylsp" then
      return nil
    end
    local py = vim.tbl_get(settings_of(client), "python", "pythonPath")
    if type(py) ~= "string" or py == "" then
      return nil
    end
    local out = M._run { py, "--version" }
    return out and M.first_version(out:match "Python%s+([%d%.]+)") or nil
  end,
}

--- Version of `base` named by an attached language server's settings.
--- @param base string
--- @param clients table[] vim.lsp.get_clients{ bufnr = ... }
--- @return string|nil version, string|nil source "lsp:<client>"
function M.from_lsp(base, clients)
  local fn = M.lsp_detectors[base]
  if not fn then
    return nil
  end
  for _, client in ipairs(clients or {}) do
    local ok, v = pcall(fn, client)
    if ok and v then
      return v, "lsp:" .. client.name
    end
  end
  return nil
end

return M
