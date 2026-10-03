local config = require "devdocs.config"
local index = require "devdocs.index"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local PAGE = {
  "# os.path — paths",
  "",
  "Intro text.",
  "",
  "## Functions",
  "",
  "**`os.path.join(path, *paths)`**",
  "",
  "  Join one or more path segments.",
  "",
  "  Example:",
  "",
  "  ```python",
  "  >>> os.path.join('a', 'b')",
  "  'a/b'",
  "  ```",
  "",
  "**`os.path.split(path)`**",
  "",
  "  Split a pathname.",
  "",
  "## Notes",
  "",
  "```",
  "no lang",
  "```",
  "",
  "### Deep",
  "",
  "deep text",
}

describe("index", function()
  local root = tmpdir()
  config.resolve { data_dir = root }
  store.invalidate()
  local slug = "python~3.12"
  store.write_json(paths.meta_file(slug), { slug = slug, name = "Python", doc_version = "3.12" }, "meta")
  store.write_file(
    paths.entries_file(slug),
    store.encode_entries {
      { name = "os.path.join()", path = "library/os.path#os.path.join", type = "File & Directory Access" },
      { name = "os.path.split()", path = "library/os.path#os.path.split", type = "File & Directory Access" },
      { name = "os.path", path = "library/os.path", type = "File & Directory Access" },
    }
  )
  store.write_json(
    paths.anchors_file(slug),
    { pages = { ["library/os.path"] = { ["os.path.join"] = 7, ["os.path.split"] = 18, functions = 5, notes = 22 } } },
    "anchors"
  )
  store.write_file(paths.page_file(slug, "library/os.path"), table.concat(PAGE, "\n") .. "\n")
  store.invalidate()

  it("builds sources only from installed docs", function()
    local s = index.sources({ slug, "missing" }, { [slug] = 1 })
    eq(1, #s)
    eq(1, s[1].tier)
    eq(3, #s[1].entries)
  end)

  it("reads a whole page and reports a missing one", function()
    eq(PAGE, index.page(slug, "library/os.path#anything"))
    local lines, err = index.page(slug, "library/nope")
    eq(nil, lines)
    ok(err:find("not on disk", 1, true))
  end)

  it("slices a heading section up to the next heading of the same level", function()
    local lines, start = index.section(slug, "library/os.path#functions")
    eq(5, start)
    eq("## Functions", lines[1])
    eq("  Split a pathname.", lines[#lines])
    local notes = index.section(slug, "library/os.path#notes")
    eq({ "## Notes", "", "```", "no lang", "```", "", "### Deep", "", "deep text" }, notes)
  end)

  it("slices a definition term up to the next term", function()
    local lines, start = index.section(slug, "library/os.path#os.path.join")
    eq(7, start)
    eq("**`os.path.join(path, *paths)`**", lines[1])
    eq("  ```", lines[#lines])
    eq(10, #lines)
  end)

  it("falls back to the whole page for unknown fragments", function()
    local lines, start = index.section(slug, "library/os.path#nope")
    eq(1, start)
    eq(#PAGE, #lines)
  end)

  it("extracts code blocks with captions and strips list indent", function()
    local blocks = index.code_blocks(PAGE)
    eq(2, #blocks)
    eq("python", blocks[1].lang)
    eq({ ">>> os.path.join('a', 'b')", "'a/b'" }, blocks[1].lines)
    eq("Example:", blocks[1].caption)
    eq("", blocks[2].lang)
    eq("Notes", blocks[2].caption)
    eq({
      "**Example:**",
      "```python",
      ">>> os.path.join('a', 'b')",
      "'a/b'",
      "```",
      "",
      "**Notes**",
      "```",
      "no lang",
      "```",
    }, index.examples_markdown(blocks))
  end)

  it("titles, breadcrumbs and entry lookup", function()
    eq("os.path — paths", index.title(PAGE))
    eq(nil, index.title { "no heading" })
    eq(
      "Python 3.12 › File & Directory Access › os.path.join()",
      index.breadcrumb(slug, index.entry_for_path(slug, "library/os.path#os.path.join"))
    )
    eq("Python 3.12", index.breadcrumb(slug, nil))
    eq("os.path.join()", index.entry_for_path(slug, "library/os.path#os.path.join").name)
    eq("os.path.join()", index.entry_for_path(slug, "library/os.path#unknown").name)
    eq(nil, index.entry_for_path(slug, "elsewhere"))
  end)
end)

describe("index.section is fence-aware", function()
  local root = tmpdir()
  config.resolve { data_dir = root }
  store.invalidate()
  local slug = "fence~1"
  store.write_json(paths.meta_file(slug), { slug = slug, name = "Fence", doc_version = "1" }, "meta")
  store.write_file(paths.entries_file(slug), store.encode_entries {})
  local function put(page, lines, anchors)
    store.write_file(paths.page_file(slug, page), table.concat(lines, "\n") .. "\n")
    local all = store.anchors(slug)
    all[page] = anchors
    store.write_json(paths.anchors_file(slug), { pages = all }, "anchors")
    store.invalidate()
  end

  it("does not end a heading section at a fenced # comment", function()
    put(
      "page",
      { "# T", "", "## A", "text", "```sh", "# comment", "echo", "```", "more", "## B", "b" },
      { a = 3, b = 10 }
    )
    local lines, start = index.section(slug, "page#a")
    eq(3, start)
    eq(7, #lines)
    eq("## A", lines[1])
    eq("# comment", lines[4])
    eq("more", lines[#lines])
    local b = index.section(slug, "page#b")
    eq({ "## B", "b" }, b)
  end)

  it("does not end a plain-anchor section at a fenced heading", function()
    put("plain", { "# T", "intro", "```", "## fake", "```", "tail", "## Real", "x" }, { intro = 2 })
    local lines, start = index.section(slug, "plain#intro")
    eq(2, start)
    eq({ "intro", "```", "## fake", "```", "tail" }, lines)
  end)

  it("does not end a definition term at a fenced heading or term", function()
    put("terms", {
      "# T",
      "**f (x)**",
      "",
      "```lua",
      "# not a heading",
      "**g (y)**",
      "```",
      "body",
      "**g (y)**",
      "other",
    }, { f = 2 })
    local lines, start = index.section(slug, "terms#f")
    eq(2, start)
    eq({ "**f (x)**", "", "```lua", "# not a heading", "**g (y)**", "```", "body" }, lines)
  end)
end)
