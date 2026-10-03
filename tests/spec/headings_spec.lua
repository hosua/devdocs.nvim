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
