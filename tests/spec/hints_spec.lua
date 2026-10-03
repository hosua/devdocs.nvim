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

  it("highlights the key column of help lines in key sections only", function()
    local lines = {
      "DevDocs viewer keys",
      "",
      "  q, <Esc>   close",
      "  V … m        mark every doc",
      "               a continuation  with two spaces",
      "  ?          this help;  q closes",
      "Columns",
      "  Version      not a key",
    }
    local spans = hints.help_spans(lines)
    local got = vim.tbl_map(function(s)
      eq("DevDocsKey", s.hl)
      return { s.row, lines[s.row]:sub(s.col_start + 1, s.col_end) }
    end, spans)
    eq({ { 3, "q, <Esc>" }, { 4, "V … m" }, { 6, "?" } }, got)
  end)
end)

describe("key hints in the viewer and the manager help", function()
  it("the viewer footer is key / action pairs", function()
    local viewer = require "devdocs.ui.viewer"
    eq(
      "⏎ follow  ⌫ back  e examples  p page  n/N section  c/C chapter  s search  ? help  q close  o browser  y url",
      hints.text(viewer.FOOTER)
    )
    ok(#hints.help_spans(viewer.HELP) >= 8)
  end)

  it("the manager help highlights its keys, not its Columns section", function()
    local render = require "devdocs.ui.render"
    local spans = hints.help_spans(render.HELP)
    ok(#spans >= 15, #spans)
    for _, s in ipairs(spans) do
      ok(not render.HELP[s.row]:find "^  Version", render.HELP[s.row])
    end
  end)
end)
