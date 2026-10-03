-- Installs from a file:// "CDN" built in a temp dir, under a throwaway XDG
-- tree (make integration). Never touches the real data dir.
local real = vim.fn.expand "~/.local/share/nvim"
assert(not vim.startswith(vim.fn.stdpath "data", real), "refusing to run against real data")

local config = require "devdocs.config"
local installer = require "devdocs.installer"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local function write(file, content)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  assert(store.write_file(file, content))
end

--- Build <cdn>/<slug>.tar.gz and <cdn>/<slug>/{db,index,meta}.json
local function make_doc(cdn, slug, name)
  local dir = cdn .. "/" .. slug
  local db = {
    index = '<h1 id="top">' .. name .. ' manual</h1><p>Intro</p><h2 id="f">f()</h2><pre data-language="lua">f(1)</pre>',
    ["lib/io"] = "<h1>io</h1><p>Input and output for " .. name .. ".</p>",
  }
  local index = {
    entries = {
      { name = "f()", path = "index#f", type = "API" },
      { name = "io", path = "lib/io", type = "Library" },
    },
    types = { { name = "API", count = 1, slug = "api" } },
  }
  local meta = { name = name, slug = slug, type = "lua", version = "5.4", release = "5.4.1", mtime = 100, db_size = 1 }
  write(dir .. "/db.json", vim.json.encode(db))
  write(dir .. "/index.json", vim.json.encode(index))
  write(dir .. "/meta.json", vim.json.encode(meta))
  local res = vim.system({ "tar", "-czf", cdn .. "/" .. slug .. ".tar.gz", "-C", dir, "." }):wait()
  assert(res.code == 0, res.stderr)
  return meta
end

local function wait_cb(fn)
  local got
  fn(function(ok, err)
    got = { ok = ok, err = err }
  end)
  assert(
    vim.wait(20000, function()
      return got ~= nil
    end),
    "callback never ran"
  )
  return got.ok, got.err
end

