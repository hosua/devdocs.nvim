--- Releases: when each doc's version line was actually released upstream.
--- docs.json only has `release` (a version string) and `mtime` (when DevDocs
--- built the doc), so the dates come from endoflife.date's v1 API:
---
---   https://endoflife.date/api/v1/products/<product>
---     result.releases[] = { name = "3.12", releaseDate = "2023-10-02", latest = { name = "3.12.9" } }
---   https://endoflife.date/api/v1/products   (name + aliases of every product)
---
--- One JSON per product is cached under <data_dir>/releases/ for TTL seconds.
--- Fetches never block and never notify: on failure the stale cache (or
--- nothing) is used and the list falls back to the DevDocs build date.
local config = require "devdocs.config"
local fetch = require "devdocs.fetch"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local M = {}

M.VERSION = 1
M.API = "https://endoflife.date/api/v1/products"
M.TTL = 7 * 86400
M.MAX_JOBS = 4

--- Cache name of the products index; product names cannot start with "_".
local INDEX = "_products"

--- DevDocs base slug -> endoflife.date product, each one checked against the
--- live API. Bases missing here are looked up in the products index (by name,
--- alias, or with "_" read as "-"), so new upstream products work unlisted.
M.PRODUCTS = {
  angular = "angular",
  angularjs = "angularjs",
  ansible = "ansible-core", -- devdocs' ansible~2.x are ansible-core versions, not the community package
  apache_http_server = "apache-http-server",
  bazel = "bazel",
  bootstrap = "bootstrap",
  bun = "bun",
  cakephp = "cakephp",
  chef = "chef-infra-client",
  coldfusion = "coldfusion",
  composer = "composer",
  couchdb = "apache-couchdb",
  deno = "deno",
  django = "django",
  docker = "docker-engine",
  drupal = "drupal",
  duckdb = "duckdb",
  electron = "electron",
  elixir = "elixir",
  ember = "emberjs",
  erlang = "erlang",
  eslint = "eslint",
  express = "express",
  go = "go",
  godot = "godot",
  groovy = "apache-groovy",
  grunt = "grunt",
  haproxy = "haproxy",
  haskell = "ghc",
  jekyll = "jekyll",
  jquery = "jquery",
  jqueryui = "jquery-ui",
  julia = "julia",
  kotlin = "kotlin",
  kubectl = "kubernetes",
  kubernetes = "kubernetes",
  laravel = "laravel",
  lua = "lua",
  mariadb = "mariadb",
  nextjs = "nextjs",
  nginx = "nginx",
  nix = "nix",
  node = "nodejs",
  numpy = "numpy",
  openjdk = "oracle-jdk", -- Java SE GA dates; the only product that also lists 8
  opentofu = "opentofu",
  perl = "perl",
  phoenix = "phoenix-framework",
  php = "php",
  postgresql = "postgresql",
  powershell = "powershell",
  python = "python",
  qt = "qt",
  rabbitmq = "rabbitmq",
  rails = "rails",
  react = "react",
  react_native = "react-native",
  redis = "redis",
  ruby = "ruby",
  rust = "rust",
  saltstack = "salt",
  scala = "scala",
  spring_boot = "spring-boot",
  sqlite = "sqlite",
  svelte = "svelte",
  symfony = "symfony",
  tailwindcss = "tailwind-css",
  terraform = "terraform",
  twig = "twig",
  varnish = "vinyl-cache",
  vue = "vue",
  wagtail = "wagtail",
  wordpress = "wordpress",
  yarn = "yarn",
}

--- @class DevDocsReleaseCycle
--- @field cycle string   "3.12"
--- @field date string    "2023-10-02" (when the cycle was first released)
--- @field latest string|nil "3.12.9"

--- @class DevDocsReleaseDate
--- @field date string   "YYYY-MM-DD"
--- @field exact boolean always true: an upstream release date, not a build date
--- @field cycle string  the endoflife.date cycle it came from

--- @class DevDocsReleaseCache
--- @field version integer
--- @field fetched_at integer
--- @field product string
--- @field cycles DevDocsReleaseCycle[]

