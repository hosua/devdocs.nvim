-- The index (glossary) view's pure model: tree, rows, reducer. Written from
-- the plan; the module is lua/devdocs/ui/glossary.lua.
local glossary = require "devdocs.ui.glossary"

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

local function entries()
  return {
    { name = "Introduction", path = "index#1", type = "Manual" },
    { name = "Basic Concepts", path = "index#2", type = "Manual" },
    { name = "assert()", path = "index#pdf-assert", type = "Standard Libraries" },
    { name = "error()", path = "index#pdf-error", type = "Standard Libraries" },
    { name = "table.insert()", path = "index#pdf-table.insert", type = "Standard Libraries" },
  }
end

local function tree()
  return glossary.build("lua~5.4", META, entries())
end

local function act(t, extra)
  return vim.tbl_extend("force", { type = t }, extra or {})
end

--- The group's name, whether a row carries its index, its table or its name.
local function gname(t, row)
  local g = row.group
  if type(g) == "number" then
    return t.groups[g].name
  elseif type(g) == "table" then
    return g.name
  end
  return g
end

local function kinds(rows)
  return vim.tbl_map(function(r)
    return r.kind
  end, rows)
end

local function names_of(t)
  return vim.tbl_map(function(g)
    return g.name
  end, t.groups)
end

local function row_of(rows, kind, pred)
  for i, r in ipairs(rows) do
    if r.kind == kind and (not pred or pred(r)) then
      return i, r
    end
  end
end

local function entry_row(t, rows, name)
  return row_of(rows, "entry", function(r)
    return glossary.target(r).name == name
  end)
end

local function group_row(t, rows, name)
  return row_of(rows, "group", function(r)
    return gname(t, r) == name
  end)
end

