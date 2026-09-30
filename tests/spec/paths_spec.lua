local config = require "devdocs.config"
local paths = require "devdocs.paths"

describe("paths", function()
  local root = tmpdir()
  config.resolve { data_dir = root }

  it("lays out the data dir", function()
    eq(root .. "/manifest.json", paths.manifest_file())
    eq(root .. "/state.json", paths.state_file())
    eq(root .. "/docs/css/meta.json", paths.meta_file "css")
    eq(root .. "/docs/python~3.12/entries.tsv", paths.entries_file "python~3.12")
    eq(root .. "/docs/node~22_lts/pages", paths.pages_dir "node~22_lts")
  end)

  it("accepts real slugs and rejects escapes", function()
    for _, s in ipairs { "css", "cpp", "python~3.12", "node~22_lts", "gcc~13_cpp", "scala~2.13_library", "c" } do
      ok(paths.valid_slug(s), s)
    end
    for _, s in ipairs { "", "../x", "a/b", "..", ".hidden", "a b", "~css", 42 } do
      ok(not paths.valid_slug(s), tostring(s))
    end
    ok(not pcall(paths.doc_dir, "../etc"))
  end)

  it("splits fragments", function()
    eq({ "library/os.path", "os.path.join" }, { paths.split_fragment "library/os.path#os.path.join" })
    eq({ "index", nil }, { paths.split_fragment "index" })
    eq({ "index", "" }, { paths.split_fragment "index#" })
  end)

  it("encodes page paths to safe file names and round-trips", function()
    local cases = {
      ["index"] = "index.md",
      ["selectors/:default"] = "selectors/%3Adefault.md",
      ["library/os.path"] = "library/os.path.md",
      ["io/basic_ostream/operator<<"] = "io/basic_ostream/operator%3C%3C.md",
      ["a b/100%"] = "a%20b/100%25.md",
      ["ünïcode/ü"] = "%C3%BCn%C3%AFcode/%C3%BC.md",
    }
    for page, file in pairs(cases) do
      eq(file, paths.encode_page(page), page)
      eq(page, paths.decode_page(file), file)
    end
  end)

  it("refuses traversing, absolute and empty page paths", function()
    for _, bad in ipairs { "", "/etc/passwd", "../x", "a/../b", "a/./b", "a//b", "..", "a/" } do
      ok(not pcall(paths.encode_page, bad), bad)
    end
  end)

  it("maps a page to its file and back, dropping the fragment", function()
    local f = paths.page_file("css", "selectors/:default#syntax")
    eq(root .. "/docs/css/pages/selectors/%3Adefault.md", f)
    eq({ "css", "selectors/:default" }, { paths.page_from_file(f) })
    eq(nil, (paths.page_from_file "/somewhere/else/pages/x.md"))
    eq(nil, (paths.page_from_file(root .. "/docs/css/meta.json")))
  end)

  it("builds browser urls", function()
    eq("https://devdocs.io/css/selectors/:default#syntax", paths.browser_url("css", "selectors/:default#syntax"))
    eq("https://devdocs.io/python~3.12/", paths.browser_url("python~3.12", nil))
  end)

  it("expands the doc url template", function()
    eq(
      "https://documents.devdocs.io/python~3.12/db.json",
      paths.doc_url("https://documents.devdocs.io/{slug}/{file}", "python~3.12", "db.json")
    )
    eq("file:///m/docs/css/index.json", paths.doc_url("file:///m/docs/{slug}/{file}", "css", "index.json"))
    ok(not pcall(paths.doc_url, "x/{slug}/{file}", "../x", "db.json"))
  end)
end)
