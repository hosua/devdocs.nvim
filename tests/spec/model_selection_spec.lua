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

local function index_of(state, slug)
  for i, r in ipairs(model.rows(state)) do
    if r.kind == "doc" and r.slug == slug then
      return i
    end
  end
  error("no row for " .. slug)
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

  it("mark on a row that is not installed only moves", function()
    local s = fresh()
    local i = index_of(s, "rust")
    s = model.reduce(s, { type = "goto", row = i })
    s = model.reduce(s, { type = "mark" })
    eq({}, s.marked or {})
  end)

  it("does not mutate the previous state", function()
    local s0 = model.reduce(fresh(), { type = "goto", row = index_of(fresh(), "css") })
    local s1 = model.reduce(s0, { type = "mark" })
    eq(nil, (s0.marked or {}).css)
    eq(true, s1.marked.css)
  end)

  it("mark_range marks every installed row between two row indexes", function()
    local s = fresh()
    local rows = model.rows(s)
    s = model.reduce(s, { type = "mark_range", from = 1, to = #rows })
    eq({ css = true, ["python~3.12"] = true, ["python~3.9"] = true }, s.marked)
    -- again: everything in range already marked -> unmarks it
    s = model.reduce(s, { type = "mark_range", from = #rows, to = 1 })
    eq({}, s.marked)
  end)

  it("unmark_all clears every mark", function()
    local s = model.reduce(fresh(), { type = "mark_range", from = 1, to = 99 })
    s = model.reduce(s, { type = "unmark_all" })
    eq({}, s.marked)
  end)

  it("marked_cleanup and data drop marks for slugs no longer installed", function()
    local s = model.reduce(fresh(), { type = "mark_range", from = 1, to = 99 })
    local installed = vim.deepcopy(s.installed)
    installed.css = nil
    s = model.reduce(s, { type = "data", data = { installed = installed } })
    eq({ ["python~3.12"] = true, ["python~3.9"] = true }, s.marked)
    s.installed["python~3.9"] = nil
    s = model.reduce(s, { type = "marked_cleanup" })
    eq({ ["python~3.12"] = true }, s.marked)
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
