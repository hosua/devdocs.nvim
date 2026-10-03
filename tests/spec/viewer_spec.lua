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
    -- paginated: assert has 4 body lines, so the next section joins it
    eq("Lua 5.4 › Standard Libraries › assert() (2/2)", title)
    eq("### assert (v [, message])", lines[1])
    eq("Raises an error.", lines[#lines])
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

  it("names in the footer the view p switches to", function()
    local function action_of(footer, key)
      for _, h in ipairs(footer) do
        if h[1] == key then
          return h[2]
        end
      end
    end
    eq("pages", action_of(viewer.footer "section", "p"))
    eq("paginated", action_of(viewer.footer "page", "p"))
    eq("pages", action_of(viewer.footer "examples", "p"))
    eq("pages", action_of(viewer.FOOTER, "p"))
    eq(#viewer.FOOTER, #viewer.footer "page")
    for i, h in ipairs(viewer.FOOTER) do
      if h[1] ~= "p" then
        eq(h, viewer.footer("page")[i])
      end
    end
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
    -- the footer is text, or { text, hl } chunks when keys are highlighted
    local footer = vim.api.nvim_win_get_config(0).footer
    local text = type(footer) == "table" and table.concat(vim.tbl_map(function(c)
      return c[1]
    end, footer)) or footer
    ok(text:find("⏎ follow", 1, true), vim.inspect(footer))
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

  local function footer_text()
    local footer = vim.api.nvim_win_get_config(0).footer
    return type(footer) == "table" and table.concat(vim.tbl_map(function(c)
      return c[1]
    end, footer)) or footer
  end
  local function cur()
    return vim.api.nvim_win_get_cursor(0)[1]
  end
  local function at(line)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end
  local function mode()
    return viewer.current_view().mode
  end

  it("p toggles between the paginated view and the whole page, keeping the place", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    eq(31, vim.api.nvim_buf_line_count(0))
    ok(footer_text():find("p pages", 1, true), footer_text())
    viewer.toggle()
    eq("page", mode())
    eq(20, cur())
    eq(20, topline())
    ok(footer_text():find("p paginated", 1, true), footer_text())
    viewer.toggle()
    eq("section", mode())
    eq(20, viewer.current_view().page_start)
    eq(1, cur())
    eq(1, topline())
    eq(31, vim.api.nvim_buf_line_count(0))
    eq("### assert (v [, message])", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    ok(footer_text():find("p pages", 1, true), footer_text())
    viewer.close()
  end)

  it("p from the whole page lands on the page holding the cursor, scrolled the same", function()
    viewer.open { slug = slug, path = "index", entry = nil, mode = "page", line = 35 }
    local top0 = topline()
    viewer.toggle()
    eq("section", mode())
    eq(20, viewer.current_view().page_start)
    eq(16, cur())
    eq(math.max(1, top0 - 19), topline())
    viewer.close()

    viewer.open { slug = slug, path = "index", entry = nil, mode = "page" }
    at(5)
    viewer.toggle()
    eq(1, viewer.current_view().page_start)
    eq(5, cur())
    ok(title():find("(1/2)", 1, true), title())
    viewer.close()
  end)

  it("p goes on the history: <BS> walks back through the toggles", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    viewer.toggle()
    viewer.toggle()
    viewer.back()
    eq("page", mode())
    eq(20, cur())
    viewer.back()
    eq("section", mode())
    eq(1, cur())
    viewer.close()
  end)

  it("p over the help screen toggles the view underneath", function()
    viewer.open { slug = slug, path = "index", entry = nil, mode = "page", line = 35 }
    viewer.help()
    eq("help", mode())
    viewer.toggle()
    eq("section", mode())
    eq(20, viewer.current_view().page_start)
    eq(16, cur())
    viewer.close()
  end)

  it("maps p buffer-locally in the viewer", function()
    viewer.open { slug = slug, path = entry.path, entry = entry, mode = "section" }
    eq(1, vim.fn.maparg("p", "n", false, true).buffer)
    viewer.close()
  end)
end)

describe("viewer heading navigation (n N c C)", function()
  local root = tmpdir()
  config.resolve { data_dir = root, view = { height = 6 } }
  store.invalidate()
  local slug = "lua~5.4"
  store.write_json(paths.meta_file(slug), { slug = slug, name = "Lua", doc_version = "5.4" }, "meta")
  store.write_file(paths.entries_file(slug), store.encode_entries {})
  local page = { "# Manual", "" }
  for i = 3, 8 do
    page[i] = ("intro %d"):format(i)
  end
  page[9] = "# 1 – Introduction"
  for i = 10, 14 do
    page[i] = ("one %d"):format(i)
  end
  vim.list_extend(page, {
    "# 2 – Basic Concepts", -- 15
    "",
    "## 2.1 – Values", -- 17
    "values 18",
    "```lua", -- 19
    "# not a heading",
    "```",
    "### 2.1.1 – Details", -- 22
    "details 23",
    "```sh",
    "echo hi",
    "```",
    "## 2.2 – Environments", -- 27
  })
  for i = 28, 31 do
    page[i] = ("env %d"):format(i)
  end
  vim.list_extend(page, { "# 3 – The Language", "lang 33", "lang 34", "**load (chunk)**" }) -- 32..35
  for i = 36, 40 do
    page[i] = ("lang %d"):format(i)
  end
  store.write_file(paths.page_file(slug, "index"), table.concat(page, "\n") .. "\n")
  store.write_json(
    paths.anchors_file(slug),
    { pages = { index = { ["2"] = 15, ["2.1"] = 17, ["pdf-load"] = 35 } } },
    "anchors"
  )
  store.invalidate()

  local function open(path, mode, extra)
    viewer.open(vim.tbl_extend("force", { slug = slug, path = path, mode = mode }, extra or {}))
  end
  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
  end
  local function cur()
    return vim.api.nvim_win_get_cursor(0)[1]
  end
  local function at(line)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end
  local function topline()
    return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].topline
  end
  local function mode()
    return viewer.current_view().mode
  end
  local function capture(fn)
    local saved, msgs = vim.notify, {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local ok_run, err = pcall(fn)
    vim.notify = saved
    assert(ok_run, err)
    return msgs
  end
  local function footer_text(footer)
    local parts = {}
    for _, h in ipairs(footer) do
      parts[#parts + 1] = h[1] .. " " .. h[2]
    end
    return table.concat(parts, "  ")
  end

  it("maps n N c C buffer-locally in the viewer", function()
    open("index", "page")
    for _, lhs in ipairs { "n", "N", "c", "C" } do
      eq(1, vim.fn.maparg(lhs, "n", false, true).buffer, lhs)
    end
    viewer.close()
  end)

  it("n / N move between headings of a page, skipping fenced # lines", function()
    open("index", "page")
    at(1)
    press "n"
    eq(9, cur())
    eq(9, topline())
    press "n"
    eq(15, cur())
    press "n"
    eq(17, cur())
    press "n"
    eq(22, cur())
    eq(22, topline())
    press "N"
    eq(17, cur())
    at(24)
    press "N"
    eq(22, cur())
    at(1)
    press "3n"
    eq(17, cur())
    eq(17, topline())
    viewer.close()
  end)

  it("c / C move between chapters", function()
    open("index", "page")
    at(17)
    press "c"
    eq(32, cur())
    eq(32, topline())
    press "C"
    eq(15, cur())
    at(18)
    press "C"
    eq(15, cur())
    at(18)
    press "2C"
    eq(9, cur())
    viewer.close()
  end)

  it("stays put and says so at the ends", function()
    open("index", "page")
    local function try(line, keys, msg)
      at(line)
      local msgs = capture(function()
        press(keys)
      end)
      eq(line, cur())
      eq({ "devdocs: " .. msg }, msgs)
    end
    try(32, "n", "no next section")
    try(1, "N", "no previous section")
    try(33, "c", "no next chapter")
    try(1, "C", "no previous chapter")
    viewer.close()
  end)

  it("puts the jump on the jumplist", function()
    open("index", "page")
    at(1)
    press "n"
    eq(9, cur())
    vim.cmd "normal! ''"
    eq(1, cur())
    viewer.close()
  end)

  it("page moves do not touch the history", function()
    open("index", "page")
    press "n"
    press "n"
    local msgs = capture(function()
      viewer.back()
    end)
    eq({ "devdocs: no previous page" }, msgs)
    eq("page", mode())
    viewer.close()
  end)

  local function title()
    local t = vim.api.nvim_win_get_config(0).title
    return type(t) == "table" and t[1][1] or t
  end
  local function first_line()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  end
  local function shown(first, last_line_count)
    eq("section", mode())
    eq(first, viewer.current_view().page_start)
    eq(last_line_count, vim.api.nvim_buf_line_count(0))
  end

  it("paginated view: n moves inside the page, then turns it, without touching the history", function()
    open("index#2.1", "section", { entry = { name = "2.1", path = "index#2.1", type = "Manual" } })
    eq("## 2.1 – Values", first_line())
    eq(10, vim.api.nvim_buf_line_count(0))
    ok(title():find("(4/6)", 1, true), title())
    press "n"
    eq("section", mode())
    eq(6, cur())
    press "n"
    shown(27, 8)
    eq("## 2.2 – Environments", first_line())
    eq(1, cur())
    eq(1, topline())
    ok(title():find("(5/6)", 1, true), title())
    eq("index#2.1", viewer.current_view().path)
    press "n"
    shown(27, 8)
    eq(6, cur())
    press "n"
    shown(35, 6)
    eq("**load (chunk)**", first_line())
    eq(1, cur())
    ok(title():find("(6/6)", 1, true), title())
    local msgs = capture(function()
      press "n"
    end)
    eq({ "devdocs: no next section" }, msgs)
    press "N"
    shown(27, 8)
    eq(6, cur())
    press "N"
    shown(27, 8)
    eq(1, cur())
    press "N"
    shown(17, 10)
    eq(6, cur())
    msgs = capture(function()
      viewer.back()
    end)
    eq({ "devdocs: no previous page" }, msgs)
    viewer.close()
  end)

  it("paginated view: c / C jump between chapters, turning pages", function()
    local entry = { name = "2.1", path = "index#2.1", type = "Manual" }
    open("index#2.1", "section", { entry = entry })
    press "c"
    shown(27, 8)
    eq(6, cur())
    viewer.close()

    open("index#2.1", "section", { entry = entry })
    press "C"
    shown(15, 1) -- the blank line 16 is trimmed
    eq(1, cur())
    press "C"
    shown(9, 6)
    eq(1, cur())
    press "C"
    shown(1, 8)
    eq(1, cur())
    local msgs = capture(function()
      press "C"
    end)
    eq({ "devdocs: no previous chapter" }, msgs)
    viewer.close()
  end)

  it("paginated view: a count counts stops across pages", function()
    open("index#2.1", "section", { entry = { name = "2.1", path = "index#2.1", type = "Manual" } })
    press "3n"
    shown(27, 8)
    eq(6, cur())
    viewer.close()
  end)

  it("paginated view: an anchored definition term is a page start", function()
    open("index#pdf-load", "section")
    eq("**load (chunk)**", first_line())
    local msgs = capture(function()
      press "n"
    end)
    eq({ "devdocs: no next section" }, msgs)
    eq("section", mode())
    press "N"
    shown(32, 3)
    eq("# 3 – The Language", first_line())
    eq(1, cur())
    press "n"
    shown(35, 6)
    eq(1, cur())
    viewer.close()
  end)

  it("whole page: an unanchored term is no stop", function()
    open("index", "page")
    at(32)
    local msgs = capture(function()
      press "n"
    end)
    eq({ "devdocs: no next section" }, msgs)
    eq(32, cur())
    viewer.close()
  end)

  it("e after p shows the examples of the page the view was turned to", function()
    open("index", "page")
    at(18)
    viewer.toggle()
    eq(15, viewer.current_view().page_start)
    viewer.set_mode "examples"
    eq({ "**values 18**", "```lua", "# not a heading", "```" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    local chunks = vim.api.nvim_win_get_config(0).footer
    local text = type(chunks) == "table" and table.concat(vim.tbl_map(function(c)
      return c[1]
    end, chunks)) or chunks
    ok(text:find("p pages", 1, true), text)
    viewer.close()
  end)

  it("e twice returns to the view e came from", function()
    open("index", "page")
    at(18)
    press "e"
    eq("examples", mode())
    press "e"
    eq("page", mode())
    eq(18, cur())
    viewer.close()
    open("index#2.1", "section")
    press "e"
    press "e"
    eq("section", mode())
    viewer.close()
  end)

  it("opens an entry without a fragment, or an unknown one, as the whole page", function()
    open("index#nope", "section")
    eq("page", mode())
    eq(40, vim.api.nvim_buf_line_count(0))
    viewer.close()
    open("index", "section")
    eq("page", mode())
    local footer = vim.api.nvim_win_get_config(0).footer
    local text = type(footer) == "table" and table.concat(vim.tbl_map(function(c)
      return c[1]
    end, footer)) or footer
    ok(text:find("p paginated", 1, true), text)
    viewer.close()
  end)

  it("examples view steps between examples", function()
    open("index#2.1", "examples")
    eq(
      { "**values 18**", "```lua", "# not a heading", "```", "", "**details 23**", "```sh", "echo hi", "```" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
    at(1)
    press "n"
    eq(6, cur())
    local msgs = capture(function()
      press "n"
    end)
    eq(6, cur())
    eq({ "devdocs: no next example" }, msgs)
    press "N"
    eq(1, cur())
    press "c"
    eq(6, cur())
    eq("examples", mode())
    viewer.close()
  end)

  it("does nothing on the help screen", function()
    open("index#2.1", "section")
    viewer.help()
    local before = cur()
    local msgs = capture(function()
      press "n"
      press "C"
    end)
    eq({}, msgs)
    eq("help", mode())
    eq(before, cur())
    viewer.close()
  end)

  it("lists the keys in the footer and the help", function()
    local footer = footer_text(viewer.FOOTER)
    ok(footer:find("n/N section", 1, true), footer)
    ok(footer:find("c/C chapter", 1, true), footer)
    ok(footer:find("p pages", 1, true), footer)
    local help = table.concat((viewer.help_lines(80)), "\n")
    ok(help:find("  n / N", 1, true))
    ok(help:find("  c / C", 1, true))
    ok(help:find("/ Enter", 1, true))
  end)

  it("viewer.jump with no viewer open is a no-op", function()
    viewer.close()
    viewer.jump("section", 1, 1)
  end)
end)

describe("viewer help screen (aligned tables)", function()
  local root = tmpdir()
  config.resolve { data_dir = root, view = { height = 6 } }
  store.invalidate()
  local slug = "lua~5.4"
  store.write_json(paths.meta_file(slug), { slug = slug, name = "Lua", doc_version = "5.4" }, "meta")
  store.write_file(paths.entries_file(slug), store.encode_entries {})
  store.write_file(paths.page_file(slug, "index"), "# Manual\n\ntext\n")
  store.invalidate()

  local function span_texts(lines, spans, hl)
    local out = {}
    for _, s in ipairs(spans) do
      if s.hl == hl then
        out[#out + 1] = lines[s.row]:sub(s.col_start + 1, s.col_end)
      end
    end
    return out
  end
  local function dw(str)
    return vim.fn.strdisplaywidth(str)
  end
  --- display column where the action text starts, from the header row
  local function action_col(lines)
    for _, l in ipairs(lines) do
      local at = l:find("Action", 1, true)
      if at and vim.startswith(l, "  Key") then
        return dw(l:sub(1, at - 1))
      end
    end
  end

  it("is a titled Key / Action table", function()
    local lines, spans = viewer.help_lines(80)
    eq("DevDocs viewer keys", lines[1])
    local header
    for i, l in ipairs(lines) do
      if vim.startswith(l, "  Key") then
        header = i
      end
    end
    ok(header, "no header row")
    local got = {}
    for _, s in ipairs(spans) do
      if s.row == header then
        eq("DevDocsHelpHeader", s.hl)
        got[#got + 1] = lines[header]:sub(s.col_start + 1, s.col_end)
      end
    end
    eq({ "Key", "Action" }, got)
  end)

  it("highlights the keys and puts every action in one column", function()
    local lines, spans = viewer.help_lines(80)
    local keys = span_texts(lines, spans, "DevDocsKey")
    for _, k in ipairs { "q, Esc", "Enter (<CR>), double-click", "Backspace (<BS>), u", "Ctrl-f / Ctrl-b", "n / N" } do
      ok(vim.tbl_contains(keys, k), k)
    end
    local col = action_col(lines)
    ok(col, "no action column")
    for _, s in ipairs(spans) do
      if s.hl == "DevDocsKey" then
        local rest = lines[s.row]:sub(s.col_end + 1)
        local pad = #rest:match "^ *"
        eq(col, dw(lines[s.row]:sub(1, s.col_end + pad)), lines[s.row])
      end
    end
    for _, l in ipairs(lines) do
      ok(dw(l) <= 80, l)
    end
  end)

  it("names both views in the p row", function()
    local lines, spans = viewer.help_lines(80)
    local found
    for _, s in ipairs(spans) do
      if s.hl == "DevDocsKey" and lines[s.row]:sub(s.col_start + 1, s.col_end) == "p" then
        found = lines[s.row]
      end
    end
    ok(found, "no p row")
    ok(found:find("paginated", 1, true), found)
    ok(found:find("pages", 1, true), found)
  end)

  it("wraps long actions under the action column on a narrow float", function()
    local lines, spans = viewer.help_lines(60)
    local col = action_col(lines)
    local has_span = {}
    for _, s in ipairs(spans) do
      has_span[s.row] = true
    end
    local continuations = 0
    for i, l in ipairs(lines) do
      ok(dw(l) <= 60, l)
      if l ~= "" and not has_span[i] then
        continuations = continuations + 1
        eq(string.rep(" ", col), l:sub(1, col), l)
        ok(l:sub(col + 1, col + 1):match "%S", l)
      end
    end
    ok(continuations > 0, "nothing wrapped")
  end)

  it("shows the table in the float, headers bold", function()
    viewer.open { slug = slug, path = "index", mode = "page" }
    viewer.help()
    local width = vim.api.nvim_win_get_width(0)
    local expected = viewer.help_lines(width)
    eq(expected, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    local seen = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
      if m[4].hl_group == "DevDocsHelpHeader" then
        seen = true
      end
    end
    ok(seen, "no DevDocsHelpHeader extmark")
    viewer.close()
  end)
end)
