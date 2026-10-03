-- The index view's drawing: lines, highlight spans, title, footer, help.
-- Written from the plan; the module is lua/devdocs/ui/glossary_render.lua.
local config = require "devdocs.config"
local glossary = require "devdocs.ui.glossary"
local gr = require "devdocs.ui.glossary_render"
local hints = require "devdocs.ui.hints"
local paths = require "devdocs.paths"
local render = require "devdocs.ui.render"
local store = require "devdocs.store"

local dw = vim.fn.strdisplaywidth

local META = {
  slug = "lua~5.4",
  name = "Lua",
  doc_version = "5.4",
  release = "5.4.1",
  types = {
    { slug = "manual", name = "Manual", count = 2 },
    { slug = "stdlib", name = "Standard Libraries", count = 3 },
  },
}
local ENTRIES = {
  { name = "Introduction", path = "index#1", type = "Manual" },
  { name = "Basic Concepts", path = "index#2", type = "Manual" },
  { name = "assert()", path = "index#pdf-assert", type = "Standard Libraries" },
  { name = "error()", path = "index#pdf-error", type = "Standard Libraries" },
  { name = "table.insert()", path = "index#pdf-table.insert", type = "Standard Libraries" },
}

local function act(t, extra)
  return vim.tbl_extend("force", { type = t }, extra or {})
end

--- render() may answer { lines, spans } or two values; take either.
local function draw(tree, rows, opts)
  local a, b = gr.render(tree, rows, opts)
  if b == nil and type(a) == "table" and a.lines then
    return a.lines, a.spans
  end
  return a, b
end

--- left text, then right text flush with the right edge of `width`
local function flush(left, right, width)
  return left .. string.rep(" ", width - dw(left) - dw(right)) .. right
end

