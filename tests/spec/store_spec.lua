local config = require "devdocs.config"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

describe("store", function()
  local root = tmpdir()
  config.resolve { data_dir = root }
  store.invalidate()

  it("writes files atomically and leaves no temp file behind", function()
    local f = root .. "/nested/dir/a.txt"
    ok(store.write_file(f, "hello"))
    eq("hello", store.read_file(f))
    eq({}, vim.fn.glob(root .. "/nested/dir/*.tmp", false, true))
  end)

  it("distinguishes a missing file from a corrupt one", function()
    local _, err = store.read_json(root .. "/nope.json")
    eq("missing", err)
    store.write_file(root .. "/bad.json", "{not json")
    local tbl, err2 = store.read_json(root .. "/bad.json")
    eq(nil, tbl)
    ok(err2:find("corrupt", 1, true), err2)
  end)

  it("stamps the version on json records", function()
    ok(store.write_json(root .. "/rec.json", { a = 1 }, "meta"))
    eq({ a = 1, version = store.VERSIONS.meta }, store.read_json(root .. "/rec.json"))
  end)

  it("never overwrites a record written by a newer plugin", function()
    store.write_file(root .. "/new.json", vim.json.encode { version = 99, a = 1 })
    local okw, err = store.write_json(root .. "/new.json", { a = 2 }, "meta")
    eq(false, okw)
    ok(err:find("newer", 1, true), err)
    eq(1, store.read_json(root .. "/new.json").a)
  end)

  it("yields default state when the file is missing or corrupt", function()
    local st, err = store.state()
    eq({ version = 1, enabled = {}, recent = {} }, st)
    eq(nil, err)
    store.write_file(paths.state_file(), "garbage")
    local st2, err2 = store.state()
    eq({}, st2.enabled)
    ok(err2 ~= nil)
    os.remove(paths.state_file())
  end)

  it("update_state re-reads before writing so two writers interleave safely", function()
    ok(store.update_state(function(st)
      st.enabled.css = true
      return st
    end))
    -- another instance writes in between
    local other = store.state()
    other.enabled.lua = true
    store.write_json(paths.state_file(), other, "state")
    ok(store.update_state(function(st)
      st.enabled.python = true
      return st
    end))
    eq({ css = true, lua = true, python = true }, store.state().enabled)
  end)

  it("does not hand its callers a shared table", function()
    local a = store.state()
    a.enabled.mutated = true
    eq(nil, store.state().enabled.mutated)
  end)

  it("lists installed docs from meta.json files only", function()
    vim.fn.mkdir(paths.doc_dir "css", "p")
    vim.fn.mkdir(paths.doc_dir "broken", "p")
    vim.fn.mkdir(root .. "/docs/not a slug", "p")
    store.write_json(paths.meta_file "css", { slug = "css", name = "CSS" }, "meta")
    store.invalidate()
    eq({ "css" }, store.installed())
    ok(store.is_installed "css")
    ok(not store.is_installed "broken")
    ok(not store.is_installed "../css")
    eq("CSS", store.meta("css").name)
  end)

  it("round-trips entries through tsv", function()
    local entries = {
      { name = "std::cout", path = "io/cout", type = "Input/output" },
      { name = "assert()", path = "index#pdf-assert", type = "Standard Libraries" },
      { name = "no type", path = "x", type = "" },
    }
    store.write_file(paths.entries_file "css", store.encode_entries(entries))
    store.invalidate "css"
    eq(entries, store.entries "css")
    eq({}, store.entries "missing")
  end)

  it("reads anchors and tolerates a missing file", function()
    store.write_json(paths.anchors_file "css", { pages = { index = { syntax = 12 } } }, "anchors")
    store.invalidate "css"
    eq({ index = { syntax = 12 } }, store.anchors "css")
    eq({}, store.anchors "missing")
  end)

  it("keeps a bounded, de-duplicated recent list", function()
    for i = 1, store.RECENT_MAX + 5 do
      store.push_recent("css", "p" .. i, "P" .. i)
    end
    store.push_recent("css", "p3", "P3")
    local recent = store.state().recent
    eq(store.RECENT_MAX, #recent)
    eq("p3", recent[1].path)
    local seen = {}
    for _, r in ipairs(recent) do
      ok(not seen[r.path], "duplicate " .. r.path)
      seen[r.path] = true
    end
  end)

  it("caches state and refreshes it after update_state", function()
    store.update_state(function(st)
      st.enabled.css = false
      return st
    end)
    local a = store.state()
    eq(false, a.enabled.css)
    a.enabled.css = true -- callers get a copy; mutating it changes nothing
    eq(false, store.state().enabled.css)
    store.update_state(function(st)
      st.enabled.css = nil
      return st
    end)
    eq(nil, store.state().enabled.css)
  end)

  it("tells subscribers when docs or state change", function()
    local n = 0
    store.on_invalidate(function()
      n = n + 1
    end)
    store.invalidate()
    store.update_state(function(st)
      return st
    end)
    eq(2, n)
  end)
end)