describe("glossary.build", function()
  it("groups entries by type in the order of meta.types, with the entry order kept", function()
    local t = tree()
    eq({ "Manual", "Standard Libraries" }, names_of(t))
    eq(
      { "Introduction", "Basic Concepts" },
      vim.tbl_map(function(e)
        return e.name
      end, t.groups[1].entries)
    )
    eq("assert()", t.groups[2].entries[1].name)
    eq(2, #t.groups[1].entries)
    eq(3, #t.groups[2].entries)
  end)

  it("carries the doc's slug, name, version and total", function()
    local t = tree()
    eq("lua~5.4", t.slug)
    eq("Lua", t.name)
    eq(5, t.total)
    eq(false, t.flat and true or false)
  end)

  it("takes the version from meta.release, else doc_version, else empty", function()
    eq("5.4.1", tree().version)
    local m = vim.deepcopy(META)
    m.release = nil
    eq("5.4", glossary.build("lua~5.4", m, entries()).version)
    m.doc_version = nil
    eq("", glossary.build("lua~5.4", m, entries()).version)
  end)

  it("counts from the entries, not from meta.types[].count", function()
    local m = vim.deepcopy(META)
    m.types[1].count = 99
    local t = glossary.build("lua~5.4", m, entries())
    eq(2, #t.groups[1].entries)
  end)

  it("appends types missing from meta.types in first-seen order, and puts the empty type last as Other", function()
    local es = entries()
    es[#es + 1] = { name = "zeta", path = "z", type = "Zeta" }
    es[#es + 1] = { name = "loose", path = "l", type = "" }
    es[#es + 1] = { name = "alpha", path = "a", type = "Alpha" }
    local t = glossary.build("lua~5.4", META, es)
    eq({ "Manual", "Standard Libraries", "Zeta", "Alpha", "Other" }, names_of(t))
    eq("loose", t.groups[5].entries[1].name)
    eq(8, t.total)
  end)

  it("groups by entry type, first seen, when meta has no types", function()
    local m = { slug = "x~1", name = "X", doc_version = "1" }
    local t = glossary.build("x~1", m, entries())
    eq({ "Manual", "Standard Libraries" }, names_of(t))
    eq(5, t.total)
  end)

  it("is flat with one type, or none", function()
    local m = { slug = "deno~1", name = "Deno", types = { { name = "API", count = 2 } } }
    local one = glossary.build("deno~1", m, {
      { name = "Deno.cwd()", path = "api#cwd", type = "API" },
      { name = "Deno.exit()", path = "api#exit", type = "API" },
    })
    ok(one.flat)
    eq(1, #one.groups)
    local none = glossary.build("deno~1", { slug = "deno~1", name = "Deno" }, {})
    ok(none.flat)
    eq(0, none.total)
  end)

  it("keeps entries with the same name under different types", function()
    local es = {
      { name = "print()", path = "index#print", type = "Manual" },
      { name = "print()", path = "index#pdf-print", type = "Standard Libraries" },
    }
    local t = glossary.build("lua~5.4", META, es)
    eq("print()", t.groups[1].entries[1].name)
    eq("print()", t.groups[2].entries[1].name)
    eq(2, t.total)
  end)

  it("handles a type with no entries without erroring", function()
    local m = vim.deepcopy(META)
    m.types[#m.types + 1] = { slug = "empty", name = "Empty", count = 0 }
    local t = glossary.build("lua~5.4", m, entries())
    for _, g in ipairs(t.groups) do
      if g.name == "Empty" then
        eq(0, #g.entries)
      end
    end
    eq(5, t.total)
  end)
end)

describe("glossary.rows", function()
  it("starts with the doc row, then one collapsed row per type", function()
    local t = tree()
    local rows = glossary.rows(t, glossary.new())
    eq({ "doc", "group", "group" }, kinds(rows))
    eq(0, rows[1].depth)
    eq(1, rows[2].depth)
    eq(1, rows[3].depth)
    eq(false, rows[2].expanded and true or false)
    eq(2, rows[2].count)
    eq(2, rows[2].total)
    eq(3, rows[3].count)
    eq("Standard Libraries", gname(t, rows[3]))
  end)

  it("lists a type's entries, depth 2, once it is expanded", function()
    local t = tree()
    local s = glossary.new()
    local rows = glossary.rows(t, (glossary.reduce(t, s, 3, act "toggle")))
    eq({ "doc", "group", "group", "entry", "entry", "entry" }, kinds(rows))
    eq(true, rows[3].expanded and true or false)
    eq(2, rows[4].depth)
    eq("assert()", glossary.target(rows[4]).name)
    eq("table.insert()", glossary.target(rows[6]).name)
  end)

  it("hides everything under a closed doc row", function()
    local t = tree()
    local s = glossary.reduce(t, glossary.new(), 1, act "toggle")
    eq({ "doc" }, kinds(glossary.rows(t, s)))
  end)

  it("puts a single type's entries straight under the doc row at depth 1", function()
    local m = { slug = "deno~1", name = "Deno", types = { { name = "API", count = 2 } } }
    local t = glossary.build("deno~1", m, {
      { name = "Deno.cwd()", path = "api#cwd", type = "API" },
      { name = "Deno.exit()", path = "api#exit", type = "API" },
    })
    local rows = glossary.rows(t, glossary.new())
    eq({ "doc", "entry", "entry" }, kinds(rows))
    eq(1, rows[2].depth)
    eq("Deno.cwd()", glossary.target(rows[2]).name)
  end)

  it("filters by a case-insensitive plain substring of the entry name", function()
    local t = tree()
    local s = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "ASSERT" }))
    local rows = glossary.rows(t, s)
    eq({ "doc", "group", "entry" }, kinds(rows))
    eq("assert()", glossary.target(rows[3]).name)
    -- plain text: "(" and "." are not pattern characters
    local p = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "()" }))
    eq(3, #vim.tbl_filter(function(r)
      return r.kind == "entry"
    end, glossary.rows(t, p)))
    local dot = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "table.ins" }))
    eq({ "doc", "group", "entry" }, kinds(glossary.rows(t, dot)))
    local no = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "t.ins" }))
    eq({ "doc" }, kinds(glossary.rows(t, no)))
  end)

  it("forces matching types open, hides empty ones, and counts matches", function()
    local t = tree()
    local s = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "r" }))
    local rows = glossary.rows(t, s)
    -- nothing was expanded by hand, yet the matches show
    eq({ "doc", "group", "entry", "group", "entry", "entry", "entry" }, kinds(rows))
    eq(true, rows[2].expanded and true or false)
    eq(1, rows[2].count)
    eq(2, rows[2].total)
    eq(3, rows[4].count)
    local filtered = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "error" }))
    local frows = glossary.rows(t, filtered)
    eq({ "doc", "group", "entry" }, kinds(frows))
    eq(1, frows[2].count)
    eq(3, frows[2].total)
    eq("Standard Libraries", gname(t, frows[2]))
  end)

  it("filters a flat doc's entries under the doc row", function()
    local m = { slug = "deno~1", name = "Deno", types = { { name = "API", count = 2 } } }
    local t = glossary.build("deno~1", m, {
      { name = "Deno.cwd()", path = "api#cwd", type = "API" },
      { name = "Deno.exit()", path = "api#exit", type = "API" },
    })
    local s = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "exit" }))
    local rows = glossary.rows(t, s)
    eq({ "doc", "entry" }, kinds(rows))
    eq("Deno.exit()", glossary.target(rows[2]).name)
  end)

  it("target is the entry itself on entry rows and nil elsewhere", function()
    local t = tree()
    local s = glossary.reduce(t, glossary.new(), 3, act "toggle")
    local rows = glossary.rows(t, s)
    eq(nil, glossary.target(rows[1]))
    eq(nil, glossary.target(rows[2]))
    eq(nil, glossary.target(rows[3]))
    ok(
      glossary.target(rows[4]) == t.groups[2].entries[1]
        or vim.deep_equal(glossary.target(rows[4]), t.groups[2].entries[1])
    )
  end)