describe("installer (integration)", function()
  local data = vim.fn.stdpath "data" .. "/devdocs"
  local cdn = tmpdir()
  local lua_meta = make_doc(cdn, "lua~5.4", "Lua")
  make_doc(cdn, "css", "CSS")
  make_doc(cdn, "lua~5.1", "Lua")

  config.resolve {
    data_dir = data,
    notify = false,
    install = {
      tarball_url = "file://" .. cdn .. "/{slug}.tar.gz",
      doc_url = "file://" .. cdn .. "/{slug}/{file}",
      max_jobs = 1,
    },
  }
  store.invalidate()

  local events = {}
  installer.on(function(event, job)
    events[#events + 1] = event .. ":" .. job.slug .. ":" .. job.stage
  end)

  it("installs a doc from a tarball and enables it", function()
    local okv, err = wait_cb(function(cb)
      installer.install("lua~5.4", nil, cb)
    end)
    eq(true, okv, err)
    local pages = paths.pages_dir "lua~5.4"
    eq(
      { "# Lua manual", "", "Intro", "", "## f()", "", "```lua", "f(1)", "```" },
      vim.fn.readfile(pages .. "/index.md")
    )
    ok(vim.uv.fs_stat(pages .. "/lib/io.md"))
    eq({ "lua~5.4" }, store.installed())
    local meta = store.meta "lua~5.4"
    eq("Lua", meta.name)
    eq(lua_meta.mtime, meta.mtime)
    eq(2, meta.page_count)
    eq(2, meta.entry_count)
    eq(
      { { name = "f()", path = "index#f", type = "API" }, { name = "io", path = "lib/io", type = "Library" } },
      store.entries "lua~5.4"
    )
    eq({ index = { top = 1, f = 5 } }, store.anchors "lua~5.4")
    eq(true, store.state().enabled["lua~5.4"])
    eq({}, vim.fn.glob(data .. "/tmp/*", false, true), "staging dir left behind")
    ok(vim.tbl_contains(events, "start:lua~5.4:queued"), vim.inspect(events))
    ok(vim.tbl_contains(events, "done:lua~5.4:done"), vim.inspect(events))
  end)

  it("skips an installed doc unless forced, and force replaces the tree", function()
    local okv, err = wait_cb(function(cb)
      installer.install("lua~5.4", nil, cb)
    end)
    eq(true, okv)
    eq("already installed", err)
    write(paths.pages_dir "lua~5.4" .. "/stale.md", "old")
    okv, err = wait_cb(function(cb)
      installer.install("lua~5.4", { force = true }, cb)
    end)
    eq(true, okv, err)
    eq(nil, vim.uv.fs_stat(paths.pages_dir "lua~5.4" .. "/stale.md"))
    ok(vim.uv.fs_stat(paths.pages_dir "lua~5.4" .. "/index.md"))
  end)

  it("installs from db.json + index.json when source = json, taking meta from the manifest entry", function()
    config.resolve {
      data_dir = data,
      notify = false,
      install = { source = "json", doc_url = "file://" .. cdn .. "/{slug}/{file}", max_jobs = 1 },
    }
    local doc = { name = "CSS", slug = "css", type = "mdn", version = "", release = "", mtime = 7, db_size = 3 }
    local okv, err = wait_cb(function(cb)
      installer.install("css", { doc = doc }, cb)
    end)
    eq(true, okv, err)
    eq("CSS", store.meta("css").name)
    eq(7, store.meta("css").mtime)
    eq({ "css", "lua~5.4" }, store.installed())
    config.resolve {
      data_dir = data,
      notify = false,
      install = { tarball_url = "file://" .. cdn .. "/{slug}.tar.gz", max_jobs = 1 },
    }
  end)

  it("reports a missing doc as an error and leaves nothing behind", function()
    local okv, err = wait_cb(function(cb)
      installer.install("nope", nil, cb)
    end)
    eq(false, okv)
    ok(err:find("download failed", 1, true), err)
    eq(nil, vim.uv.fs_stat(paths.doc_dir "nope"))
    eq({}, vim.fn.glob(data .. "/tmp/*", false, true))
    ok(vim.tbl_contains(events, "error:nope:error"), vim.inspect(events))
  end)

  it("install_many summarises successes and failures", function()
    local summary
    installer.install_many({ "lua~5.4", "missing" }, { force = true }, function(s)
      summary = s
    end)
    assert(vim.wait(20000, function()
      return summary ~= nil
    end))
    eq(1, summary.ok)
    eq(1, summary.failed)
    ok(summary.errors.missing ~= nil)
  end)

  it("finds outdated docs against a manifest", function()
    eq({ "css" }, installer.outdated { { slug = "css", mtime = 8 }, { slug = "lua~5.4", mtime = 100 } })
  end)

  it("uninstalls and refuses bad input", function()
    eq(true, (installer.uninstall "css"))
    eq(nil, vim.uv.fs_stat(paths.doc_dir "css"))
    eq(nil, store.state().enabled.css)
    eq({ "lua~5.4" }, store.installed())
    local okv, err = installer.uninstall "css"
    eq(false, okv)
    eq("not installed", err)
    ok(not installer.uninstall "../lua~5.4")
  end)

  it("disk_usage sums installed doc dirs and ignores missing ones", function()
    local bytes = installer.disk_usage { "lua~5.4", "nope" }
    ok(type(bytes) == "number" and bytes > 0, vim.inspect(bytes))
    eq(nil, installer.disk_usage {})
    eq(nil, installer.disk_usage { "nope" })
  end)

  it("uninstall_many deletes several docs and reports the ones it could not", function()
    for _, slug in ipairs { "css", "lua~5.1" } do
      local okv, err = wait_cb(function(cb)
        installer.install(slug, { force = true }, cb)
      end)
      eq(true, okv, err)
    end
    eq({ "css", "lua~5.1", "lua~5.4" }, store.installed())
    local n, errors = installer.uninstall_many { "css", "lua~5.1", "nope", "../x" }
    eq(2, n)
    eq(2, #errors)
    ok(errors[1]:find("nope", 1, true), errors[1])
    ok(errors[2]:find("invalid", 1, true), errors[2])
    eq({ "lua~5.4" }, store.installed())
  end)

  it("prune deletes every installed version but the current one", function()
    local okv, err = wait_cb(function(cb)
      installer.install("lua~5.1", { force = true }, cb)
    end)
    eq(true, okv, err)
    local docs = { { slug = "lua~5.4", version = "5.4" }, { slug = "lua~5.1", version = "5.1" } }
    local done
    require("devdocs").prune {
      yes = true,
      docs = docs,
      on_done = function(n, errors)
        done = { n, errors }
      end,
    }
    eq({ 1, {} }, done)
    eq({ "lua~5.4" }, store.installed())
    -- one version left: nothing to do, nothing deleted
    done = nil
    require("devdocs").prune { yes = true, docs = docs, base = "lua" }
    eq(nil, done)
    eq({ "lua~5.4" }, store.installed())
  end)

  it("status lists jobs and clear_finished drops the settled ones", function()
    ok(#installer.status() > 0)
    installer.clear_finished()
    eq({}, installer.status())
    ok(not installer.is_busy())
  end)
end)
