local config = require "devdocs.config"
local paths = require "devdocs.paths"
local store = require "devdocs.store"
local viewer = require "devdocs.ui.viewer"

describe("viewer (pure parts)", function()
  local root = tmpdir()
  config.resolve { data_dir = root }
  store.invalidate()
  local slug = "lua~5.4"
  store.write_json(paths.meta_file(slug), { slug = slug, name = "Lua", doc_version = "5.4" }, "meta")
  store.write_file(
    paths.entries_file(slug),
    store.encode_entries { { name = "assert()", path = "index#pdf-assert", type = "Standard Libraries" } }
  )
  store.write_json(paths.anchors_file(slug), { pages = { index = { ["pdf-assert"] = 5 } } }, "anchors")
  store.write_file(paths.page_file(slug, "index"), table.concat({
    "# Lua manual",
    "",
    "Intro",
    "",
    "### assert (v [, message])",
    "",
    "Raises an error if v is false.",
    "",
    "```lua",
    "assert(io.open(f))",
    "```",
    "",
    "### error (message)",
    "",
    "Raises an error.",
  }, "\n") .. "\n")
  store.invalidate()
  local entry = { name = "assert()", path = "index#pdf-assert", type = "Standard Libraries" }

  it("renders a section with a breadcrumb title", function()
    local lines, title = viewer.render { slug = slug, path = entry.path, entry = entry, mode = "section" }
    eq("Lua 5.4 › Standard Libraries › assert()", title)
    eq("### assert (v [, message])", lines[1])
    eq("```", lines[#lines])
  end)

  it("renders the whole page", function()
    local lines, title = viewer.render { slug = slug, path = "index", entry = nil, mode = "page" }
    eq("Lua 5.4", title)
    eq("# Lua manual", lines[1])
    eq(15, #lines)
  end)

  it("renders only the examples, with captions", function()
    local lines, title = viewer.render { slug = slug, path = entry.path, entry = entry, mode = "examples" }
    eq("Lua 5.4 › Standard Libraries › assert() › examples", title)
    eq({ "**Raises an error if v is false.**", "```lua", "assert(io.open(f))", "```" }, lines)
  end)

  it("says when a section has no examples", function()
    local e = { name = "error()", path = "index#pdf-error", type = "x" }
    store.write_json(
      paths.anchors_file(slug),
      { pages = { index = { ["pdf-assert"] = 5, ["pdf-error"] = 13 } } },
      "anchors"
    )
    store.invalidate(slug)
    local lines, title = viewer.render { slug = slug, path = e.path, entry = e, mode = "examples" }
    -- the section has none, so the whole page's examples are shown instead
    ok(title:find("whole page", 1, true), title)
    eq("```lua", lines[2])
    store.write_file(paths.page_file(slug, "plain"), "# plain\n\nno code here\n")
    local none, t2 = viewer.render { slug = slug, path = "plain", entry = nil, mode = "examples" }
    ok(none[2]:find("No examples", 1, true), none[2])
    ok(t2:find("examples", 1, true))
  end)

  it("reports a missing page instead of crashing", function()
    local lines, _, err = viewer.render { slug = slug, path = "nope", entry = nil, mode = "page" }
    ok(err ~= nil)
    ok(lines[2]:find("not on disk", 1, true))
  end)

  it("shows link text only and remembers the targets", function()
    local display, links = viewer.display {
      "see [`open()`](devdocs://python/library/functions#open) and [x](https://a.b/c).",
      "plain https://x.y/z, more",
      "![img](i.png) none",
      "```",
      "[not](a-link)",
      "```",
      "after [y](z)",
    }
    eq(
      { "see `open()` and x.", "plain https://x.y/z, more", "img none", "```", "[not](a-link)", "```", "after y" },
      display
    )
    eq(
      { { s = 5, e = 12, url = "devdocs://python/library/functions#open" }, { s = 18, e = 18, url = "https://a.b/c" } },
      links[1]
    )
    eq({ { s = 7, e = 19, url = "https://x.y/z" } }, links[2])
    eq(nil, links[3])
    eq(nil, links[5])
    eq({ { s = 7, e = 7, url = "z" } }, links[7])
  end)

  it("finds the link under the cursor, else the first on the line", function()
    local _, links = viewer.display { "see [`open()`](devdocs://x/y) and [x](https://a.b/c)." }
    eq("devdocs://x/y", viewer.link_at(links[1], 6))
    eq("https://a.b/c", viewer.link_at(links[1], 17))
    eq("devdocs://x/y", viewer.link_at(links[1], 0))
    eq(nil, viewer.link_at(nil, 3))
  end)

  it("parses devdocs urls and rejects bad slugs", function()
    eq({ "css", "properties/grid#syntax" }, { viewer.parse_devdocs_url "devdocs://css/properties/grid#syntax" })
    eq(nil, (viewer.parse_devdocs_url "devdocs://../x/y"))
    eq(nil, (viewer.parse_devdocs_url "https://devdocs.io/css"))
  end)
end)
