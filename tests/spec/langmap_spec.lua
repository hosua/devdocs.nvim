local langmap = require "devdocs.langmap"

local function doc(slug, version, name)
  return { name = name or slug:match "^(%a+)", slug = slug, version = version or "", type = "x", mtime = 1, db_size = 1 }
end

local DOCS = {
  doc("css", "", "CSS"),
  doc("python~3.12", "3.12", "Python"),
  doc("python~3.9", "3.9", "Python"),
  doc("python~2.7", "2.7", "Python"),
  doc("bootstrap~5", "5", "Bootstrap"),
  doc("bootstrap~4", "4", "Bootstrap"),
  doc("node", "", "Node.js"),
  doc("node~22_lts", "22 LTS", "Node.js"),
}

describe("langmap", function()
  it("maps filetypes to bases, most specific first", function()
    eq({ "cpp", "c" }, langmap.bases_for("cpp", "main.cpp"))
    eq({ "typescript", "javascript", "node", "dom" }, langmap.bases_for("typescript", "a.ts"))
    eq({}, langmap.bases_for("unknownft", "x"))
    eq({ "lua" }, langmap.bases_for("lua", nil))
  end)

  it("adds file-name rules before the filetype", function()
    eq({ "docker" }, langmap.bases_for("yaml", "/p/docker-compose.override.yml"))
    eq({ "docker" }, langmap.bases_for("dockerfile", "Dockerfile.dev"))
    eq({ "npm", "node" }, langmap.bases_for("json", "package.json"))
    eq({ "cmake" }, langmap.bases_for("cmake", "CMakeLists.txt"))
  end)

  it("lets extra_filetypes come first and de-duplicates", function()
    eq({ "mylib", "c", "cpp" }, langmap.bases_for("cpp", "x.cpp", { cpp = { "mylib", "c" } }))
  end)

  it("derives bases from mason packages", function()
    eq(
      { "c", "cpp", "go", "lua", "python" },
      langmap.bases_for_mason { "gopls", "clangd", "basedpyright", "lua-language-server", "stylua" }
    )
    eq({ "zz" }, langmap.bases_for_mason({ "custom-ls" }, { ["custom-ls"] = { "zz" } }))
    eq({}, langmap.bases_for_mason {})
  end)

  it("returns no mason packages when mason is absent", function()
    eq({}, langmap.mason_installed())
  end)

  it("expands import patterns to the newest version per base", function()
    eq(
      { { "css", "python~3.12", "bootstrap~5" }, {} },
      { langmap.expand_import(DOCS, { "css", "Python", "bootstrap*" }) }
    )
  end)

  it("keeps an explicit versioned slug and honours all", function()
    eq({ "python~3.9" }, (langmap.expand_import(DOCS, { "python~3.9" })))
    eq({ "python~3.12", "python~3.9", "python~2.7" }, (langmap.expand_import(DOCS, { "python*" }, { all = true })))
    eq({ "python~3.12" }, (langmap.expand_import(DOCS, { "python~3*" })))
  end)

  it("reports unmatched patterns", function()
    local slugs, unmatched = langmap.expand_import(DOCS, { "rust", "css", "node" })
    eq({ "css", "node" }, slugs)
    eq({ "rust" }, unmatched)
  end)
end)