local function span_texts(lines, spans, hl)
  local out = {}
  for _, s in ipairs(spans) do
    if s.hl == hl then
      out[#out + 1] = lines[s.row]:sub(s.col_start + 1, s.col_end)
    end
  end
  return out
end

describe("glossary_render.render", function()
  local tree = glossary.build("lua~5.4", META, ENTRIES)

  it("draws the doc row with the version flush right, and a collapsed row per type with its count", function()
    local rows = glossary.rows(tree, glossary.new())
    local lines = draw(tree, rows, { width = 40 })
    eq({
      flush("▾ Lua", "5.4.1", 40),
      flush("  ▸ Manual", "2", 40),
      flush("  ▸ Standard Libraries", "3", 40),
    }, lines)
  end)

  it("uses render.CHEVRON for every chevron", function()
    eq("▾ ", render.CHEVRON.open)
    eq("▸ ", render.CHEVRON.closed)
    local s = glossary.reduce(tree, glossary.new(), 3, act "toggle")
    local lines = draw(tree, glossary.rows(tree, s), { width = 40 })
    ok(vim.startswith(lines[1], render.CHEVRON.open .. "Lua"), lines[1])
    ok(vim.startswith(lines[2], "  " .. render.CHEVRON.closed .. "Manual"), lines[2])
    ok(vim.startswith(lines[3], "  " .. render.CHEVRON.open .. "Standard Libraries"), lines[3])
    -- and a closed doc shows the closed chevron
    local closed = glossary.reduce(tree, glossary.new(), 1, act "toggle")
    local l2 = draw(tree, glossary.rows(tree, closed), { width = 40 })
    ok(vim.startswith(l2[1], render.CHEVRON.closed .. "Lua"), l2[1])
  end)

  it("indents entries 6 cells under a type", function()
    local s = glossary.reduce(tree, glossary.new(), 3, act "toggle")
    local lines = draw(tree, glossary.rows(tree, s), { width = 40 })
    eq(6, #lines)
    eq("      assert()", lines[4])
    eq("      error()", lines[5])
    eq("      table.insert()", lines[6])
  end)

  it("indents a flat doc's entries 4 cells", function()
    local m = { slug = "deno~1", name = "Deno", doc_version = "1", types = { { name = "API", count = 2 } } }
    local t = glossary.build("deno~1", m, {
      { name = "Deno.cwd()", path = "api#cwd", type = "API" },
      { name = "Deno.exit()", path = "api#exit", type = "API" },
    })
    local lines = draw(t, glossary.rows(t, glossary.new()), { width = 40 })
    eq({ flush("▾ Deno", "1", 40), "    Deno.cwd()", "    Deno.exit()" }, lines)
  end)

  it("one line per row", function()
    local s = glossary.reduce(tree, glossary.new(), 1, act "expand_all")
    local rows = glossary.rows(tree, s)
    local lines = draw(tree, rows, { width = 40 })
    eq(#rows, #lines)
  end)

  it("cuts a long entry name with … so no line is wider than the window", function()
    local long = string.rep("abcdefghij", 8)
    local t = glossary.build("lua~5.4", META, {
      { name = "Introduction", path = "index#1", type = "Manual" },
      { name = long, path = "index#long", type = "Standard Libraries" },
      {
        name = "日本語日本語日本語日本語日本語日本語日本語日本語日本語",
        path = "index#cjk",
        type = "Standard Libraries",
      },
    })
    local s = glossary.reduce(t, glossary.new(), 3, act "toggle")
    local lines = draw(t, glossary.rows(t, s), { width = 40 })
    for i, l in ipairs(lines) do
      ok(dw(l) <= 40, ("line %d is %d wide: %s"):format(i, dw(l), l))
    end
    ok(lines[4]:find("…", 1, true), lines[4])
    ok(vim.startswith(lines[4], "      abcdef"), lines[4])
    ok(lines[5]:find("…", 1, true), lines[5])
  end)

  it("marks the current entry with ● in DevDocsMark", function()
    local s = glossary.reduce(tree, glossary.new(), 3, act "toggle")
    local rows = glossary.rows(tree, s)
    local current = tree.groups[2].entries[2]
    local lines, spans = draw(tree, rows, { width = 40, current = current })
    ok(lines[5]:find("●", 1, true), lines[5])
    ok(lines[5]:find("error()", 1, true), lines[5])
    ok(not lines[4]:find("●", 1, true), lines[4])
    ok(not lines[6]:find("●", 1, true), lines[6])
    local marks = span_texts(lines, spans, "DevDocsMark")
    eq(1, #marks)
    eq("●", vim.trim(marks[1]))
    for _, sp in ipairs(spans) do
      if sp.hl == "DevDocsMark" then
        eq(5, sp.row)
      end
    end
  end)

  it("names the doc in DevDocsHeader and the version and counts in DevDocsDim", function()
    local lines, spans = draw(tree, glossary.rows(tree, glossary.new()), { width = 40 })
    local headers = span_texts(lines, spans, "DevDocsHeader")
    eq(1, #headers)
    ok(headers[1]:find("Lua", 1, true), headers[1])
    local dim = vim.tbl_map(vim.trim, span_texts(lines, spans, "DevDocsDim"))
    ok(vim.tbl_contains(dim, "5.4.1"), vim.inspect(dim))
    ok(vim.tbl_contains(dim, "2"), vim.inspect(dim))
    ok(vim.tbl_contains(dim, "3"), vim.inspect(dim))
    for _, sp in ipairs(spans) do
      ok(sp.row >= 1 and sp.row <= #lines, vim.inspect(sp))
      ok(sp.col_end <= #lines[sp.row], vim.inspect(sp))
    end
  end)

  it("highlights the filter hits in DevDocsMatch, by byte column", function()
    local t = glossary.build("lua~5.4", META, {
      { name = "héllo.Insert()", path = "index#a", type = "Standard Libraries" },
      { name = "table.insert()", path = "index#b", type = "Standard Libraries" },
      { name = "error()", path = "index#c", type = "Standard Libraries" },
    })
    local s = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "ins" }))
    local rows = glossary.rows(t, s)
    local lines, spans = draw(t, rows, { width = 40, filter = "ins" })
    local hits = span_texts(lines, spans, "DevDocsMatch")
    eq({ "Ins", "ins" }, hits)
    -- the é is two bytes: the column is a byte offset, not a character count
    local first = vim.tbl_filter(function(sp)
      return sp.hl == "DevDocsMatch"
    end, spans)[1]
    eq(lines[first.row]:find("Ins", 1, true) - 1, first.col_start)
  end)

  it("shows matches/total on a type while filtering", function()
    local many = {}
    for i = 1, 141 do
      many[i] = { name = ("fn%03d"):format(i), path = "index#" .. i, type = "Standard Libraries" }
    end
    many[10].name = "target_a"
    many[50].name = "TARGET_b"
    many[100].name = "my_target_c"
    many[142] = { name = "Introduction", path = "index#1", type = "Manual" }
    local t = glossary.build("lua~5.4", META, many)
    local plain = draw(t, glossary.rows(t, glossary.new()), { width = 40 })
    eq(flush("  ▸ Standard Libraries", "141", 40), plain[#plain])
    local s = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "target" }))
    local lines = draw(t, glossary.rows(t, s), { width = 40, filter = "target" })
    local g = vim.tbl_filter(function(l)
      return l:find("Standard Libraries", 1, true)
    end, lines)[1]
    eq(flush("  ▾ Standard Libraries", "3/141", 40), g)
  end)
end)

describe("glossary_render.title / empty", function()
  local root = tmpdir()
  config.resolve { data_dir = root }
  store.invalidate()
  store.write_json(paths.meta_file "lua~5.4", META, "meta")
  store.invalidate()
  local tree = glossary.build("lua~5.4", META, ENTRIES)

  it("titles the index with the doc's breadcrumb", function()
    eq("Lua 5.4 › index", gr.title(tree, glossary.new(), 5))
  end)

  it("adds the filter and its match count while filtering", function()
    local s = glossary.reduce(tree, glossary.new(), 1, act("filter", { text = "assert" }))
    eq("Lua 5.4 › index › /assert (12)", gr.title(tree, s, 12))
  end)

  it("says when a doc has no entries", function()
    local t = glossary.build("lua~5.4", META, {})
    local msg = gr.empty(t)
    if type(msg) == "table" then
      msg = msg[1]
    end
    eq("  no entries in lua~5.4 (reinstall the doc)", msg)
  end)
end)

describe("glossary_render.FOOTER", function()
  it("lists the index keys in order", function()
    eq(
      "⏎ open  l/h expand/fold  / filter  I page  ⌫ back  s search  ? help  q close  d doc  o browser  y url",
      hints.text(gr.FOOTER)
    )
  end)

  it("keeps ? help and q close when a narrow footer drops the rest", function()
    local flagged = {}
    for _, h in ipairs(gr.FOOTER) do
      if h.keep or h[3] then
        flagged[#flagged + 1] = h[1]
      end
    end
    ok(vim.tbl_contains(flagged, "?") and vim.tbl_contains(flagged, "q"), vim.inspect(flagged))
    local chunks = hints.chunks(gr.FOOTER, 40)
    local text = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, chunks))
    ok(text:find("? help", 1, true), text)
    ok(text:find("q close", 1, true), text)
    ok(not text:find("y url", 1, true), text)
    ok(dw(text) <= 40, text)
  end)
end)

describe("glossary_render.HELP", function()
  local lines, spans = hints.help(gr.HELP, { width = 80 })

  it("is a titled Key / Action table", function()
    eq("DevDocs index keys", lines[1])
    local headers = span_texts(lines, spans, "DevDocsHelpHeader")
    eq({ "Key", "Action" }, headers)
  end)

  it("spells the keys out", function()
    local keys = span_texts(lines, spans, "DevDocsKey")
    for _, k in ipairs { "Enter (<CR>)", "Tab", "Backspace (<BS>), u", "q, Esc" } do
      ok(vim.tbl_contains(keys, k), k .. " in " .. vim.inspect(keys))
    end
  end)

  it("covers every key the index maps", function()
    local text = table.concat(lines, "\n")
    for _, needle in ipairs {
      "Enter (<CR>)",
      "l / h",
      "Tab",
      "zR",
      "zM",
      "} / {",
      "/",
      "I",
      "Backspace (<BS>)",
      "s",
      "d",
      "o / y",
      "j / k",
      "gg / G",
      "?",
      "q, Esc",
    } do
      ok(text:find(needle, 1, true), "help lacks " .. needle)
    end
    ok(text:find("filter entries by name", 1, true), "no filter row")
    ok(text:find("expand / collapse every type", 1, true), "no zR/zM row")
  end)

  it("every line fits the width", function()
    for _, l in ipairs(lines) do
      ok(dw(l) <= 80, l)
    end
  end)
end)

describe("glossary at scale", function()
  it("builds, expands and renders 50k entries in types of 10 in under a second", function()
    local types, es = {}, {}
    for t = 1, 5000 do
      types[t] = { slug = "t" .. t, name = "Type " .. t, count = 10 }
      for e = 1, 10 do
        es[#es + 1] = { name = ("entry_%d_%d"):format(t, e), path = ("p%d#e%d"):format(t, e), type = "Type " .. t }
      end
    end
    local meta = { slug = "big~1", name = "Big", doc_version = "1", types = types }
    local started = vim.uv.hrtime()
    local tree = glossary.build("big~1", meta, es)
    local s = glossary.reduce(tree, glossary.new(), 1, act "expand_all")
    local rows = glossary.rows(tree, s)
    local lines = draw(tree, rows, { width = 80 })
    local filtered = glossary.rows(tree, (glossary.reduce(tree, s, 1, act("filter", { text = "entry_77" }))))
    local ms = (vim.uv.hrtime() - started) / 1e6
    eq(1 + 5000 + 50000, #rows)
    eq(#rows, #lines)
    ok(#filtered > 1)
    ok(ms < 1000, ("took %d ms"):format(ms))
  end)

  it("handles one big type (13956 entries) and a missing type list", function()
    local es = {}
    for i = 1, 13956 do
      es[i] = { name = "n" .. i, path = "p#" .. i, type = "Only" }
    end
    local t = glossary.build("scala~3", { slug = "scala~3", name = "Scala", doc_version = "3" }, es)
    ok(t.flat)
    eq(13957, #glossary.rows(t, glossary.new()))
  end)
end)
