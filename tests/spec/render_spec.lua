local model = require "devdocs.ui.model"
local render = require "devdocs.ui.render"

local function doc(slug, version, name, size, mtime)
  return {
    slug = slug,
    version = version or "",
    name = name or slug,
    db_size = size or 1000,
    mtime = mtime or 10,
    type = "x",
  }
end

local DOCS = {
  doc("css", "", "CSS", 15878611),
  doc("python~3.12", "3.12", "Python", 18129117),
  doc("python~3.9", "3.9", "Python", 15447502),
  doc("rust", "", "Rust", 70119547, 20),
}

local function state(width, height)
  return model.new {
    docs = DOCS,
    installed = {
      css = { mtime = 10, name = "CSS", page_count = 1028, installed_at = 0 },
      rust = { mtime = 5, name = "Rust" },
    },
    jobs = { ["python~3.12"] = { slug = "python~3.12", stage = "convert", progress = 0.5 } },
    width = width,
    height = height,
  }
end

describe("list render", function()
  it("formats sizes and bars", function()
    eq("", render.size(nil))
    eq("958 kB", render.size(958336))
    eq("18.1 MB", render.size(18129117))
    eq("2.3 GB", render.size(2.3e9))
    eq("█████░░░░░", render.bar(0.5))
    eq("░░░░░░░░░░", render.bar(0))
    eq("██████████", render.bar(1.2))
  end)

  it("pads and truncates cells by display width", function()
    eq("ab  ", render.cell("ab", 4))
    eq("abc…", render.cell("abcdef", 4))
    eq("日本…", render.cell("日本語テキスト", 5))
  end)

  it("renders a fixed header, group rows and doc rows at 80 columns", function()
    local r = render.render(state(80, 20))
    eq(3, render.HEADER_LINES)
    ok(r.lines[1]:find("DevDocs  1 installed · 1 available · 1 outdated · 1 installing", 1, true), r.lines[1])
    ok(r.lines[1]:find("sort: name", 1, true))
    eq(80, vim.fn.strdisplaywidth(r.lines[3]))
    eq("▾ Installing (1)", vim.trim(r.lines[4]))
    ok(r.lines[5]:find("↓ Python", 1, true), r.lines[5])
    ok(
      r.lines[5]:find("convert  50%% █████░░░░░", 1, false)
        or r.lines[5]:find("convert  50% █████░░░░░", 1, true),
      r.lines[5]
    )
    eq("▾ Outdated (1)", vim.trim(r.lines[6]))
    ok(r.lines[7]:find("↑ Rust", 1, true))
    ok(r.lines[7]:find("update available", 1, true))
    eq("▾ Installed (1)", vim.trim(r.lines[8]))
    ok(r.lines[9]:find("✓ CSS", 1, true))
    ok(r.lines[9]:find("1028 pages", 1, true))
    eq("▾ Available (1)", vim.trim(r.lines[10]))
    ok(r.lines[11]:find("· Python", 1, true))
    ok(r.lines[11]:find("3.9", 1, true))
    for _, l in ipairs(r.lines) do
      ok(vim.fn.strdisplaywidth(l) <= 80, ("line too wide: %q"):format(l))
    end
    -- regions cover doc rows only and point at row indices
    eq(
      { 5, 7, 9, 11 },
      vim.tbl_map(function(reg)
        return reg.row
      end, r.regions)
    )
    eq(
      { 2, 4, 6, 8 },
      vim.tbl_map(function(reg)
        return reg.id
      end, r.regions)
    )
  end)

  it("emits only the visible window of rows and reports the cursor line", function()
    local s = state(120, 2)
    s = model.reduce(s, { type = "bottom" })
    local r = render.render(s)
    eq(3 + 2, #r.lines)
    ok(r.lines[5]:find("Python", 1, true))
    eq(5, render.cursor_line(s))
  end)

  it("shows filter, loading and error states", function()
    local s = model.reduce(state(100, 10), { type = "filter", text = "zzz" })
    local r = render.render(s)
    ok(r.lines[1]:find("filter: zzz", 1, true))
    ok(r.lines[4]:find('nothing matches "zzz"', 1, true), r.lines[4])
    local loading = render.render(model.new { loading = true, width = 80, height = 5 })
    ok(loading.lines[1]:find("loading", 1, true))
    local err = render.render(model.new { error = "could not fetch", width = 80, height = 5 })
    ok(err.lines[1]:find("could not fetch", 1, true))
    ok(vim.tbl_contains(
      vim.tbl_map(function(sp)
        return sp.hl
      end, err.spans),
      "DevDocsError"
    ))
  end)

  it("notes describe what each status needs", function()
    eq("+3 versions (Tab)", render.note { status = "available", versions = 4 })
    eq("", render.note { status = "available", versions = 1 })
    eq("disabled (e enables)", render.note { status = "disabled" })
    eq("failed: boom", render.note { status = "error", job = { err = "boom" } })
    eq("queued  retrying", render.note { status = "installing", job = { stage = "queued", err = "retrying" } })
  end)
end)
