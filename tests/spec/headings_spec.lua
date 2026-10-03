local headings = require "devdocs.headings"

--- {line, level} pairs -> DevDocsHeading list
local function hs(pairs_)
  local out = {}
  for _, p in ipairs(pairs_) do
    out[#out + 1] = { line = p[1], level = p[2] }
  end
  return out
end

--- Headings at lines 1..n with the given levels.
local function levels(list)
  local out = {}
  for i, l in ipairs(list) do
    out[i] = { line = i, level = l }
  end
  return out
end

describe("headings", function()
  it("reads the ATX level of a line", function()
    eq(1, headings.level "# a")
    eq(6, headings.level "###### f")
    eq(1, headings.level "#\tTab")
    eq(0, headings.level "####### g")
    eq(0, headings.level "#include <x>")
    eq(0, headings.level "#")
    eq(0, headings.level "#page {")
    eq(0, headings.level "  ## indented")
    eq(0, headings.level "> ## quoted")
    eq(0, headings.level "- ## item")
    eq(0, headings.level "plain")
    eq(0, headings.level "**bold**")
  end)

  it("parses headings of every level in line order", function()
    local lines = { "# T", "", "text", "## A", "x", "### a1", "## B" }
    eq(hs { { 1, 1 }, { 4, 2 }, { 6, 3 }, { 7, 2 } }, headings.parse(lines))
  end)

  local FENCED =
    { "# T", "```sh", "# comment", "## not", "```", "## A", "````md", "```", "# still code", "```", "````", "## B" }

  it("ignores headings inside fences, including a 4-backtick fence around ```", function()
    eq(hs { { 1, 1 }, { 6, 2 }, { 12, 2 } }, headings.parse(FENCED))
  end)

  it("ignores headings inside an indented fence", function()
    eq(hs { { 5, 2 } }, headings.parse { "- item", "  ```python", "  # comment", "  ```", "## After" })
  end)

  it("treats an unclosed fence as running to the end", function()
    eq(hs { { 1, 2 } }, headings.parse { "## A", "```", "# x", "## y" })
  end)

  it("does not read setext headings", function()
    eq(hs { { 5, 2 } }, headings.parse { "Title", "=====", "Sub", "-----", "## Real" })
  end)

  it("reports the fenced lines, fence lines included", function()
    local keys = vim.tbl_keys(headings.fenced(FENCED))
    table.sort(keys)
    eq({ 2, 3, 4, 5, 7, 8, 9, 10, 11 }, keys)
    eq({}, headings.fenced { "# a", "text" })
  end)

  it("finds the headings of a typescript page whose # lines are shell comments", function()
    local lines = {
      "# tsc CLI Options",
      "",
      "Was this page helpful?",
      "",
      "# tsc CLI Options",
      "",
      "## Using the CLI",
      "",
      "Running `tsc` locally will compile the closest project",
      "",
      "```shell",
      "# Run a compile based on a backwards look through the fs for a tsconfig.json",
      "tsc",
      "",
      "# Emit JS for just the index.ts with the compiler defaults",
      "tsc index.ts",
      "```",
      "",
      "## Compiler Options",
    }
    local h = headings.parse(lines)
    eq(hs { { 1, 1 }, { 5, 1 }, { 7, 2 }, { 19, 2 } }, h)
    eq(2, headings.chapter_level(h))
    eq(19, headings.target(h, 8, 1, "section"))
    eq(19, headings.target(h, 8, 1, "chapter"))
    eq(7, headings.target(h, 18, -1, "chapter"))
  end)

  it("picks the chapter level", function()
    eq(nil, headings.chapter_level {})
    eq(1, headings.chapter_level(levels { 1 }))
    eq(3, headings.chapter_level(levels { 3 }))
    eq(1, headings.chapter_level(levels { 1, 1, 1, 2, 2, 3, 1, 2 }))
    eq(2, headings.chapter_level(levels { 1, 2, 3, 2, 2 }))
    eq(3, headings.chapter_level(levels { 1, 3, 3, 3 }))
    eq(3, headings.chapter_level(levels { 1, 2, 3, 3 }))
    eq(2, headings.chapter_level(levels { 1, 3, 1, 2, 2, 2 }))
    eq(3, headings.chapter_level(levels { 1, 1, 3, 3, 3 }))
    eq(1, headings.chapter_level(levels { 2, 1, 1 }))
    eq(2, headings.chapter_level(levels { 1, 2 }))
  end)

  describe("moves on a Lua-manual-like page", function()
    local lines = {
      "# Manual", -- 1
      "",
      "# 1 – Introduction", -- 3
      "text",
      "# 2 – Basic Concepts", -- 5
      "",
      "## 2.1 – Values", -- 7
      "text",
      "```lua", -- 9
      "# not a heading",
      "```",
      "### 2.1.1 – Details", -- 12
      "text",
      "## 2.2 – Environments", -- 14
      "text",
      "# 3 – The Language", -- 16
      "text",
      "## 3.1 – Lexical", -- 18
      "text",
    }
    local h = headings.parse(lines)

    local function line_of(kind, dir, cursor, count)
      return headings.target(h, cursor, dir, kind, count)
    end

    it("parses the headings and the chapter level", function()
      local got = {}
      for _, x in ipairs(h) do
        got[#got + 1] = x.line
      end
      eq({ 1, 3, 5, 7, 12, 14, 16, 18 }, got)
      eq(1, headings.chapter_level(h))
    end)

    it("moves to the next and previous section", function()
      eq(3, line_of("section", 1, 1))
      eq(5, line_of("section", 1, 4))
      eq(7, line_of("section", 1, 5))
      eq(12, line_of("section", 1, 8))
      eq(nil, line_of("section", 1, 18))
      eq(nil, line_of("section", 1, 19))
      eq(7, line_of("section", -1, 8))
      eq(5, line_of("section", -1, 7))
      eq(12, line_of("section", -1, 13))
      eq(1, line_of("section", -1, 2))
      eq(nil, line_of("section", -1, 1))
    end)

    it("honours a count, clamped to the farthest heading", function()
      eq(7, line_of("section", 1, 1, 3))
      eq(18, line_of("section", 1, 1, 100))
      eq(3, line_of("section", 1, 1, nil))
      eq(3, line_of("section", 1, 1, 0))
      eq(16, line_of("section", -1, 19, 2))
      eq(1, line_of("section", -1, 19, 100))
    end)

    it("moves between chapters only", function()
      eq(3, line_of("chapter", 1, 1))
      eq(16, line_of("chapter", 1, 8))
      eq(nil, line_of("chapter", 1, 16))
      eq(nil, line_of("chapter", 1, 17))
      eq(16, line_of("chapter", -1, 17))
      eq(5, line_of("chapter", -1, 16))
      eq(5, line_of("chapter", -1, 13))
      eq(3, line_of("chapter", -1, 13, 2))
      eq(1, line_of("chapter", -1, 2))
      eq(nil, line_of("chapter", -1, 1))
      eq(16, line_of("chapter", 1, 4, 5))
    end)

    it("finds nothing on a page without headings", function()
      eq(nil, headings.target({}, 5, 1, "section"))
      eq(nil, headings.target({}, 5, 1, "chapter"))
    end)
  end)

  describe("real pages (golden fixtures)", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h") .. "/fixtures"
    local function load(name)
      local h = headings.parse(vim.fn.readfile(root .. "/" .. name .. ".md"))
      local ls, lv = {}, {}
      for i, x in ipairs(h) do
        ls[i], lv[i] = x.line, x.level
      end
      return h, ls, lv
    end

    it("css grid-template-areas: title, MDN H2 chapters", function()
      local h, ls, lv = load "css__properties~grid-template-areas"
      eq({ 1, 11, 75, 95, 106, 115, 123, 125, 127, 138, 176, 178, 184, 192 }, ls)
      eq({ 1, 2, 2, 3, 2, 2, 2, 3, 4, 4, 4, 2, 2, 2 }, lv)
      eq(2, headings.chapter_level(h))
      eq(11, headings.target(h, 1, 1, "chapter"))
      eq(106, headings.target(h, 95, 1, "chapter"))
      eq(106, headings.target(h, 96, 1, "section"))
      eq(127, headings.target(h, 130, -1, "section"))
      eq(123, headings.target(h, 130, -1, "chapter"))
    end)

    it("cpp std::cout: H3 chapters", function()
      local h, ls, lv = load "cpp__io~cout"
      eq({ 1, 21, 27, 61 }, ls)
      eq({ 1, 3, 3, 3 }, lv)
      eq(3, headings.chapter_level(h))
      eq(21, headings.target(h, 1, 1, "chapter"))
      eq(27, headings.target(h, 22, 1, "section"))
    end)

    it("javascript Array.prototype.map: H2 chapters over H3 examples", function()
      local h = load "javascript__global_objects~array~map"
      eq(2, headings.chapter_level(h))
      eq(279, headings.target(h, 61, 1, "chapter"))
      eq(73, headings.target(h, 61, 1, "section"))
      eq(285, headings.target(h, 300, -1, "chapter", 2))
    end)

    it("python os.path: a title-only page", function()
      local h = load "python~3.12__library~os.path"
      eq(hs { { 1, 1 } }, h)
      eq(1, headings.chapter_level(h))
      eq(nil, headings.target(h, 50, 1, "section"))
      eq(1, headings.target(h, 50, -1, "section"))
    end)
  end)

  describe("pages (paginated view)", function()
    local function spans_of(pages)
      local out = {}
      for i, p in ipairs(pages) do
        out[i] = { p.first, p.last }
      end
      return out
    end
    local function pages(lines, opts)
      return spans_of(headings.pages(lines, opts))
    end

    it("pads short sections with the following ones until 5 body lines", function()
      eq(
        { { 1, 6 }, { 7, 12 }, { 13, 14 } },
        pages { "# T", "a", "b", "c", "d", "e", "## A", "1", "2", "3", "4", "5", "## B", "x" }
      )
      eq({ { 1, 8 }, { 9, 10 } }, pages { "# T", "a", "## A", "1", "## B", "1", "2", "3", "## C", "z" })
    end)

    it("does not count blank lines", function()
      eq({ { 1, 12 } }, pages { "# T", "", "a", "", "b", "", "c", "", "d", "", "## A", "x" })
    end)

    it("ignores headings inside fences but counts fence lines", function()
      eq({ { 1, 6 }, { 7, 12 } }, pages { "# T", "```sh", "# c", "## d", "```", "x", "## A", "1", "2", "3", "4", "5" })
    end)

    it("starts with a preamble page that merges forward", function()
      eq({ { 1, 8 } }, pages { "p1", "p2", "# T", "a", "b", "c", "d", "e" })
      eq({ { 1, 5 }, { 6, 7 } }, pages { "p1", "p2", "p3", "p4", "p5", "# T", "a" })
    end)

    it("makes one page of a page without headings, none of an empty one", function()
      eq({ { 1, 3 } }, pages { "a", "b", "c" })
      eq({}, pages {})
    end)

    it("breaks at the given definition-term lines only", function()
      local lines = {
        "# T",
        "a",
        "b",
        "c",
        "d",
        "e",
        "**f()**",
        "",
        "  1",
        "  2",
        "  3",
        "  4",
        "  5",
        "**g()**",
        "",
        "  1",
      }
      eq({ { 1, 6 }, { 7, 13 }, { 14, 16 } }, pages(lines, { breaks = { [7] = true, [14] = true } }))
      eq({ { 1, 16 } }, pages(lines))
    end)

    it("never merges across the hard break, and starts a page there", function()
      local lines = { "# T", "a", "## A", "1", "2", "3", "4", "5" }
      eq({ { 1, 2 }, { 3, 8 } }, pages(lines, { hard = 3 }))
      eq({ { 1, 8 } }, pages(lines))
      eq({ { 1, 4 }, { 5, 8 } }, pages(lines, { hard = 5 }))
    end)

    it("honours min_body, ignores fenced breaks and closes an unclosed fence at the end", function()
      eq({ { 1, 2 }, { 3, 4 } }, pages({ "# T", "a", "## A", "b" }, { min_body = 1 }))
      eq({ { 1, 6 } }, pages({ "# T", "a", "```", "b", "```", "c" }, { breaks = { [4] = true }, min_body = 1 }))
      eq({ { 1, 4 } }, pages { "# T", "```", "# x", "## y" })
    end)

    it("finds the page of a line, clamped", function()
      local ps = { { first = 1, last = 6 }, { first = 7, last = 12 }, { first = 13, last = 14 } }
      local i, p = headings.page_at(ps, 7)
      eq(2, i)
      eq({ first = 7, last = 12 }, p)
      eq(1, (headings.page_at(ps, 0)))
      eq(3, (headings.page_at(ps, 99)))
      eq(nil, (headings.page_at({}, 3)))
    end)

    it("slices a page and trims its trailing blank lines", function()
      eq({ "a", "b" }, headings.page_lines({ "a", "b", "", "", "" }, { first = 1, last = 5 }))
      eq({ "x", "y" }, headings.page_lines({ "a", "x", "y", "", "z" }, { first = 2, last = 4 }))
      eq({ "" }, headings.page_lines({ "", "", "" }, { first = 1, last = 3 }))
    end)

    it("lists headings plus the page starts that are not headings, as n/N stops", function()
      local stops = headings.stops(
        hs { { 1, 1 }, { 9, 2 } },
        { { first = 1, last = 4 }, { first = 5, last = 8 }, { first = 9, last = 12 } }
      )
      eq(hs { { 1, 1 }, { 5, 6 }, { 9, 2 } }, stops)
    end)
  end)

  describe("blocks (examples view)", function()
    it("makes one pseudo-heading per fenced block, at its caption when it has one", function()
      local lines = {
        "**Raises an error.**",
        "```lua",
        "assert(x)",
        "# comment",
        "```",
        "",
        "```sh",
        "echo",
        "```",
        "",
        "**Cap**",
        "````md",
        "```",
        "````",
      }
      eq(hs { { 1, 1 }, { 7, 1 }, { 11, 1 } }, headings.blocks(lines))
    end)

    it("is empty for the no-examples notice", function()
      eq(
        {},
        headings.blocks { "", "  No examples in x.", "", "  o opens the page on devdocs.io, p shows the whole page." }
      )
    end)
  end)
end)
