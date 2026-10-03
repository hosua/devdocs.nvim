local version = require "devdocs.version"

local function doc(slug, v)
  return { slug = slug, version = v, name = slug }
end

local function write(root, rel, content)
  local file = root .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), file)
end

describe("version", function()
  it("extracts the first version from a spec", function()
    eq("20.1.0", version.first_version "^20.1.0")
    eq("3.10", version.first_version ">=3.10,<4")
    eq("22", version.first_version "v22")
    eq("18", version.first_version ">=18")
    eq(nil, version.first_version "lts/*")
    eq(nil, version.first_version(nil))
    eq("4.2", version.first_version "~> 4.2")
  end)

  it("reduces to major.minor", function()
    eq("3.12", version.major_minor "3.12.3")
    eq("22", version.major_minor "22")
    eq("x", version.major_minor "x")
  end)

  describe("pick", function()
    local py =
      { doc("python~3.14", "3.14"), doc("python~3.12", "3.12"), doc("python~3.9", "3.9"), doc("python~2.7", "2.7") }
    local node =
      { doc("node", ""), doc("node~22_lts", "22 LTS"), doc("node~20_lts", "20 LTS"), doc("node~18_lts", "18 LTS") }

    it("takes the newest when nothing is detected or recent_only", function()
      eq("python~3.14", version.pick(py, nil).slug)
      eq("python~3.14", version.pick(py, "3.9", { recent_only = true }).slug)
      eq("node", version.pick(node, nil).slug)
    end)

    it("prefers an exact major.minor", function()
      eq("python~3.12", version.pick(py, "3.12.3").slug)
      eq("python~3.9", version.pick(py, "3.9").slug)
      eq("node~22_lts", version.pick(node, "22.4.0").slug)
    end)

    it("falls back to the newest not newer than detected", function()
      eq("python~3.12", version.pick(py, "3.13").slug)
      eq("node~20_lts", version.pick(node, "21.0.0").slug)
      eq("python~2.7", version.pick(py, "2.9").slug)
    end)

    it("falls back to the newest when detected is older than everything", function()
      eq("python~3.14", version.pick(py, "1.5").slug)
    end)

    it("uses the unversioned doc when that is all there is", function()
      eq("css", version.pick({ doc("css", "") }, "3").slug)
      eq(nil, version.pick({}, "3"))
    end)
  end)

  describe("detectors", function()
    local root = tmpdir()

    it("read node versions from .nvmrc, .node-version and package.json engines", function()
      write(root, ".nvmrc", "v22.1.0\n")
      eq("22.1.0", version.detect("node", root))
      os.remove(root .. "/.nvmrc")
      write(
        root,
        "package.json",
        '{"engines":{"node":">=18"},"dependencies":{"react":"^18.2.0","vue":"3.4.1"},"devDependencies":{"typescript":"~5.4"}}'
      )
      eq("18", version.detect("node", root))
      eq("18.2.0", version.detect("react", root))
      eq("3.4.1", version.detect("vue", root))
      eq("5.4", version.detect("typescript", root))
      eq(nil, version.detect("bootstrap", root))
    end)

    it("reads python from .python-version and pyproject", function()
      write(root, ".python-version", "3.12.3")
      eq("3.12.3", version.detect("python", root))
      os.remove(root .. "/.python-version")
      write(
        root,
        "pyproject.toml",
        '[project]\nrequires-python = ">=3.10"\ndependencies = ["Django>=4.2,<5", "numpy==1.26.4"]'
      )
      eq("3.10", version.detect("python", root))
      eq("4.2", version.detect("django", root))
      eq("1.26.4", version.detect("numpy", root))
    end)

    it("reads go, ruby, php, cmake, elixir, godot", function()
      write(root, "go.mod", "module x\n\ngo 1.22.1\n")
      eq("1.22.1", version.detect("go", root))
      write(root, ".ruby-version", "3.3.0")
      eq("3.3.0", version.detect("ruby", root))
      write(root, "composer.json", '{"require":{"php":"^8.2","laravel/framework":"^11.0"}}')
      eq("8.2", version.detect("php", root))
      eq("11.0", version.detect("laravel", root))
      write(root, "CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\nproject(x)")
      eq("3.20", version.detect("cmake", root))
      write(root, "mix.exs", 'defmodule X.MixProject do\n  def project, do: [elixir: "~> 1.15"]\nend')
      eq("1.15", version.detect("elixir", root))
      write(
        root,
        "project.godot",
        'config_version=5\n[application]\nconfig/features=PackedStringArray("4.2", "Forward Plus")'
      )
      eq("4.2", version.detect("godot", root))
    end)

    it("reads java from pom.xml and gradle", function()
      write(
        root,
        "pom.xml",
        "<project><properties><maven.compiler.release>17</maven.compiler.release></properties></project>"
      )
      eq("17", version.detect("openjdk", root))
      os.remove(root .. "/pom.xml")
      write(root, "build.gradle", "java {\n  sourceCompatibility = JavaVersion.VERSION_21\n}")
      eq("21", version.detect("openjdk", root))
    end)

    it("treats a neovim config or .luarc as LuaJIT", function()
      local nv = tmpdir()
      write(nv, "init.lua", "require 'x'")
      write(nv, "lua/x.lua", "return {}")
      eq("5.1", version.detect("lua", nv))
      local lr = tmpdir()
      write(lr, ".luarc.json", '{"runtime": {"version": "Lua 5.4"}}')
      eq("5.4", version.detect("lua", lr))
      write(lr, ".luarc.json", '{"runtime.version": "LuaJIT"}')
      eq("5.1", version.detect("lua", lr))
      eq(nil, version.detect("lua", tmpdir()))
    end)

    it("returns nil for unknown bases, missing roots and broken files", function()
      eq(nil, version.detect("rust", root))
      eq(nil, version.detect("node", ""))
      write(root, "package.json", "{not json")
      eq(nil, version.detect("node", root))
    end)
  end)

  it("records every file a detector tried, present or not", function()
    local root = tmpdir()
    write(root, ".nvmrc", "v20.1.0")
    local v, files = version.detect_with_files("node", { root })
    eq("20.1.0", v)
    eq(root .. "/.nvmrc", files[1])
    local _, none = version.detect_with_files("python", { tmpdir(), root })
    ok(vim.tbl_contains(none, root .. "/.python-version"), "absent files are recorded too")
  end)

  it("tries each version dir in order", function()
    local sub, top = tmpdir(), tmpdir()
    write(top, ".nvmrc", "18")
    eq("18", (version.detect_with_files("node", { sub, top })))
    write(sub, ".nvmrc", "22")
    eq("22", (version.detect_with_files("node", { sub, top })))
  end)

  it("reads the typescript the project actually installed", function()
    local root = tmpdir()
    write(root, "package.json", '{"devDependencies":{"typescript":"^5.0.0"}}')
    write(root, "node_modules/typescript/package.json", '{"version":"5.4.5"}')
    eq("5.4.5", version.detect("typescript", root))
  end)

  it("reads the Lua runtime from an attached lua_ls", function()
    local client = { name = "lua_ls", settings = { Lua = { runtime = { version = "LuaJIT" } } } }
    eq({ "5.1", "lsp:lua_ls" }, { version.from_lsp("lua", { client }) })
    client.settings.Lua.runtime.version = "Lua 5.4"
    eq("5.4", (version.from_lsp("lua", { client })))
    eq(nil, version.from_lsp("lua", { { name = "lua_ls", settings = {} } }))
    eq(nil, version.from_lsp("python", { client }))
  end)

  it("asks pyright's interpreter for the Python version", function()
    local saved = version._run
    version._run = function(cmd)
      eq({ "/venv/bin/python", "--version" }, cmd)
      return "Python 3.11.9"
    end
    local client = { name = "basedpyright", config = { settings = { python = { pythonPath = "/venv/bin/python" } } } }
    eq({ "3.11.9", "lsp:basedpyright" }, { version.from_lsp("python", { client }) })
    version._run = saved
  end)

  it("parses installed tool versions", function()
    local saved = version._run
    local outputs = {
      fish = "fish, version 4.0.2",
      node = "v22.11.0",
      bash = "GNU bash, version 5.3.20(1)-release (x86_64-pc-linux-gnu)",
      go = "go version go1.23.2 linux/amd64",
    }
    version._run = function(cmd)
      return outputs[cmd[1]]
    end
    eq("4.0.2", version.tool_version "fish")
    eq("22.11.0", version.tool_version "node")
    eq("5.3.20", version.tool_version "bash")
    eq("1.23.2", version.tool_version "go")
    eq(nil, version.tool_version "rust")
    version._run = saved
  end)
end)
