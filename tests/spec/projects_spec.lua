local config = require "devdocs.config"
local projects = require "devdocs.projects"
local store = require "devdocs.store"

describe("projects", function()
  local data = tmpdir()
  config.resolve { data_dir = data }
  projects.reset_session()

  local function counting(v, files, source)
    local calls = 0
    return function()
      calls = calls + 1
      return v, files, source
    end, function()
      return calls
    end
  end

  it("computes once, then serves from the session and from disk", function()
    local root = tmpdir()
    vim.fn.writefile({ "v20" }, root .. "/.nvmrc")
    local compute, calls = counting("20", { root .. "/.nvmrc", root .. "/.node-version" }, "file:.nvmrc")
    eq({ "20", "file:.nvmrc" }, { projects.version(root, "node", compute) })
    eq({ "20", "file:.nvmrc" }, { projects.version(root, "node", compute) })
    eq(1, calls())
    projects.reset_session()
    eq({ "20", "file:.nvmrc" }, { projects.version(root, "node", compute) })
    eq(1, calls(), "a new session reads projects.json instead of detecting again")
    ok(vim.uv.fs_stat(data .. "/projects.json"), "written outside the project")
  end)

  it("caches a nil result too", function()
    local root = tmpdir()
    local compute, calls = counting(nil, { root .. "/.python-version" }, nil)
    eq(nil, projects.version(root, "python", compute))
    projects.reset_session()
    eq(nil, projects.version(root, "python", compute))
    eq(1, calls())
  end)

  it("re-detects when a fingerprinted file changes", function()
    local root = tmpdir()
    vim.fn.writefile({ "v20" }, root .. "/.nvmrc")
    local compute, calls = counting("20", { root .. "/.nvmrc" }, "file:.nvmrc")
    projects.version(root, "node", compute)
    vim.fn.writefile({ "v22", "" }, root .. "/.nvmrc")
    projects.reset_session()
    projects.version(root, "node", compute)
    eq(2, calls())
  end)

  it("re-detects when a file that was absent appears", function()
    local root = tmpdir()
    local compute, calls = counting(nil, { root .. "/.nvmrc" }, nil)
    projects.version(root, "node", compute)
    vim.fn.writefile({ "v22" }, root .. "/.nvmrc")
    projects.reset_session()
    projects.version(root, "node", compute)
    eq(2, calls())
  end)

  it("forgets one root or all of them", function()
    local a, b = tmpdir(), tmpdir()
    local ca, calls_a = counting("1", {}, "file:x")
    local cb, calls_b = counting("2", {}, "file:y")
    projects.version(a, "lua", ca)
    projects.version(b, "lua", cb)
    projects.forget(a)
    projects.version(a, "lua", ca)
    projects.version(b, "lua", cb)
    eq({ 2, 1 }, { calls_a(), calls_b() })
    projects.forget()
    projects.version(b, "lua", cb)
    eq(2, calls_b())
  end)

  it("caches tool versions keyed by the executable's stamp", function()
    local exe = tmpdir() .. "/fish"
    vim.fn.writefile({ "#!/bin/sh" }, exe)
    local compute, calls = counting "4.0.2"
    eq("4.0.2", projects.tool(exe, compute))
    projects.reset_session()
    eq("4.0.2", projects.tool(exe, compute))
    eq(1, calls())
    vim.fn.writefile({ "#!/bin/sh", "# upgraded" }, exe)
    projects.reset_session()
    projects.tool(exe, compute)
    eq(2, calls(), "an upgraded binary is asked again")
  end)

  it("refuses to overwrite a projects.json from a newer plugin", function()
    store.write_file(data .. "/projects.json", vim.json.encode { version = 99, roots = {}, tools = {} })
    projects.reset_session()
    local compute = counting("1", {}, "file:x")
    eq("1", projects.version(tmpdir(), "lua", compute))
    eq(99, vim.json.decode(store.read_file(data .. "/projects.json")).version)
    vim.fn.delete(data .. "/projects.json")
    projects.reset_session()
  end)
end)
