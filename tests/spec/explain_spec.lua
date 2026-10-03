local explain = require "devdocs.explain"
local float = require "devdocs.ui.float"

local function msg(target)
  return { explain.message(target) }
end

describe("explain.message", function()
  it("describes literals, with the subject range", function()
    eq(
      { '"DevDocs" is a string literal: nothing to document.', 0, 9 },
      msg { class = "trivial", kind = "string", word = '"DevDocs"' }
    )
    eq(
      { "42 is a number literal: nothing to document.", 0, 2 },
      msg { class = "trivial", kind = "number", word = "42" }
    )
    eq(
      { "true is a boolean literal: nothing to document.", 0, 4 },
      msg { class = "builtin", kind = "boolean", word = "true" }
    )
    eq({ "nil is a null literal: nothing to document.", 0, 3 }, msg { class = "builtin", kind = "nil", word = "nil" })
    eq({ "== is an operator: nothing to document.", 0, 2 }, msg { class = "trivial", kind = "operator", word = "==" })
    eq({ "; is punctuation: nothing to document.", 0, 1 }, msg { class = "trivial", kind = "punctuation", word = ";" })
  end)

  it("has no subject for a comment or whitespace", function()
    eq({ "This is a comment: nothing to document." }, msg { class = "trivial", kind = "comment", word = "" })
    eq({ "Nothing under the cursor to look up." }, msg { class = "trivial", kind = "whitespace", word = "" })
  end)

  it("describes names declared in the buffer", function()
    eq(
      { "count is a local variable (declared on line 12): no documentation.", 0, 5 },
      msg { class = "variable", kind = "local", word = "count", decl_line = 12 }
    )
    eq(
      { "arg is a parameter (declared on line 3): no documentation.", 0, 3 },
      msg { class = "variable", kind = "parameter", word = "arg", decl_line = 3 }
    )
    eq({ "x is a field: no documentation.", 0, 1 }, msg { class = "variable", kind = "field", word = "x" })
    eq(
      { "helper is a function (declared on line 3): no documentation.", 0, 6 },
      msg { class = "unknown", kind = "function", word = "helper", decl_line = 3 }
    )
    eq({ "count is a variable: no documentation.", 0, 5 }, msg { class = "variable", word = "count" })
  end)

  it("has nothing to say for everything else", function()
    eq({}, msg { class = "keyword", word = "return" })
    eq({}, msg { class = "builtin", word = "print" })
    eq({}, msg { class = "unknown", word = "foo" })
    eq({}, msg { class = "trivial", kind = "string", word = "" })
  end)
end)

describe("explain.subject", function()
  it("keeps short single-line text", function()
    eq("abc", explain.subject "abc")
    eq(("x"):rep(40), explain.subject(("x"):rep(40)))
  end)

  it("cuts long or multi-line text with an ellipsis", function()
    eq(("x"):rep(39) .. "…", explain.subject(("x"):rep(41)))
    eq("[[a…", explain.subject "[[a\nb]]")
    local long = '"' .. ("é"):rep(58) .. '"' -- 60 characters, more bytes
    local cut = explain.subject(long)
    eq(40, vim.fn.strchars(cut))
    eq("…", vim.fn.strcharpart(cut, 39))
  end)
end)

describe("explain.show", function()
  local function windows()
    return #vim.api.nvim_list_wins()
  end

  --- A lua buffer in the current window; closes any float on exit.
  local function with_source(fn)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 42" })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "lua"
    local src_win = vim.api.nvim_get_current_win()
    local before = windows()
    local ok, err = pcall(fn, buf, src_win, before)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= src_win and vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    require("devdocs.config").resolve()
    if not ok then
      error(err, 0)
    end
  end

  it("shows nothing for a target with no message", function()
    with_source(function(_, _, before)
      eq(nil, explain.show { class = "keyword", word = "return" })
      eq(before, windows())
    end)
  end)

  it("opens a non-focusable float with the subject highlighted", function()
    with_source(function(buf, src_win)
      local win = explain.show { class = "trivial", kind = "number", word = "42" }
      ok(win and vim.api.nvim_win_is_valid(win))
      local cfg = vim.api.nvim_win_get_config(win)
      eq(false, cfg.focusable)
      ok(cfg.relative ~= "")
      eq(src_win, vim.api.nvim_get_current_win())
      local fbuf = vim.api.nvim_win_get_buf(win)
      eq({ "42 is a number literal: nothing to document." }, vim.api.nvim_buf_get_lines(fbuf, 0, -1, false))
      ok(vim.wo[win].winhighlight:find("NormalFloat:DevDocsNote", 1, true))
      local marks = vim.api.nvim_buf_get_extmarks(fbuf, float.NOTE_NS, 0, -1, { details = true })
      eq(1, #marks)
      eq(0, marks[1][3])
      eq(2, marks[1][4].end_col)
      eq("DevDocsNoteSubject", marks[1][4].hl_group)
      eq("NormalFloat", vim.api.nvim_get_hl(0, { name = "DevDocsNote" }).link)
      eq("Identifier", vim.api.nvim_get_hl(0, { name = "DevDocsNoteSubject" }).link)
      eq(buf, vim.api.nvim_win_get_buf(src_win))
    end)
  end)

  it("closes when the cursor moves", function()
    with_source(function(buf)
      local win = explain.show { class = "trivial", kind = "number", word = "42" }
      ok(win and vim.api.nvim_win_is_valid(win))
      vim.wait(100, function() -- open_floating_preview registers its close_events on the next loop turn
        return false
      end)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
      vim.wait(500, function() -- the close itself is vim.schedule'd
        return not vim.api.nvim_win_is_valid(win)
      end)
      eq(false, vim.api.nvim_win_is_valid(win))
    end)
  end)

  it("is replaced by a second note", function()
    with_source(function(_, _, before)
      local first = explain.show { class = "trivial", kind = "number", word = "42" }
      local second = explain.show { class = "trivial", kind = "operator", word = "==" }
      ok(second and vim.api.nvim_win_is_valid(second))
      eq(false, vim.api.nvim_win_is_valid(first))
      eq(before + 1, windows())
    end)
  end)
end)
