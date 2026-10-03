-- Reducer actions for bulk selection: mark, mark_range, unmark_all,
-- marked_cleanup, and the mark pruning done by "data". Rows are located by
-- slug, not by index, so these hold whatever grouping model.rows emits.
local model = require "devdocs.ui.model"

local function doc(slug, version, name)
  return { slug = slug, version = version or "", name = name or slug, db_size = 1000, mtime = 10, type = "x" }
end

local DOCS = {
  doc("css", "", "CSS"),
  doc("python~3.12", "3.12", "Python"),
  doc("python~3.9", "3.9", "Python"),
  doc("rust", "", "Rust"),
}

-- a version row, or the language row of a single-version language
local function index_of(state, slug)
  for i, r in ipairs(model.rows(state)) do
    if r.kind == "doc" and r.slug == slug then
      return i
    end
    if r.kind == "lang" and #r.children == 1 and r.children[1].slug == slug then
      return i
    end
  end
  error("no row for " .. slug)
end

local function lang_index(state, base)
  for i, r in ipairs(model.rows(state)) do
    if r.kind == "lang" and r.base == base then
      return i
    end
  end
  error("no language row for " .. base)
end

local function fresh()
  return model.new {
    docs = DOCS,
    installed = { css = { mtime = 10 }, ["python~3.12"] = { mtime = 10 }, ["python~3.9"] = { mtime = 10 } },
    height = 20,
    width = 80,
  }
end

describe("list model selection", function()
  it("mark toggles the installed row under the cursor and moves down one row", function()
    local s = fresh()
    local i = index_of(s, "css")
    s = model.reduce(s, { type = "goto", row = i })
    s = model.reduce(s, { type = "mark" })
    eq({ css = true }, s.marked)
    ok(s.cursor > i, "cursor did not advance")
    s = model.reduce(s, { type = "goto", row = i })
    s = model.reduce(s, { type = "mark" })
    eq({}, s.marked)
  end)

  it("mark on a language row marks every installed version, again unmarks them", function()
    local s = fresh()
    s = model.reduce(s, { type = "goto", row = lang_index(s, "python") })
    s = model.reduce(s, { type = "mark" })
    eq({ ["python~3.12"] = true, ["python~3.9"] = true }, s.marked)
    s = model.reduce(s, { type = "goto", row = lang_index(s, "python") })
    s = model.reduce(s, { type = "mark" })
    eq({}, s.marked)
  end)

  it("mark on a row that is not installed marks it (to install) and moves down", function()
    local s = fresh()
    local i = index_of(s, "rust")
    s = model.reduce(s, { type = "goto", row = i })
    s = model.reduce(s, { type = "mark" })
    eq({ rust = true }, s.marked)
  end)

  it("mark on an installing row only moves", function()
    local s = fresh()
    s = model.reduce(s, { type = "data", data = { jobs = { rust = { slug = "rust", stage = "download" } } } })
    s = model.reduce(s, { type = "goto", row = index_of(s, "rust") })
    s = model.reduce(s, { type = "mark" })
    eq({}, s.marked)
  end)

  it("a not-installed mark survives data refreshes; unmark drops given slugs", function()
    local s = model.reduce(fresh(), { type = "goto", row = index_of(fresh(), "rust") })
    s = model.reduce(s, { type = "mark" })
    s = model.reduce(s, { type = "data", data = { installed = vim.deepcopy(s.installed) } })
    eq({ rust = true }, s.marked)
    s = model.reduce(s, { type = "marked_cleanup" })
    eq({ rust = true }, s.marked)
    s = model.reduce(s, { type = "unmark", slugs = { "rust" } })
    eq({}, s.marked)
    s = model.reduce(s, { type = "mark_slugs", slugs = { "rust", "css" } })
    eq({ rust = true, css = true }, s.marked)
  end)

  it("data drops marks of slugs that left both the docs list and the installed set", function()
    local s = model.reduce(fresh(), { type = "goto", row = index_of(fresh(), "rust") })
    s = model.reduce(s, { type = "mark" })
    local docs = vim.tbl_filter(function(d)
      return d.slug ~= "rust"
    end, DOCS)
    s = model.reduce(s, { type = "data", data = { docs = docs } })
    eq({}, s.marked)
  end)

  it("mark on a language under a filter marks only the versions the filter shows", function()
    local s = model.reduce(fresh(), { type = "filter", text = "3.12" })
    s = model.reduce(s, { type = "goto", row = lang_index(s, "python") })
    s = model.reduce(s, { type = "mark" })
    eq({ ["python~3.12"] = true }, s.marked)
  end)

  it("keeps marks across filter changes", function()
    local s = model.reduce(fresh(), { type = "goto", row = index_of(fresh(), "css") })
    s = model.reduce(s, { type = "mark" })
    s = model.reduce(s, { type = "filter", text = "python" })
    eq({ css = true }, s.marked)
    eq({ css = true }, model.reduce(s, { type = "filter", text = "" }).marked)
  end)

  it("does not mutate the previous state", function()
    local s0 = model.reduce(fresh(), { type = "goto", row = index_of(fresh(), "css") })
    local s1 = model.reduce(s0, { type = "mark" })
    eq(nil, (s0.marked or {}).css)
    eq(true, s1.marked.css)
  end)

  it("mark_range marks every row between two row indexes, installed or not", function()
    local s = fresh()
    local rows = model.rows(s)
    s = model.reduce(s, { type = "mark_range", from = 1, to = #rows })
    eq({ css = true, ["python~3.12"] = true, ["python~3.9"] = true, rust = true }, s.marked)
    -- again: everything in range already marked -> unmarks it
    s = model.reduce(s, { type = "mark_range", from = #rows, to = 1 })
    eq({}, s.marked)
  end)

  it("unmark_all clears every mark", function()
    local s = model.reduce(fresh(), { type = "mark_range", from = 1, to = 99 })
    s = model.reduce(s, { type = "unmark_all" })
    eq({}, s.marked)
  end)

  it("marked_cleanup and data keep marks of docs uninstalled elsewhere (now: install them)", function()
    local s = model.reduce(fresh(), { type = "mark_range", from = 1, to = 99 })
    local installed = vim.deepcopy(s.installed)
    installed.css = nil
    s = model.reduce(s, { type = "data", data = { installed = installed } })
    eq({ css = true, ["python~3.12"] = true, ["python~3.9"] = true, rust = true }, s.marked)
    s.installed["python~3.9"] = nil
    s.docs = { DOCS[1] }
    s = model.reduce(s, { type = "marked_cleanup" })
    eq({ css = true, ["python~3.12"] = true }, s.marked)
  end)

  it("handles a state without a marked table", function()
    local s = fresh()
    s.marked = nil
    eq({}, model.reduce(s, { type = "unmark_all" }).marked)
    eq({}, model.reduce(s, { type = "marked_cleanup" }).marked)
    s = model.reduce(s, { type = "data", data = {} })
    eq(nil, s.marked)
  end)
end)