end)

describe("glossary.find", function()
  local es = {
    { name = "Introduction", path = "index#1", type = "Manual" },
    { name = "print()", path = "index#print", type = "Manual" },
    { name = "print()", path = "index#pdf-print", type = "Standard Libraries" },
    { name = "assert()", path = "index#pdf-assert", type = "Standard Libraries" },
    { name = "assert (alias)", path = "index#pdf-assert", type = "Standard Libraries" },
  }
  local t = glossary.build("lua~5.4", META, es)

  it("finds the exact path as group and entry indexes", function()
    local gi, ei = glossary.find(t, "index#pdf-print", "print()")
    eq(2, gi)
    eq(1, ei)
    local g1, e1 = glossary.find(t, "index#print", "print()")
    eq(1, g1)
    eq(2, e1)
  end)

  it("prefers the entry whose name matches when several share the path", function()
    local gi, ei = glossary.find(t, "index#pdf-assert", "assert (alias)")
    eq(2, gi)
    eq(3, ei)
    local g2, e2 = glossary.find(t, "index#pdf-assert", "assert()")
    eq(2, g2)
    eq(2, e2)
  end)

  it("falls back to the first entry on the same page, ignoring the fragment", function()
    local gi, ei = glossary.find(t, "index#nowhere")
    eq(1, gi)
    eq(1, ei)
  end)

  it("returns nil when no entry is on that page", function()
    eq(nil, (glossary.find(t, "other#x")))
  end)
end)

describe("glossary.reveal", function()
  it("opens the doc and the entry's type and returns the entry's row", function()
    local t = tree()
    local s, row = glossary.reveal(t, glossary.new(), "index#pdf-error", "error()")
    local rows = glossary.rows(t, s)
    eq("error()", glossary.target(rows[row]).name)
    eq(true, s.doc_open)
    eq("", s.filter)
    ok(not group_row(t, rows, "Manual") or not rows[group_row(t, rows, "Manual")].expanded)
  end)

  it("reopens a closed doc row", function()
    local t = tree()
    local closed = glossary.reduce(t, glossary.new(), 1, act "toggle")
    local s, row = glossary.reveal(t, closed, "index#1", "Introduction")
    eq("Introduction", glossary.target(glossary.rows(t, s)[row]).name)
  end)

  it("clears a filter that hides the entry and keeps one that does not", function()
    local t = tree()
    local hide = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "table" }))
    local s, row = glossary.reveal(t, hide, "index#pdf-assert", "assert()")
    eq("", s.filter)
    eq("assert()", glossary.target(glossary.rows(t, s)[row]).name)
    local keep = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "ass" }))
    local s2, row2 = glossary.reveal(t, keep, "index#pdf-assert", "assert()")
    eq("ass", s2.filter)
    eq("assert()", glossary.target(glossary.rows(t, s2)[row2]).name)
  end)

  it("answers row 1 for an entry the tree does not have", function()
    local t = tree()
    local _, row = glossary.reveal(t, glossary.new(), "nope#x", "nope")
    eq(1, row)
  end)

  it("does not change the state it was given", function()
    local t = tree()
    local s = glossary.new()
    local before = vim.deepcopy(s)
    glossary.reveal(t, s, "index#pdf-error", "error()")
    eq(before, s)
  end)
end)

