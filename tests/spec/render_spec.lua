local model = require "devdocs.ui.model"
local render = require "devdocs.ui.render"

local function doc(slug, version, name, size, mtime, release)
  return {
    slug = slug,
    version = version or "",
    name = name or slug,
    db_size = size or 1000,
    mtime = mtime or 10,
    release = release or "",
    type = "x",
  }
end

local DOCS = {
  doc("css", "", "CSS", 15878611),
  doc("python~3.12", "3.12", "Python", 18129117, 10, "3.12.9"),
  doc("python~3.9", "3.9", "Python", 15447502, 10, "3.9.21"),
  doc("rust", "", "Rust", 70119547, 20),
  doc("angular", "", "Angular", 8e6, 1780544785, "22.2.1"),
}

local function state(width, height, extra)
  return model.new(vim.tbl_extend("force", {
    docs = DOCS,
    installed = {
      css = { mtime = 10, name = "CSS", page_count = 1028, installed_at = 0 },
      rust = { mtime = 5, name = "Rust" },
    },
    jobs = { ["python~3.12"] = { slug = "python~3.12", stage = "convert", progress = 0.5 } },
    release_dates = {
      css = { date = "2026-06-03", exact = true },
      ["python~3.12"] = { date = "2025-10-07", exact = false },
    },
    width = width,
    height = height,
  }, extra or {}))
end

local DATE = "%d%d%d%d%-%d%d%-%d%d"

