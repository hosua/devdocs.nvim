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

describe("viewer p (whole page at the current section)", function()
  local root = tmpdir()
  -- a short float, so the page is taller than the window and scrolling shows
  config.resolve { data_dir = root, view = { height = 6 } }
  store.invalidate()
  local slug = "lua~5.4"
  store.write_json(paths.meta_file(slug), { slug = slug, name = "Lua", doc_version = "5.4" }, "meta")
  store.write_file(paths.entries_file(slug), store.encode_entries {})
  local page = { "# Lua manual", "" }
  for i = 3, 19 do
    page[i] = ("intro %d"):format(i)
  end
  vim.list_extend(page, {
    "### assert (v [, message])", -- 20
    "",
    "Raises an error if v is false.",
    "",
    "```lua",
    "assert(io.open(f))",
    "```",
    "",
    "### error (message)", -- 28
    "",
  })
  for i = 30, 50 do
    page[i] = ("outro %d"):format(i)
  end
  store.write_file(paths.page_file(slug, "index"), table.concat(page, "\n") .. "\n")
  store.write_json(
    paths.anchors_file(slug),
    { pages = { index = { ["pdf-assert"] = 20, ["pdf-error"] = 28 } } },
    "anchors"
  )
  store.invalidate()
  local entry = { name = "assert()", path = "index#pdf-assert", type = "Standard Libraries" }

  local function topline()
    return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].topline
  end
  local function title()
    local t = vim.api.nvim_win_get_config(0).title
    return type(t) == "table" and t[1][1] or t
  end

  it("knows the page line a view's section starts at", function()
    eq(20, viewer.page_line { slug = slug, path = entry.path, entry = entry, mode = "section" })
    eq(28, viewer.page_line { slug = slug, path = "index#pdf-error", entry = nil, mode = "examples" })
    eq(1, viewer.page_line { slug = slug, path = "index", entry = nil, mode = "section" })
    eq(1, viewer.page_line { slug = slug, path = "index#nope", entry = nil, mode = "section" })
    eq(1, viewer.page_line { slug = slug, path = "missing#x", entry = nil, mode = "section" })
  end)

  it("opens the whole page with the section heading at the top", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    eq("### assert (v [, message])", vim.api.nvim_get_current_line())
    viewer.set_mode "page"
    eq("page", viewer.current_view().mode)
    eq(50, vim.api.nvim_buf_line_count(0))
    eq(20, vim.api.nvim_win_get_cursor(0)[1])
    eq("### assert (v [, message])", vim.api.nvim_get_current_line())
    eq(20, topline())
    ok(title():find("assert()", 1, true), title())
    local footer = vim.api.nvim_win_get_config(0).footer
    ok(vim.inspect(footer):find("o browser", 1, true), vim.inspect(footer))
  end)

  it("goes back to the section view from the page", function()
    viewer.back()
    eq("section", viewer.current_view().mode)
    eq("### assert (v [, message])", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    viewer.close()
  end)

  it("opens the page at the section from the examples view too", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "examples" }
    viewer.set_mode "page"
    eq(20, vim.api.nvim_win_get_cursor(0)[1])
    eq(20, topline())
    -- examples of the section again: the page line no longer applies
    viewer.set_mode "examples"
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    eq(nil, viewer.current_view().line)
    viewer.close()
  end)

  it("p puts the heading at the top after <BS> restored a scroll position (e -> p, ? -> p)", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    viewer.set_mode "page"
    viewer.back() -- the section view comes back with the topline it was left at
    viewer.set_mode "examples"
    viewer.set_mode "page"
    eq(20, vim.api.nvim_win_get_cursor(0)[1])
    eq(20, topline())
    viewer.back()
    viewer.help()
    viewer.set_mode "page"
    eq(20, vim.api.nvim_win_get_cursor(0)[1])
    eq(20, topline())
    viewer.close()
  end)

  it("opens the page at the section from the help screen", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    viewer.help()
    viewer.set_mode "page"
    eq(20, vim.api.nvim_win_get_cursor(0)[1])
    eq(20, topline())
    viewer.back() -- help already put the section on the history
    eq("section", viewer.current_view().mode)
    viewer.close()
  end)

  it("pins the heading to the top whatever the user's 'scrolloff'", function()
    local saved = vim.go.scrolloff
    local before_win = vim.api.nvim_get_current_win()
    local ok_run, err = pcall(function()
      for _, so in ipairs { 8, 999 } do
        vim.go.scrolloff = so
        viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
        viewer.set_mode "page"
        eq(20, vim.api.nvim_win_get_cursor(0)[1])
        eq(20, topline(), "scrolloff=" .. so)
        -- window-local: the user's global value and other windows are untouched
        eq(so, vim.go.scrolloff)
        eq(so, vim.api.nvim_get_option_value("scrolloff", { win = before_win }))
        viewer.close()
      end
    end)
    vim.go.scrolloff = saved
    assert(ok_run, err)
  end)

  it("puts e on the history like p, so <BS> walks back through both", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    viewer.set_mode "examples"
    eq("examples", viewer.current_view().mode)
    viewer.set_mode "page"
    eq(20, vim.api.nvim_win_get_cursor(0)[1])
    viewer.back()
    eq("examples", viewer.current_view().mode)
    viewer.back()
    eq("section", viewer.current_view().mode)
    eq("### assert (v [, message])", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    viewer.close()
  end)

  it("does not grow the history when the mode does not change", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    viewer.set_mode "page"
    viewer.set_mode "page"
    viewer.back()
    eq("section", viewer.current_view().mode)
    local notify = vim.notify
    vim.notify = function() end
    viewer.back() -- nothing left
    vim.notify = notify
    eq("section", viewer.current_view().mode)
    viewer.close()
  end)

  it("keeps a search hit's line through e and back to p", function()
    viewer.open { slug = slug, path = "index", entry = nil, mode = "page", line = 35 }
    eq(35, vim.api.nvim_win_get_cursor(0)[1])
    viewer.set_mode "examples"
    viewer.set_mode "page"
    eq(35, vim.api.nvim_win_get_cursor(0)[1])
    viewer.close()
  end)

  it("restores the cursor and scroll position of a view on <BS>", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    viewer.set_mode "page"
    vim.api.nvim_win_set_cursor(0, { 41, 0 })
    local top = topline()
    viewer.set_mode "examples"
    viewer.back()
    eq("page", viewer.current_view().mode)
    eq(41, vim.api.nvim_win_get_cursor(0)[1])
    eq(top, topline())
    viewer.close()

    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    viewer.set_mode "page"
    viewer.back()
    eq("section", viewer.current_view().mode)
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    viewer.close()
  end)

  it("falls back to the top of the page when the anchor is unknown", function()
    viewer.open { slug = slug, path = "index#nope", entry = nil, mode = "section" }
    viewer.set_mode "page"
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    eq(1, topline())
    viewer.close()
  end)
end)