describe("glossary.reduce", function()
  local t = tree()

  it("toggle opens and closes a type, the cursor staying on its row", function()
    local s, c = glossary.reduce(t, glossary.new(), 3, act "toggle")
    eq(3, c)
    eq(6, #glossary.rows(t, s))
    local s2, c2 = glossary.reduce(t, s, 3, act "toggle")
    eq(3, c2)
    eq(3, #glossary.rows(t, s2))
  end)

  it("toggle on the doc row closes the doc, and opens it again", function()
    local s, c = glossary.reduce(t, glossary.new(), 1, act "toggle")
    eq(1, c)
    eq(1, #glossary.rows(t, s))
    local s2 = glossary.reduce(t, s, 1, act "toggle")
    eq(3, #glossary.rows(t, s2))
  end)

  it("expand opens a closed type, then an open type moves to its first entry", function()
    local s, c = glossary.reduce(t, glossary.new(), 2, act "expand")
    eq(2, c)
    eq(5, #glossary.rows(t, s)) -- doc + 2 types + 2 Manual entries
    local s2, c2 = glossary.reduce(t, s, 2, act "expand")
    eq(3, c2)
    eq(5, #glossary.rows(t, s2))
  end)

  it("expand on the open doc row moves to its first child", function()
    local _, c = glossary.reduce(t, glossary.new(), 1, act "expand")
    eq(2, c)
  end)

  it(
    "collapse folds: entry -> its type (cursor on it), open type -> closed, closed type -> doc row, doc -> closed",
    function()
      local open = glossary.reduce(t, glossary.new(), 3, act "toggle") -- Standard Libraries
      local rows = glossary.rows(t, open)
      local er = entry_row(t, rows, "error()")
      local s1, c1 = glossary.reduce(t, open, er, act "collapse")
      eq(3, c1)
      eq(3, #glossary.rows(t, s1))
      -- an open type closes
      local s2, c2 = glossary.reduce(t, open, 3, act "collapse")
      eq(3, c2)
      eq(3, #glossary.rows(t, s2))
      -- a closed type goes to the doc row
      local s3, c3 = glossary.reduce(t, s2, 3, act "collapse")
      eq(1, c3)
      eq(3, #glossary.rows(t, s3))
      -- the doc row closes the doc
      local s4, c4 = glossary.reduce(t, s3, 1, act "collapse")
      eq(1, c4)
      eq(1, #glossary.rows(t, s4))
    end
  )

  it("expand_all opens every type and collapse_all closes them", function()
    local s = glossary.reduce(t, glossary.new(), 1, act "expand_all")
    eq(8, #glossary.rows(t, s))
    local s2 = glossary.reduce(t, s, 1, act "collapse_all")
    eq(3, #glossary.rows(t, s2))
    eq(true, s2.doc_open)
  end)

  it("collapse_all keeps the cursor on a row that still exists", function()
    local s = glossary.reduce(t, glossary.new(), 1, act "expand_all")
    local rows = glossary.rows(t, s)
    local _, c = glossary.reduce(t, s, #rows, act "collapse_all")
    ok(c >= 1 and c <= 3, c)
  end)

  it("filter sets the text and puts the cursor on the first entry", function()
    local s, c = glossary.reduce(t, glossary.new(), 1, act("filter", { text = "e" }))
    eq("e", s.filter)
    local rows = glossary.rows(t, s)
    eq("entry", rows[c].kind)
    -- an empty text clears it
    local s2 = glossary.reduce(t, s, c, act("filter", { text = "" }))
    eq("", s2.filter)
    eq(3, #glossary.rows(t, s2))
  end)

  it("filter with no match leaves the doc row and the cursor on it", function()
    local s, c = glossary.reduce(t, glossary.new(), 3, act("filter", { text = "zzzz" }))
    eq(1, #glossary.rows(t, s))
    eq(1, c)
  end)

  it("next_group / prev_group jump between types and stay at the edges", function()
    local s = glossary.reduce(t, glossary.new(), 1, act "expand_all")
    local rows = glossary.rows(t, s)
    local g1 = group_row(t, rows, "Manual")
    local g2 = group_row(t, rows, "Standard Libraries")
    local _, a = glossary.reduce(t, s, 1, act "next_group")
    eq(g1, a)
    local _, b = glossary.reduce(t, s, g1, act "next_group")
    eq(g2, b)
    local _, c = glossary.reduce(t, s, g1 + 1, act "next_group")
    eq(g2, c)
    local _, d = glossary.reduce(t, s, #rows, act "next_group")
    eq(#rows, d) -- no later type: stay
    local _, e = glossary.reduce(t, s, g2, act "prev_group")
    eq(g1, e)
    local _, f = glossary.reduce(t, s, g2 + 1, act "prev_group")
    eq(g2, f)
    local _, g = glossary.reduce(t, s, g1, act "prev_group")
    eq(g1, g) -- no earlier type: stay
  end)

  it("clamps a cursor past the end", function()
    local s, c = glossary.reduce(t, glossary.new(), 99, act "toggle")
    ok(c >= 1 and c <= #glossary.rows(t, s), c)
  end)

  it("never mutates the state or the tree it is given", function()
    local tr = tree()
    local snapshot = vim.deepcopy(tr)
    local s = glossary.new()
    local before = vim.deepcopy(s)
    for _, a in ipairs {
      act "toggle",
      act "expand",
      act "collapse",
      act "expand_all",
      act "collapse_all",
      act("filter", { text = "e" }),
      act "next_group",
      act "prev_group",
    } do
      glossary.reduce(tr, s, 2, a)
      eq(before, s, a.type)
    end
    eq(snapshot, tr)
    -- and the result is a new table
    local s2 = glossary.reduce(tr, s, 2, act "toggle")
    ok(s2 ~= s)
  end)
end)
