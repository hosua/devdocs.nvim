local config = require "devdocs.config"
local fetch = require "devdocs.fetch"
local releases = require "devdocs.releases"
local store = require "devdocs.store"

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h") .. "/fixtures"

local function fixture(product)
  return store.read_file(fixtures .. "/eol_" .. product .. ".json")
end

local function cycles_of(product)
  return releases.normalize(vim.json.decode(fixture(product)))
end

local function doc(slug, version, release)
  return { slug = slug, name = slug, version = version or "", release = release or "", mtime = 1 }
end

--- Replace fetch.download with a stub serving `bodies[product]` (nil = 404).
--- Answers on the next loop iteration, like curl would. Returns a probe.
local function stub_fetch(bodies)
  local probe = { calls = {}, inflight = 0, max_inflight = 0 }
  local real = fetch.download
  fetch.download = function(url, dest, _, cb)
    local product = url:match "/products/([^/]+)$" or url:match "/products$" and "_index"
    probe.calls[#probe.calls + 1] = product
    probe.inflight = probe.inflight + 1
    probe.max_inflight = math.max(probe.max_inflight, probe.inflight)
    vim.defer_fn(function()
      probe.inflight = probe.inflight - 1
      local body = bodies[product]
      if not body then
        cb { ok = false, status = 404, err = "404" }
        return
      end
      vim.fn.mkdir(vim.fs.dirname(dest), "p")
      store.write_file(dest, body)
      cb { ok = true, status = 200 }
    end, 5)
    return nil
  end
  probe.restore = function()
    fetch.download = real
  end
  return probe
end

local INDEX = vim.json.encode {
  result = {
    { name = "nodejs", aliases = { "node" } },
    { name = "python", aliases = {} },
    { name = "angular", aliases = {} },
    { name = "newthing", aliases = { "nt" } },
  },
}

describe("releases", function()
  describe("normalize", function()
    it("reads the v1 product shape", function()
      local c = cycles_of "python"
      ok(#c > 10)
      eq({ cycle = "3.12", date = "2023-10-02", latest = c[3].latest }, c[3])
      ok(c[3].latest:match "^3%.12%.%d+$", c[3].latest)
    end)

    it("reads the legacy /api/<product>.json shape and drops cycles without a date", function()
      local c = releases.normalize {
        { cycle = "22", releaseDate = "2026-06-03", latest = "22.2.1" },
        { cycle = 21, releaseDate = "2025-11-19", latest = "21.2.25" },
        { cycle = "0", releaseDate = vim.NIL },
        "junk",
      }
      eq({
        { cycle = "22", date = "2026-06-03", latest = "22.2.1" },
        { cycle = "21", date = "2025-11-19", latest = "21.2.25" },
      }, c)
    end)

    it("returns an empty list for anything else", function()
      eq({}, releases.normalize(nil))
      eq({}, releases.normalize { result = "nope" })
      eq({}, releases.normalize "x")
    end)
  end)

  describe("match", function()
    local python, node, angular = cycles_of "python", cycles_of "nodejs", cycles_of "angular"

    it("matches a versioned slug to its cycle", function()
      eq({ date = "2023-10-02", exact = true, cycle = "3.12" }, releases.match(python, doc("python~3.12", "3.12")))
      eq("2.7", releases.match(python, doc("python~2.7", "2.7")).cycle)
      eq("2026-06-03", releases.match(angular, doc("angular~22", "22")).date)
    end)

    it("strips LTS and other suffixes from the version", function()
      eq("22", releases.match(node, doc("node~22_lts", "22 LTS", "22.20.0")).cycle)
      eq("18", releases.match(node, doc("node~18_lts", "18 LTS")).cycle)
      eq("3.12", releases.match(python, doc("python~3.12", "3.12.x")).cycle)
    end)

    it("falls back to major.minor, then the release, then the major", function()
      eq("3.12", releases.match(python, doc("python~3.12.4", "3.12.4")).cycle)
      local cycles = {
        { cycle = "3.0", date = "2020-12-25", latest = "3.0.7" },
        { cycle = "2.7", date = "2019-12-25", latest = "2.7.8" },
        { cycle = "4", date = "2025-01-01", latest = "4.2.0" },
      }
      -- ruby~3 is version "3", release "3.0.0": no cycle "3", the release names "3.0"
      eq("3.0", releases.match(cycles, doc("ruby~3", "3", "3.0.0")).cycle)
      -- only the major is known upstream
      eq("4", releases.match(cycles, doc("x~4.1", "4.1")).cycle)
    end)

    it("matches an unversioned doc by its release", function()
      eq("26", releases.match(node, doc("node", "", "26.3.1")).cycle)
      eq("22", releases.match(angular, doc("angular", "", "22.0.0")).cycle)
      eq("3.14", releases.match(python, doc("python", "", "3.14.7")).cycle)
    end)

    it("prefers the cycle whose latest equals the release", function()
      local cycles = {
        { cycle = "2.0.0", date = "2013-02-24", latest = "2.0.0p648" },
        { cycle = "2", date = "2012-01-01", latest = "2.9" },
      }
      eq("2.0.0", releases.match(cycles, doc("x", "", "2.0.0p648")).cycle)
    end)

    it("never lets a prefix match across a digit boundary", function()
      local cycles = { { cycle = "2", date = "2012-01-01", latest = "2.9" } }
      eq(nil, releases.match(cycles, doc("x", "", "22.0.0")))
    end)

    it("returns nil when nothing fits", function()
      eq(nil, releases.match(python, doc("python~9.9", "9.9", "9.9.0")))
      eq(nil, releases.match(python, doc("python", "", "")))
      eq(nil, releases.match({}, doc("python~3.12", "3.12")))
      eq(nil, releases.match(python, doc("yarn~classic", "Classic", "")))
    end)
  end)

  describe("installed_doc", function()
    local node = cycles_of "nodejs"
    -- meta.json carries `version` = its own schema version (1), the doc
    -- version is meta.doc_version
    local META = { version = 1, doc_version = "22 LTS", release = "22.20.0", name = "Node.js", type = "node" }

    it("dates an installed doc by meta.doc_version / meta.release, never meta.version", function()
      local d = releases.installed_doc(doc("node~22_lts", "22 LTS", "22.23.0"), META)
      eq("22 LTS", d.version)
      eq("22.20.0", d.release)
      eq("node~22_lts", d.slug)
      eq("22", releases.match(node, d).cycle)
      local current = releases.installed_doc(
        doc("node", "", "26.3.1"),
        { version = 1, doc_version = "", release = "26.3.1", name = "Node.js" }
      )
      eq("26", releases.match(node, current).cycle)
    end)

    it("builds a doc from meta alone for a slug the docs list dropped", function()
      local d = releases.installed_doc(nil, META, "node~22_lts")
      eq({ "node~22_lts", "22 LTS", "22.20.0", "Node.js", "node" }, { d.slug, d.version, d.release, d.name, d.type })
    end)

    it("keeps the manifest doc when there is no meta, without mutating it", function()
      local m = doc("node~22_lts", "22 LTS", "22.23.0")
      eq(m, releases.installed_doc(m, nil))
      releases.installed_doc(m, META)
      eq("22.23.0", m.release)
    end)
  end)

  describe("product_for", function()
    it("uses the static table, then the products index by name, alias or dashes", function()
      eq("nodejs", releases.product_for "node")
      eq("ansible-core", releases.product_for "ansible")
      eq("docker-engine", releases.product_for "docker")
      eq(nil, releases.product_for "css")
      local index = releases.index_from(vim.json.decode(INDEX))
      eq("newthing", releases.product_for("newthing", index))
      eq("newthing", releases.product_for("nt", index))
      eq(nil, releases.product_for("css", index))
      local dashed = { ["some-tool"] = "some-tool" }
      eq("some-tool", releases.product_for("some_tool", dashed))
    end)

    it("only maps to safe product names", function()
      ok(releases.valid_product "nodejs")
      ok(releases.valid_product "apache-http-server")
      ok(not releases.valid_product "../etc")
      ok(not releases.valid_product "")
      for base, product in pairs(releases.PRODUCTS) do
        ok(releases.valid_product(product), base .. " -> " .. product)
      end
    end)
  end)

  describe("cache and fetch", function()
    local root

    local function setup(opts)
      root = tmpdir()
      config.resolve(vim.tbl_deep_extend("force", { data_dir = root }, opts or {}))
      releases._reset()
    end

    local DOCS = {
      doc("python~3.12", "3.12", "3.12.9"),
      doc("node~22_lts", "22 LTS", "22.20.0"),
      doc("angular", "", "22.0.0"),
      doc("css", "", ""),
    }

    local function wait_calls(seen, n)
      ok(
        vim.wait(5000, function()
          return #seen >= n
        end),
        ("callback ran %d times, wanted %d"):format(#seen, n)
      )
    end

    it("caches nothing at first and is not fresh", function()
      setup()
      eq({}, releases.cached_dates(DOCS))
      eq(nil, releases.read_cache "python")
    end)

    it("answers from cache first, then fetches the missing products concurrently", function()
      setup()
      local probe = stub_fetch {
        python = fixture "python",
        nodejs = fixture "nodejs",
        angular = fixture "angular",
        _index = INDEX,
      }
      local seen = {}
      releases.dates_for(DOCS, function(map)
        seen[#seen + 1] = map
      end, { now = 1000 })
      eq(1, #seen, "cached answer is synchronous")
      eq({}, seen[1])
      wait_calls(seen, 2)
      probe.restore()
      local map = seen[2]
      eq({ date = "2023-10-02", exact = true, cycle = "3.12" }, map["python~3.12"])
      eq("2024-04-24", map["node~22_lts"].date)
      eq("2026-06-03", map["angular"].date)
      eq(nil, map["css"])
      ok(probe.max_inflight <= releases.MAX_JOBS)
      table.sort(probe.calls)
      eq({ "_index", "angular", "nodejs", "python" }, probe.calls)
      -- and the cache now answers without the network
      eq(map, releases.cached_dates(DOCS))
      local rec = releases.read_cache "python"
      eq(1000, rec.fetched_at)
      eq({ products = 3, oldest = 1000, enabled = true }, releases.cache_status())
    end)

    it("does not refetch a fresh cache, nor twice in a session", function()
      local probe = stub_fetch {}
      local seen = {}
      releases.dates_for(DOCS, function(map)
        seen[#seen + 1] = map
      end, { now = 1000 + 60 })
      eq(1, #seen)
      ok(seen[1]["python~3.12"])
      vim.wait(50)
      eq({}, probe.calls)
      probe.restore()
    end)

    it("refetches stale products once per session and keeps the stale data offline", function()
      releases._reset()
      local later = 1000 + releases.TTL + 1
      ok(not releases.is_fresh(releases.read_cache "python", later))
      local probe = stub_fetch {} -- offline: every request fails
      local seen = {}
      releases.dates_for(DOCS, function(map)
        seen[#seen + 1] = map
      end, { now = later })
      eq(1, #seen)
      eq("2023-10-02", seen[1]["python~3.12"].date)
      ok(vim.wait(5000, function()
        return #probe.calls >= 4 and probe.inflight == 0
      end))
      vim.wait(30)
      eq(1, #seen, "no second callback when nothing new arrived")
      -- the stale record survives
      eq("python", releases.read_cache("python").product)
      local before = #probe.calls
      releases.dates_for(DOCS, function() end, { now = later })
      vim.wait(30)
      eq(before, #probe.calls, "a product is attempted at most once per session")
      probe.restore()
    end)

    it("limits concurrency", function()
      setup()
      local bodies, docs = {}, {}
      for _, p in ipairs { "python", "go", "rust", "ruby", "php", "django", "vue", "react" } do
        bodies[p] = fixture "python"
        docs[#docs + 1] = doc(p == "python" and p or (p .. "~1"), "1")
      end
      bodies._index = INDEX
      local probe = stub_fetch(bodies)
      local seen = {}
      releases.dates_for(docs, function(map)
        seen[#seen + 1] = map
      end)
      wait_calls(seen, 2)
      probe.restore()
      ok(probe.max_inflight <= releases.MAX_JOBS, "max in flight " .. probe.max_inflight)
      ok(#probe.calls >= 8)
    end)

    it("ignores a garbage response without caching it", function()
      setup()
      local probe = stub_fetch { python = "not json", _index = INDEX }
      local seen = {}
      releases.dates_for({ doc("python~3.12", "3.12") }, function(map)
        seen[#seen + 1] = map
      end)
      ok(vim.wait(5000, function()
        return #probe.calls >= 1 and probe.inflight == 0
      end))
      vim.wait(30)
      probe.restore()
      eq(nil, releases.read_cache "python")
      eq(1, #seen)
    end)

    it("makes no network calls when list.release_dates is false", function()
      setup { list = { release_dates = false } }
      local probe = stub_fetch { python = fixture "python" }
      local seen = {}
      releases.dates_for(DOCS, function(map)
        seen[#seen + 1] = map
      end)
      vim.wait(30)
      probe.restore()
      eq({ {} }, seen)
      eq({}, probe.calls)
    end)
  end)
end)