--- Display column (0-based) where `pattern` starts in `line`, or nil. A
--- date's column includes its leading ≈.
local function dcol(line, pattern, plain)
  local b = line:find(pattern, 1, plain)
  if not b then
    return nil
  end
  if pattern == DATE and line:sub(b - #"≈", b - 1) == "≈" then
    b = b - #"≈"
  end
  return vim.fn.strdisplaywidth(line:sub(1, b - 1))
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

  it("labels versions: the rolling slug shows its release as (current)", function()
    eq("3.12", render.version { kind = "doc", doc = DOCS[2] })
    eq("22.2.1 (current)", render.version { kind = "doc", doc = DOCS[5] })
    eq("current", render.version { kind = "doc", doc = DOCS[1] })
    eq("1.2.3 (current)", render.version { kind = "doc", doc = DOCS[1], meta = { release = "1.2.3" } })
    local rows = model.rows(state(100, 20))
    eq("22.2.1 (current)", render.version(rows[6]), "lang row: the current version")
    eq("3.12", render.version(rows[3]), "lang row without installs: the newest")
    local two = model.rows(state(100, 20, {
      installed = { ["python~3.12"] = { mtime = 10 }, ["python~3.9"] = { mtime = 10 } },
      jobs = {},
    }))
    eq("2 installed", render.version(two[2]))
    local one = model.rows(state(100, 20, { installed = { ["python~3.9"] = { mtime = 10 } }, jobs = {} }))
    eq("3.9", render.version(one[2]), "one install: that version")
  end)

  it("dates: exact release, approximate, manifest mtime fallback, nothing", function()
    local s = state(100, 20)
    local rows = model.rows(s)
    eq("2026-06-03", render.released(s, rows[2]))
    eq("≈2025-10-07", render.released(s, rows[3]), "lang row: its target's date")
    eq("≈1970-01-01", render.released(s, rows[4]))
    eq("", render.released(s, { kind = "doc", slug = "x", doc = { mtime = 0 } }))
  end)

  it("renders a title, key hints, a column header and aligned rows", function()
    local r = render.render(state(100, 20))
    eq(4, render.HEADER_LINES)
    ok(r.lines[1]:find("DevDocs  2 installed · 2 available · 1 outdated · 1 installing", 1, true), r.lines[1])
    ok(r.lines[1]:find("sort: name", 1, true))
    for _, title in ipairs { "Name", "Version", "Size", "Released", "Pages", "Notes" } do
      ok(r.lines[3]:find(title, 1, true), ("header lacks %s: %q"):format(title, r.lines[3]))
    end
    ok(vim.tbl_contains(
      vim.tbl_map(function(sp)
        return sp.row .. sp.hl
      end, r.spans),
      "3DevDocsHeader"
    ))
    eq(100, vim.fn.strdisplaywidth(r.lines[4]))
    eq("▾ Installed (3)", vim.trim(r.lines[5]))
    ok(r.lines[6]:find("✓   CSS", 1, true), r.lines[6])
    ok(r.lines[6]:find("15.9 MB", 1, true))
    ok(r.lines[6]:find("1028", 1, true))
    ok(r.lines[6]:find("2026-06-03", 1, true))
    ok(r.lines[7]:find("↓ ▸ Python", 1, true), r.lines[7])
    ok(r.lines[7]:find("convert  50% █████░░░░░", 1, true), r.lines[7])
    ok(r.lines[8]:find("↑   Rust", 1, true))
    ok(r.lines[8]:find("update available", 1, true))
    eq("▾ Available (1)", vim.trim(r.lines[9]))
    ok(r.lines[10]:find("·   Angular", 1, true))
    ok(r.lines[10]:find("22.2.1 (current)", 1, true), r.lines[10])
    for _, l in ipairs(r.lines) do
      ok(vim.fn.strdisplaywidth(l) <= 100, ("line too wide: %q"):format(l))
    end
    -- every column starts at the same display column as its title
    local SIZE = "%d+%.?%d* [kMG]B"
    local released = dcol(r.lines[3], "Released", true)
    eq(released, render.columns(100).at.released)
    for _, n in ipairs { 6, 7, 8, 10 } do
      eq(released, dcol(r.lines[n], DATE), ("date misaligned on %q"):format(r.lines[n]))
      eq(dcol(r.lines[3], "Size", true), dcol(r.lines[n], SIZE), ("size misaligned on %q"):format(r.lines[n]))
    end
    eq(dcol(r.lines[3], "Pages", true), dcol(r.lines[6], "1028", true))
    -- regions cover language/version rows only and point at row indices
    eq(
      { 6, 7, 8, 10 },
      vim.tbl_map(function(reg)
        return reg.row
      end, r.regions)
    )
    eq(
      { 2, 3, 4, 6 },
      vim.tbl_map(function(reg)
        return reg.id
      end, r.regions)
    )
  end)

  it("indents expanded versions under their language, still aligned", function()
    local s = model.reduce(state(100, 20), { type = "goto", row = 3 })
    s = model.reduce(s, { type = "toggle_expand" })
    local r = render.render(s)
    ok(r.lines[7]:find("▾ Python", 1, true), r.lines[7])
    ok(r.lines[8]:find("├ python~3.12", 1, true), r.lines[8])
    ok(r.lines[9]:find("└ python~3.9", 1, true), r.lines[9])
    ok(r.lines[9]:find("3.9", 1, true))
    local released = dcol(r.lines[3], "Released", true)
    for n = 6, #r.lines do
      if r.lines[n]:find(DATE) then
        eq(released, dcol(r.lines[n], DATE), ("date misaligned on %q"):format(r.lines[n]))
      end
    end
  end)

  it("shows marks: ● on marked versions, ◐ on partly marked languages", function()
    local s = state(100, 20, {
      installed = { css = { mtime = 10 }, ["python~3.12"] = { mtime = 10 }, ["python~3.9"] = { mtime = 10 } },
      jobs = {},
      marked = { css = true, ["python~3.9"] = true },
    })
    local r = render.render(s)
    ok(vim.startswith(r.lines[6], "● ✓   CSS"), r.lines[6])
    ok(vim.startswith(r.lines[7], "◐ ✓ ▸ Python"), r.lines[7])
    ok(vim.startswith(r.lines[9], "  ·   Angular"), r.lines[9])
    s.marked["python~3.12"] = true
    ok(vim.startswith(render.render(s).lines[7], "● "))
    eq(
      dcol(render.render(s).lines[3], "Released", true),
      dcol(render.render(s).lines[7], DATE),
      "marks do not shift the columns"
    )
  end)

  it("emits only the visible window of rows and reports the cursor line", function()
    local s = state(120, 2)
    s = model.reduce(s, { type = "bottom" })
    local r = render.render(s)
    eq(4 + 2, #r.lines)
    ok(r.lines[6]:find("Angular", 1, true))
    eq(6, render.cursor_line(s))
  end)

  it("shows filter, loading and error states", function()
    local s = model.reduce(state(100, 10), { type = "filter", text = "zzz" })
    local r = render.render(s)
    ok(r.lines[1]:find("filter: zzz", 1, true))
    ok(r.lines[5]:find('nothing matches "zzz"', 1, true), r.lines[5])
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
    eq("3 versions", render.note { kind = "lang", status = "available", children = { {}, {}, {} } })
    eq("", render.note { kind = "lang", status = "available", children = { {} } })
    eq("", render.note { kind = "lang", status = "available", expanded = true, children = { {}, {} } })
    eq("", render.note { kind = "doc", status = "installed" })
    eq("2 versions", render.note { kind = "lang", status = "installed", installed_count = 1, children = { {}, {} } })
    eq("", render.note { kind = "lang", status = "installed", installed_count = 2, children = { {}, {} } })
    eq("disabled (e enables)", render.note { status = "disabled" })
    eq("failed: boom", render.note { status = "error", job = { err = "boom" } })
    eq("queued  retrying", render.note { status = "installing", job = { stage = "queued", err = "retrying" } })
    -- a language row reports the version that carries its status
    eq(
      "failed: boom",
      render.note {
        kind = "lang",
        status = "error",
        children = { { status = "installed" }, { status = "error", job = { err = "boom" } } },
      }
    )
  end)
end)