local attempted = {} -- product (or INDEX) -> true once requested this session
local memo = {} -- cache file -> record, so a list redraw does not re-read disk

--- Why the last fetch failed (for :checkhealth); fetch errors are never notified.
--- @type string|nil
M.last_error = nil

--- Forget the session state (tests).
function M._reset()
  attempted, memo, M.last_error = {}, {}, nil
end

-- ---------------------------------------------------------------- pure helpers

local function str(v)
  if type(v) == "string" then
    return v
  elseif type(v) == "number" then
    return tostring(v)
  end
  return nil
end

--- @param product string
--- @return boolean
function M.valid_product(product)
  return type(product) == "string" and product:match "^[%w][%w%-%.]*$" ~= nil and not product:find("..", 1, true)
end

--- Either API shape -> cycles that carry a release date, in API order.
--- v1:     { result = { releases = { { name, releaseDate, latest = { name } } } } }
--- legacy: { { cycle, releaseDate, latest } }   (/api/<product>.json)
--- @param json any decoded response
--- @return DevDocsReleaseCycle[]
function M.normalize(json)
  if type(json) ~= "table" then
    return {}
  end
  local rows, v1
  if type(json.result) == "table" and type(json.result.releases) == "table" then
    rows, v1 = json.result.releases, true
  elseif vim.islist(json) then
    rows = json
  else
    return {}
  end
  local out = {}
  for _, r in ipairs(rows) do
    if type(r) == "table" then
      local cycle = str(v1 and r.name or r.cycle)
      local date = str(r.releaseDate)
      local latest
      if v1 then
        latest = type(r.latest) == "table" and str(r.latest.name) or nil
      else
        latest = str(r.latest)
      end
      if cycle and cycle ~= "" and date and date:match "^%d%d%d%d%-%d%d%-%d%d$" then
        out[#out + 1] = { cycle = cycle, date = date, latest = latest }
      end
    end
  end
  return out
end

--- The numeric head of a devdocs version: "22 LTS" -> "22", "3.12.x" -> "3.12",
--- "2.13 Library" -> "2.13", "Classic" -> nil.
--- @param v string|nil
--- @return string|nil
local function version_key(v)
  local k = tostring(v or ""):match "^v?(%d[%d%.]*)"
  if not k then
    return nil
  end
  return (k:gsub("%.+$", ""))
end

--- The cycle a doc documents, and its release date. Tries, in order: the
--- doc's version as a cycle ("3.12"), its major.minor, the cycle whose latest
--- is the doc's release, the longest cycle the release starts with ("3.14"
--- for "3.14.7"), and finally the version's major.
--- @param cycles DevDocsReleaseCycle[]
--- @param doc { version?: string, release?: string }
--- @return DevDocsReleaseDate|nil
function M.match(cycles, doc)
  if type(cycles) ~= "table" or #cycles == 0 then
    return nil
  end
  local by = {}
  for _, c in ipairs(cycles) do
    by[c.cycle] = by[c.cycle] or c
  end
  local function hit(c)
    return c and { date = c.date, exact = true, cycle = c.cycle } or nil
  end
  local v = version_key(doc.version)
  if v then
    if by[v] then
      return hit(by[v])
    end
    local mm = v:match "^(%d+%.%d+)"
    if mm and by[mm] then
      return hit(by[mm])
    end
  end
  local rel = doc.release or ""
  if rel ~= "" then
    for _, c in ipairs(cycles) do
      if c.latest == rel then
        return hit(c)
      end
    end
    local best
    for _, c in ipairs(cycles) do
      if (rel == c.cycle or vim.startswith(rel, c.cycle .. ".")) and (not best or #c.cycle > #best.cycle) then
        best = c
      end
    end
    if best then
      return hit(best)
    end
  end
  if v then
    local major = v:match "^(%d+)"
    if major ~= v and by[major] then
      return hit(by[major])
    end
  end
  return nil
end

--- The doc to date for an installed slug: the installed release, not the
--- docs list's. meta.json's `version` is its own schema version (1), so the
--- doc version is meta.doc_version; merging meta over the doc wholesale
--- would date every installed doc as cycle "1". Returns a new table.
--- @param doc DevDocsDoc|nil manifest entry (nil when the list dropped it)
--- @param meta table|nil installed meta.json
--- @param slug string|nil when `doc` is nil
--- @return table
function M.installed_doc(doc, meta, slug)
  if type(meta) ~= "table" then
    return doc
  end
  local out = vim.deepcopy(doc or {})
  out.slug = out.slug or slug
  out.name = out.name or meta.name
  out.type = out.type or meta.type
  if meta.doc_version ~= nil then
    out.version = meta.doc_version
  end
  if (meta.release or "") ~= "" then
    out.release = meta.release
  end
  out.mtime = meta.mtime or out.mtime
  return out
end

--- Products index response -> { name or alias -> product }.
--- @param json any decoded https://endoflife.date/api/v1/products
--- @return table<string, string>
function M.index_from(json)
  local out = {}
  if type(json) ~= "table" or type(json.result) ~= "table" then
    return out
  end
  for _, p in ipairs(json.result) do
    local name = type(p) == "table" and str(p.name)
    if name and M.valid_product(name) then
      out[name] = name
      for _, a in ipairs(type(p.aliases) == "table" and p.aliases or {}) do
        if type(a) == "string" and out[a] == nil then
          out[a] = name
        end
      end
    end
  end
  return out
end

--- @param base string devdocs base slug ("node")
--- @param index table<string, string>|nil from index_from()
--- @return string|nil product
function M.product_for(base, index)
  local p = M.PRODUCTS[base]
  if not p and index then
    p = index[base] or index[(base:gsub("_", "-"))]
  end
  return (p and M.valid_product(p)) and p or nil
end

local function base_of(slug)
  return (slug:match "^([^~]+)") or slug
end

-- ---------------------------------------------------------------- cache on disk

local function cache_file(name)
  return paths.releases_dir() .. "/" .. name .. ".json"
end

local function load(name)
  local file = cache_file(name)
  if memo[file] == nil then
    local rec = store.read_json(file)
    if type(rec) == "table" and rec.version == M.VERSION and type(rec.fetched_at) == "number" then
      memo[file] = rec
    else
      memo[file] = false
    end
  end
  return memo[file] or nil
end

--- @param product string
--- @return DevDocsReleaseCache|nil
function M.read_cache(product)
  local rec = load(product)
  return (rec and type(rec.cycles) == "table") and rec or nil
end

--- @return table<string, string>|nil index, integer|nil fetched_at
local function read_index()
  local rec = load(INDEX)
  if rec and type(rec.products) == "table" then
    return rec.products, rec.fetched_at
  end
  return nil
end

--- @param rec { fetched_at: integer }|nil
--- @param now integer|nil
--- @return boolean
function M.is_fresh(rec, now)
  return rec ~= nil and type(rec.fetched_at) == "number" and (now or os.time()) - rec.fetched_at < M.TTL
end

local function write(name, rec)
  local ok, err = store.write_file(cache_file(name), vim.json.encode(rec))
  if ok then
    memo[cache_file(name)] = rec
  else
    M.last_error = ("could not cache %s: %s"):format(name, tostring(err))
  end
end

--- Dates for every doc the cache can answer, without touching the network.
--- @param docs DevDocsDoc[]
--- @return table<string, DevDocsReleaseDate>
function M.cached_dates(docs)
  local index = read_index()
  local out = {}
  for _, d in ipairs(docs or {}) do
    local product = type(d.slug) == "string" and M.product_for(base_of(d.slug), index)
    local rec = product and M.read_cache(product)
    local hit = rec and M.match(rec.cycles, d)
    if hit then
      out[d.slug] = hit
    end
  end
  return out
end

--- What the cache knows about (for :checkhealth).
--- @return { products: integer, oldest: integer|nil, enabled: boolean }
function M.cache_status()
  local count, oldest = 0, nil
  for name, kind in vim.fs.dir(paths.releases_dir()) do
    if kind == "file" and name:match "%.json$" and not vim.startswith(name, INDEX) then
      local rec = M.read_cache((name:gsub("%.json$", "")))
      if rec then
        count = count + 1
        oldest = math.min(oldest or rec.fetched_at, rec.fetched_at)
      end
    end
  end
  return { products = count, oldest = oldest, enabled = config.get().list.release_dates }
end

-- ---------------------------------------------------------------- fetching

--- Download one API document; `cb(json)` on the main loop, nil on any failure.
local function download(name, cb)
  local cfg = config.get()
  local url = name == INDEX and M.API or (M.API .. "/" .. name)
  local tmp = paths.releases_dir() .. "/" .. name .. ".download.json"
  fetch.download(url, tmp, { curl = cfg.install.curl, retries = 1, timeout = 20 }, function(res)
    vim.schedule(function()
      if not res.ok then
        M.last_error = ("%s: %s"):format(url, tostring(res.err))
        cb(nil)
        return
      end
      local json, err = store.read_json(tmp)
      os.remove(tmp)
      if not json then
        M.last_error = ("%s: %s"):format(url, tostring(err))
      end
      cb(json)
    end)
  end)
end

--- Upstream release dates for `docs`. `cb(map)` runs at once with what the
--- cache knows, then, when anything new was fetched, once more with the fuller
--- map. Missing or stale products are fetched at most once per session,
--- MAX_JOBS at a time. With `list.release_dates = false` it answers `{}` once.
--- @param docs DevDocsDoc[]
--- @param cb fun(map: table<string, DevDocsReleaseDate>)
--- @param opts { now?: integer }|nil
function M.dates_for(docs, cb, opts)
  opts = opts or {}
  if not config.get().list.release_dates then
    cb {}
    return
  end
  docs = docs or {}
  local now = opts.now or os.time()
  cb(M.cached_dates(docs))

  local queue, active, changed = {}, 0, false
  local function wanted(name, rec)
    return not attempted[name] and not M.is_fresh(rec, now)
  end
  local function enqueue(name, on_json)
    attempted[name] = true
    queue[#queue + 1] = { name = name, on_json = on_json }
  end
  local function save_product(product)
    return function(json)
      local cycles = M.normalize(json)
      if #cycles > 0 then
        write(product, { version = M.VERSION, fetched_at = now, product = product, cycles = cycles })
        changed = true
      end
    end
  end
  -- every product the docs map to with `index`; queued when missing or stale
  local function enqueue_products(index)
    local seen = {}
    for _, d in ipairs(docs) do
      local product = type(d.slug) == "string" and M.product_for(base_of(d.slug), index)
      if product and not seen[product] then
        seen[product] = true
        if wanted(product, M.read_cache(product)) then
          enqueue(product, save_product(product))
        end
      end
    end
  end

  local pump
  local function done_one()
    active = active - 1
    pump()
  end
  pump = function()
    while active < M.MAX_JOBS and #queue > 0 do
      local job = table.remove(queue, 1)
      active = active + 1
      download(job.name, function(json)
        job.on_json(json)
        done_one()
      end)
    end
    if active == 0 and #queue == 0 and changed then
      changed = false
      cb(M.cached_dates(docs))
    end
  end

  local index, index_at = read_index()
  local unmapped = false
  for _, d in ipairs(docs) do
    if type(d.slug) == "string" and not M.PRODUCTS[base_of(d.slug)] then
      unmapped = true
      break
    end
  end
  if unmapped and wanted(INDEX, index and { fetched_at = index_at } or nil) then
    enqueue(INDEX, function(json)
      local fresh = M.index_from(json)
      if next(fresh) then
        write(INDEX, { version = M.VERSION, fetched_at = now, products = fresh })
        index = fresh
      end
      -- products only the new index knows about
      enqueue_products(index)
    end)
  end
  enqueue_products(index)
  pump()
end

return M
