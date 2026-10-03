local hints = require "devdocs.ui.hints"

local H = { { "o", "browser" }, { "⏎", "follow" }, { "q", "close" } }

--- The text of every span with highlight `hl`.
local function texts(line, spans, hl)
  local out = {}
  for _, s in ipairs(spans) do
    if s.hl == hl then
      out[#out + 1] = line:sub(s.col_start + 1, s.col_end)
    end
  end
  return out
end

--- The text of every span with highlight `hl`, over help lines (spans carry a row).
local function texts_all(lines, spans, hl)
  local out = {}
  for _, s in ipairs(spans) do
    if s.hl == hl then
      out[#out + 1] = lines[s.row]:sub(s.col_start + 1, s.col_end)
    end
  end
  return out
end

describe("key hints", function()
  it("joins key / action pairs into one line", function()
    eq("o browser  ⏎ follow  q close", hints.text(H))
    eq("o browser   ⏎ follow   q close", hints.text(H, "   "))
  end)

  it("highlights each key in DevDocsKey and the rest in DevDocsDim, by byte column", function()
    local line, spans = hints.line(H, { prefix = " " })
    eq(" o browser  ⏎ follow  q close", line)
    eq({ "o", "⏎", "q" }, texts(line, spans, "DevDocsKey"))
    eq({ " ", " browser  ", " follow  ", " close" }, texts(line, spans, "DevDocsDim"))
    -- spans tile the line: no gaps, no overlaps
    local at = 0
    for _, s in ipairs(spans) do
      eq(at, s.col_start)
      at = s.col_end
    end
    eq(#line, at)
  end)

  it("drops spans past a truncation width", function()
    local line, spans = hints.line(H, { prefix = " ", width = 12 })
    ok(vim.fn.strdisplaywidth(line) <= 12, line)
    for _, s in ipairs(spans) do
      ok(s.col_end <= #line, vim.inspect(s))
    end
  end)

  it("builds float footer chunks: keys in DevDocsKey, actions in DevDocsDim", function()
    local chunks = hints.chunks(H, 80)
    eq({
      { " ", "DevDocsDim" },
      { "o", "DevDocsKey" },
      { " browser  ", "DevDocsDim" },
      { "⏎", "DevDocsKey" },
      { " follow  ", "DevDocsDim" },
      { "q", "DevDocsKey" },
      { " close ", "DevDocsDim" },
    }, chunks)
  end)

  it("drops trailing hints until the footer fits", function()
    local chunks = hints.chunks(H, 22)
    local text = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, chunks))
    eq(" o browser  ⏎ follow ", text)
    ok(vim.fn.strdisplaywidth(text) <= 22, text)
  end)
end)

describe("key hints in the viewer and the manager help", function()
  it("the viewer footer is key / action pairs", function()
    local viewer = require "devdocs.ui.viewer"
    eq(
      "⏎ follow  ⌫ back  e examples  p pages  n/N section  c/C chapter  s search  ? help  q close  o browser  y url",
      hints.text(viewer.FOOTER)
    )
    local lines, spans = viewer.help_lines(80)
    ok(#texts_all(lines, spans, "DevDocsKey") >= 8)
  end)

  it("the manager help is aligned tables: keys highlighted, Columns table not", function()
    local render = require "devdocs.ui.render"
    local lines, spans = render.help_lines(80)
    local keys = texts_all(lines, spans, "DevDocsKey")
    ok(#keys >= 15, #keys)
    for _, s in ipairs(spans) do
      if s.hl == "DevDocsKey" then
        ok(not lines[s.row]:find "^  Version", lines[s.row])
        ok(not lines[s.row]:find "^  Size", lines[s.row])
      end
    end
    local text = table.concat(lines, "\n")
    ok(text:find(":w", 1, true))
    ok(text:find("\nMarks\n", 1, true))
    ok(text:find("\nColumns\n", 1, true))
    -- both header rows (Key / Action, Column / Meaning) are bold
    local headers = {}
    for _, s in ipairs(spans) do
      if s.hl == "DevDocsHelpHeader" then
        headers[#headers + 1] = lines[s.row]:sub(s.col_start + 1, s.col_end)
      end
    end
    eq({ "Key", "Action", "Column", "Meaning" }, headers)
    -- every table shares one action column
    local cols = {}
    for _, s in ipairs(spans) do
      local l = lines[s.row]
      if s.hl == "DevDocsKey" then
        cols[vim.fn.strdisplaywidth(l:sub(1, s.col_end + #l:sub(s.col_end + 1):match "^ *"))] = true
      elseif s.hl == "DevDocsHelpHeader" and l:sub(s.col_start + 1, s.col_end) == "Meaning" then
        cols[vim.fn.strdisplaywidth(l:sub(1, s.col_start))] = true
      end
    end
    eq(1, vim.tbl_count(cols), vim.inspect(cols))
  end)
end)

describe("hints.wrap", function()
  it("wraps by display width, keeps over-long words whole", function()
    eq({ "a bb", "ccc" }, hints.wrap("a bb ccc", 4))
    eq({ "abcdefgh" }, hints.wrap("abcdefgh", 4))
    eq({ "……", "……" }, hints.wrap("…… ……", 2))
    eq({ "" }, hints.wrap("", 5))
  end)
end)

describe("hints.table", function()
  local ROWS = { { "q, Esc", "close" }, { "Enter (<CR>)", "follow" }, { "↑ / ↓", "move" }, { "V … m", "mark" } }
  local function spans_on(spans, row)
    return vim.tbl_filter(function(s)
      return s.row == row
    end, spans)
  end

  it("aligns the actions after the widest key, header included", function()
    local lines, spans = hints.table({ header = { "Key", "Action" }, rows = ROWS }, {})
    eq({
      "  Key" .. (" "):rep(12) .. "Action",
      "  q, Esc" .. (" "):rep(9) .. "close",
      "  Enter (<CR>)   follow",
      "  ↑ / ↓" .. (" "):rep(10) .. "move",
      "  V … m" .. (" "):rep(10) .. "mark",
    }, lines)
    eq({
      { row = 1, col_start = 2, col_end = 5, hl = "DevDocsHelpHeader" },
      { row = 1, col_start = 17, col_end = 23, hl = "DevDocsHelpHeader" },
    }, spans_on(spans, 1))
    eq({ { row = 4, col_start = 2, col_end = 11, hl = "DevDocsKey" } }, spans_on(spans, 4))
    eq({ { row = 2, col_start = 2, col_end = 8, hl = "DevDocsKey" } }, spans_on(spans, 2))
    for i = 2, 5 do
      local action = ROWS[i - 1][2]
      local at = lines[i]:find(action, 1, true)
      eq(17, vim.fn.strdisplaywidth(lines[i]:sub(1, at - 1)), lines[i])
    end
  end)

  it("wraps a long action under the action column when there is room", function()
    local row = { { "k", "one two three four five six seven" } }
    eq({ "  k   one two three four five", "      six seven" }, (hints.table({ rows = row }, { width = 30 })))
    eq({ "  k   one two three four five six seven" }, (hints.table({ rows = row }, { width = 25 })))
    local _, spans = hints.table({ rows = row }, { width = 30 })
    eq(1, #spans) -- continuation lines carry no span
  end)

  it("leaves the first column plain when keys = false", function()
    local lines, spans = hints.table({ keys = false, rows = { { "Version", "x" } } }, {})
    eq({ "  Version   x" }, lines)
    eq({}, spans)
  end)
end)

describe("hints.help", function()
  it("shares one key column between all the tables", function()
    local lines = hints.help({
      { rows = { { "a", "first" } } },
      "",
      { header = { "Column", "Meaning" }, keys = false, rows = { { "Version", "second" } } },
    }, {})
    eq({ "  a         first", "", "  Column    Meaning", "  Version   second" }, lines)
  end)

  it("highlights titles over the whole line and wraps text at indent 2", function()
    local lines, spans = hints.help({
      { title = "Marks" },
      { text = "aaa bbb ccc ddd eee fff ggg" },
    }, { width = 14 })
    eq("Marks", lines[1])
    eq({ { row = 1, col_start = 0, col_end = 5, hl = "DevDocsHeader" } }, spans)
    ok(#lines > 2, vim.inspect(lines))
    local words = {}
    for i = 2, #lines do
      ok(vim.startswith(lines[i], "  "), lines[i])
      ok(vim.fn.strdisplaywidth(lines[i]) <= 14, lines[i])
      words[#words + 1] = vim.trim(lines[i])
    end
    eq("aaa bbb ccc ddd eee fff ggg", table.concat(words, " "))
  end)
end)

describe("DevDocsHelpHeader highlight", function()
  it("is bold, defined by attributes rather than a link", function()
    local float = require "devdocs.ui.float"
    eq({ bold = true }, float.HIGHLIGHTS.DevDocsHelpHeader)
    float.apply_highlights()
    eq(true, vim.api.nvim_get_hl(0, { name = "DevDocsHelpHeader" }).bold)
  end)
end)
