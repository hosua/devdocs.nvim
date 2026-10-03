local classify = require "devdocs.classify"

--- A scratch buffer with `lines` and filetype `ft`, shown in the current window.
local function buffer(ft, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = ft
  return buf
end

--- Class of the first `needle` on 1-based line `lnum` (cursor placed on it).
local function at(buf, lnum, needle, nth)
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  local col = 0
  for _ = 1, nth or 1 do
    col = assert(line:find(needle, col + 1, true), needle)
  end
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
  return classify.cursor(buf)
end

--- Full target (class, kind, word, decl_line) of the nth `needle` on 1-based line `lnum`.
local function target(buf, lnum, needle, nth)
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  local col = 0
  for _ = 1, nth or 1 do
    col = assert(line:find(needle, col + 1, true), needle)
  end
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
  return classify.target(buf)
end

--- Target at a 0-based column of 1-based line `lnum`.
local function target_col(buf, lnum, col)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { lnum, col })
  return classify.target(buf)
end

--- Assert the fields of a target (`want` lists only the fields that matter).
local function expect(want, got, label)
  for k, v in pairs(want) do
    eq(v, got[k], ("%s: field %s of %s"):format(label or "target", k, vim.inspect(got)))
  end
end

--- Swap vim.lsp.semantic_tokens.get_at_pos for the duration of fn.
local function with_tokens(tokens, fn)
  local orig = vim.lsp.semantic_tokens.get_at_pos
  vim.lsp.semantic_tokens.get_at_pos = function()
    if type(tokens) == "function" then
      return tokens()
    end
    return tokens
  end
  local ok, err = pcall(fn)
  vim.lsp.semantic_tokens.get_at_pos = orig
  if not ok then
    error(err, 0)
  end
end

local LUA = {
  "local function f(param)",
  "  local count = param + 1",
  "  print(count, string.format('x'), self, vim.api, f(1), nil, true)",
  "  return count and not param",
  "end",
  "local t = { k = 1 }",
  "t.field = 1",
  "",
  "      ",
}

describe("classify.cursor (treesitter, lua)", function()
  local buf = buffer("lua", LUA)

  it("calls language keywords keywords", function()
    eq("keyword", at(buf, 1, "local"))
    eq("keyword", at(buf, 1, "function"))
    eq("keyword", at(buf, 4, "return"))
    eq("keyword", at(buf, 4, "and"))
    eq("keyword", at(buf, 4, "not"))
  end)

  it("calls builtins builtins", function()
    eq("builtin", at(buf, 3, "print"))
    eq("builtin", at(buf, 3, "string"))
    eq("builtin", at(buf, 3, "self"))
    eq("builtin", at(buf, 3, "nil"))
    eq("builtin", at(buf, 3, "true"))
  end)

  it("calls locals and parameters variables", function()
    eq("variable", at(buf, 2, "count"))
    eq("variable", at(buf, 1, "param"))
    eq("variable", at(buf, 2, "param"))
    eq("variable", at(buf, 3, "count"))
  end)

  it("sends a table key to the docs first (the locals query does not define it)", function()
    eq("symbol", at(buf, 6, "k")) -- could be a metamethod like __index
  end)

  it("is unsure about calls", function()
    eq("unknown", at(buf, 3, "format"))
    eq("unknown", at(buf, 3, "f(1)"))
  end)

  it("sends a variable that is part of a chain to the docs first", function()
    eq("symbol", at(buf, 7, "field"))
    eq("symbol", at(buf, 7, "t"))
    eq("symbol", at(buf, 3, "api"))
    eq("symbol", at(buf, 3, "vim"))
  end)

  it("is trivial when the cursor is on whitespace or punctuation (hover would not see the next word)", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq("trivial", classify.cursor(buf)) -- "  local": indentation, not `local`
    vim.api.nvim_win_set_cursor(0, { 2, 7 })
    eq("trivial", classify.cursor(buf)) -- the space before `count`
    local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
    vim.api.nvim_win_set_cursor(0, { 2, line:find("=", 1, true) - 1 })
    eq("trivial", classify.cursor(buf)) -- on `=`
    expect({ class = "trivial", kind = "whitespace", word = "" }, target_col(buf, 2, 0))
    expect({ class = "trivial", kind = "whitespace", word = "" }, target_col(buf, 2, 7))
    expect({ class = "trivial", kind = "operator", word = "=" }, target_col(buf, 2, line:find("=", 1, true) - 1))
  end)

  it("is trivial on empty and blank lines", function()
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    eq("trivial", classify.cursor(buf))
    vim.api.nvim_win_set_cursor(0, { 9, 5 })
    eq("trivial", classify.cursor(buf))
  end)

  it("is trivial after the last word on the line", function()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.cmd "normal! $"
    eq("variable", classify.cursor(buf)) -- on the last char of `param`
    local line = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
    eq("trivial", classify.at(buf, 4, #line + 3))
  end)

  it("is unknown for a buffer that is not in the current window", function()
    local other = vim.api.nvim_create_buf(false, true)
    eq("unknown", classify.cursor(other))
  end)
end)

describe("classify.cursor (treesitter, c)", function()
  local buf = buffer("c", {
    "int main(int argc, char **argv) {",
    "  int total = argc + 1;",
    '  printf("%d", total);',
    "  return sizeof(total);",
    "}",
  })

  it("separates keywords and builtin types from locals", function()
    eq("builtin", at(buf, 1, "int"))
    eq("keyword", at(buf, 4, "return"))
    eq("keyword", at(buf, 4, "sizeof"))
    eq("variable", at(buf, 2, "total"))
    eq("variable", at(buf, 2, "argc"))
    eq("variable", at(buf, 1, "argc"))
    eq("unknown", at(buf, 3, "printf"))
  end)
end)

describe("classify.cursor (treesitter only, names not declared in the buffer)", function()
  it("sends lua library names used as values to the docs first", function()
    local buf = buffer("lua", {
      "local ok = pcall(error, 'x')",
      "local mt = { __index = rawget }",
      "print(arg)",
      "local declared = 1",
      "print(declared)",
    })
    eq("symbol", at(buf, 1, "error"))
    eq("symbol", at(buf, 2, "rawget"))
    eq("symbol", at(buf, 3, "arg"))
    eq("variable", at(buf, 5, "declared"))
    eq("variable", at(buf, 1, "ok"))
  end)

  it("sends C's errno to the docs first", function()
    local buf = buffer("c", {
      "int f(int n) {",
      "  int local_n = n;",
      "  return errno + local_n;",
      "}",
    })
    eq("symbol", at(buf, 3, "errno"))
    eq("variable", at(buf, 3, "local_n"))
    eq("variable", at(buf, 2, "n;"))
  end)

  --- Run fn as if the runtime had no locals.scm (Neovim's own runtime has none
  --- for lua or c; only nvim-treesitter adds them).
  local function without_runtime_locals(fn)
    local orig = vim.treesitter.query.get
    vim.treesitter.query.get = function(lang, name)
      if name == "locals" then
        return nil
      end
      return orig(lang, name)
    end
    local ok, err = pcall(fn)
    vim.treesitter.query.get = orig
    assert(ok, err)
  end

  it("uses the bundled declarations when the runtime has no locals query (lua, c)", function()
    without_runtime_locals(function()
      local buf = buffer("lua", {
        "local count, other = 1, 2",
        "local function helper(param, ...) return param end",
        "for i, v in ipairs({}) do print(i, v) end",
        "for n = 1, 2 do print(n) end",
        "print(count, other, error)",
        "local t = { k = 1 }",
      })
      eq("variable", at(buf, 5, "count"))
      eq("variable", at(buf, 5, "other"))
      eq("variable", at(buf, 2, "param", 2))
      eq("variable", at(buf, 3, "i,", 2))
      eq("variable", at(buf, 4, "n)"))
      eq("symbol", at(buf, 5, "error"))
      eq("symbol", at(buf, 6, "k"))
      local c = buffer("c", {
        "int f(int n, char **argv) {",
        "  int total = n, arr[2];",
        "  int plain;",
        "  return errno + total + plain + argv[0][0] + arr[0];",
        "}",
      })
      eq("variable", at(c, 4, "total"))
      eq("variable", at(c, 4, "plain"))
      eq("variable", at(c, 4, "argv"))
      eq("variable", at(c, 4, "arr"))
      eq("variable", at(c, 2, "n,"))
      eq("symbol", at(c, 4, "errno"))
    end)
  end)

  it("downgrades a treesitter variable to symbol when the language has no locals query at all", function()
    local buf = buffer("lua", { "local count = 1", "print(count)" })
    local saved = classify.LOCALS_FALLBACK.lua
    classify.LOCALS_FALLBACK.lua = nil
    local ok, err = pcall(without_runtime_locals, function()
      eq("symbol", at(buf, 2, "count"))
    end)
    classify.LOCALS_FALLBACK.lua = saved
    assert(ok, err)
  end)

  it("parses every bundled declaration query with the parsers Neovim ships", function()
    for lang, src in pairs(classify.LOCALS_FALLBACK) do
      local ok, err = pcall(vim.treesitter.query.parse, lang, src)
      assert(ok, lang .. ": " .. tostring(err))
    end
  end)

  it("keeps a semantic-token variable even when the buffer does not declare it", function()
    local buf = buffer("lua", { "print(arg)" })
    with_tokens({ { type = "variable", modifiers = {} } }, function()
      eq("variable", at(buf, 1, "arg"))
    end)
  end)
end)

describe("classify.cursor without a parser", function()
  it("is unknown for a filetype treesitter cannot parse", function()
    local buf = buffer("devdocs_no_such_lang", { "local count = 1" })
    eq("unknown", at(buf, 1, "count"))
  end)

  it("is unknown for a buffer with no filetype", function()
    local buf = buffer("", { "foo bar" })
    eq("unknown", at(buf, 1, "bar"))
  end)
end)

describe("classify.cursor (LSP semantic tokens)", function()
  local buf = buffer("lua", LUA)

  it("lets a semantic token win over treesitter", function()
    with_tokens({ { type = "variable", modifiers = {} } }, function()
      eq("variable", at(buf, 3, "f(1)")) -- treesitter alone: unknown (a call)
    end)
    with_tokens({ { type = "function", modifiers = { defaultLibrary = true } } }, function()
      eq("library", at(buf, 2, "count")) -- treesitter alone: variable
    end)
  end)

  it("reads the token types", function()
    for _, case in ipairs {
      { { type = "parameter", modifiers = {} }, "variable" },
      { { type = "variable", modifiers = { readonly = true } }, "variable" },
      { { type = "variable", modifiers = { defaultLibrary = true } }, "library" },
      { { type = "function", modifiers = {} }, "symbol" },
      { { type = "method", modifiers = { declaration = true } }, "symbol" },
      { { type = "class", modifiers = {} }, "symbol" },
      { { type = "keyword", modifiers = {} }, "keyword" },
      { { type = "namespace", modifiers = {} }, "unknown" },
    } do
      with_tokens({ case[1] }, function()
        eq(case[2], at(buf, 2, "count"), vim.inspect(case[1]))
      end)
    end
  end)

  it("prefers a defaultLibrary token when several overlap", function()
    with_tokens(
      { { type = "variable", modifiers = {} }, { type = "variable", modifiers = { defaultLibrary = true } } },
      function()
        eq("library", at(buf, 2, "count"))
      end
    )
  end)

  it("treats a variable in a chain as a symbol, unless it is self's member", function()
    with_tokens({ { type = "property", modifiers = {} } }, function()
      eq("symbol", at(buf, 7, "field"))
      eq("symbol", at(buf, 3, "vim"))
      eq("variable", at(buf, 6, "k"))
    end)
    local b2 = buffer("lua", { "self.count = 1", "this->count = 2" })
    with_tokens({ { type = "property", modifiers = {} } }, function()
      eq("variable", at(b2, 1, "count"))
      eq("variable", at(b2, 2, "count"))
    end)
  end)

  it("falls back to treesitter for tokens that say nothing and for errors", function()
    with_tokens({ { type = "string", modifiers = {} } }, function()
      eq("keyword", at(buf, 1, "local"))
    end)
    with_tokens({}, function()
      eq("variable", at(buf, 2, "count"))
    end)
    with_tokens(function()
      error "no semantic tokens"
    end, function()
      eq("variable", at(buf, 2, "count"))
    end)
  end)
end)

describe("classify.from_captures", function()
  local plain = { qualified = false, chain_head = false }

  it("ranks keyword > builtin > anything else", function()
    eq("keyword", classify.from_captures({ "operator", "keyword.operator" }, plain))
    eq("builtin", classify.from_captures({ "variable", "function.call", "function.builtin" }, plain))
    eq("builtin", classify.from_captures({ "boolean" }, plain))
    eq("builtin", classify.from_captures({ "constant.builtin" }, plain))
  end)

  it("only calls a token a variable when nothing else claims it", function()
    eq("variable", classify.from_captures({ "variable" }, plain))
    eq("variable", classify.from_captures({ "variable", "variable.parameter" }, plain))
    eq("unknown", classify.from_captures({ "variable", "function.call" }, plain))
    eq("unknown", classify.from_captures({ "variable", "module" }, plain))
    eq("unknown", classify.from_captures({ "variable", "constant" }, plain))
    eq("unknown", classify.from_captures({}, plain))
    eq("trivial", classify.from_captures({ "comment", "spell" }, plain))
  end)

  it("calls literals trivial but keeps booleans and builtin constants builtin", function()
    eq("trivial", classify.from_captures({ "string" }, plain))
    eq("trivial", classify.from_captures({ "number" }, plain))
    eq("builtin", classify.from_captures({ "boolean" }, plain))
    eq("builtin", classify.from_captures({ "constant.builtin" }, plain))
  end)

  it("ignores private captures", function()
    eq("variable", classify.from_captures({ "_parent", "variable" }, plain))
  end)

  it("sends qualified members to the docs first", function()
    eq("symbol", classify.from_captures({ "variable", "variable.member" }, { qualified = true }))
    eq("symbol", classify.from_captures({ "variable" }, { qualified = false, chain_head = true }))
    eq("variable", classify.from_captures({ "variable", "property" }, plain))
  end)
end)

describe("classify.word_at", function()
  it("finds the identifier under the cursor", function()
    eq({ 6, 10 }, { classify.word_at("local count = 1", 7) })
    eq({}, { classify.word_at("local count = 1", 5) }) -- the space before `count`
    eq({}, { classify.word_at("local y = count", 9) }) -- the space after `=`
    eq({ 0, 4 }, { classify.word_at("local count = 1", 0) })
    eq({}, { classify.word_at("x = 1;   ", 7) })
    eq({}, { classify.word_at("", 0) })
    eq({}, { classify.word_at("abc", 10) })
  end)

  it("keeps non-ASCII identifiers whole", function()
    eq({ 6, 10 }, { classify.word_at("local café = 1", 7) })
    eq({ 6, 10 }, { classify.word_at("local café = 1", 9) }) -- second byte of `é`
    eq({ 0, 5 }, { classify.word_at("naïve()", 0) })
  end)

  it("says whether the word is qualified or heads a chain", function()
    eq({ qualified = true, chain_head = false }, classify.context("t.field = 1", 2, 6))
    eq({ qualified = false, chain_head = true }, classify.context("vim.api", 0, 2))
    eq({ qualified = false, chain_head = true }, classify.context("std::cout", 0, 2))
    eq({ qualified = true, chain_head = false }, classify.context("p->x", 3, 3))
    eq({ qualified = true, chain_head = false }, classify.context("obj:method()", 4, 9, "lua"))
    eq({ qualified = false, chain_head = true }, classify.context("obj:method()", 0, 2, "lua"))
    eq({ qualified = false, chain_head = false }, classify.context("self.x", 5, 5)) -- self's own member
    eq({ qualified = false, chain_head = false }, classify.context("f(...args)", 5, 8)) -- spread, not a member
    eq({ qualified = false, chain_head = false }, classify.context("a..b", 3, 3)) -- lua concat
    eq({ qualified = false, chain_head = false }, classify.context("{ a: 1 }", 2, 2))
  end)

  it("only treats `:` as member access where it calls a method (lua)", function()
    eq({ qualified = false, chain_head = false }, classify.context("a[lo:hi]", 5, 6, "python")) -- slice
    eq({ qualified = false, chain_head = false }, classify.context("a[lo:hi]", 2, 3, "python"))
    eq({ qualified = false, chain_head = false }, classify.context("c ? x:y", 6, 6, "c")) -- ternary
    eq({ qualified = false, chain_head = false }, classify.context("c ? x:y", 4, 4, "c"))
    eq({ qualified = false, chain_head = false }, classify.context("obj:method()", 4, 9)) -- no language
    eq({ qualified = true, chain_head = false }, classify.context("std::cout", 5, 8, "cpp"))
  end)
end)

local LUA_EXPLAIN = {
  'local name = "DevDocs" -- the plugin name', -- 1
  "local n, yes, none = 42, true, nil", -- 2
  "local function helper(arg)", -- 3
  "  return arg .. name", -- 4
  "end", -- 5
  "helper(0x1F)", -- 6
  "--[[ block", -- 7
  "comment ]]", -- 8
  'vim.cmd("set number")', -- 9
  "M = {}", -- 10
  "print(M, n)", -- 11
}

local C_EXPLAIN = {
  "#include <stdio.h>", -- 1
  "static int helper(int count) {", -- 2
  "  char *p = NULL; /* note */", -- 3
  "  int total = count + 'a';", -- 4
  '  printf("%d\\n", total); // done', -- 5
  "  return total > 0 ? 1 : 0;", -- 6
  "}", -- 7
}

--- Run fn as if the runtime had no locals.scm (the bundled fallback applies).
local function without_locals_query(fn)
  local orig = vim.treesitter.query.get
  vim.treesitter.query.get = function(lang, name)
    if name == "locals" then
      return nil
    end
    return orig(lang, name)
  end
  local ok, err = pcall(fn)
  vim.treesitter.query.get = orig
  assert(ok, err)
end

--- The declaration rows of the plan's lua table.
local function check_lua_declarations(buf)
  expect({ class = "variable", kind = "parameter", word = "arg", decl_line = 3 }, target(buf, 4, "arg"), "arg")
  expect({ class = "variable", kind = "local", word = "name", decl_line = 1 }, target(buf, 4, "name"), "name")
  expect({ class = "unknown", kind = "function", word = "helper", decl_line = 3 }, target(buf, 6, "helper"), "helper")
  expect({ class = "variable", kind = "variable", word = "M", decl_line = 10 }, target(buf, 11, "M"), "M")
end

describe("classify.target (treesitter, lua)", function()
  local buf = buffer("lua", LUA_EXPLAIN)

  it("calls a string literal trivial, with the quotes in the word", function()
    expect({ class = "trivial", kind = "string", word = '"DevDocs"' }, target(buf, 1, 'DevDocs"'))
    expect({ class = "trivial", kind = "string", word = '"DevDocs"' }, target(buf, 1, '"'))
  end)

  it("calls comments trivial (line and block)", function()
    expect({ class = "trivial", kind = "comment", word = "" }, target(buf, 1, "plugin"))
    expect({ class = "trivial", kind = "comment", word = "" }, target(buf, 1, "--"))
    expect({ class = "trivial", kind = "comment", word = "" }, target(buf, 8, "comment"))
  end)

  it("calls numbers trivial and true / nil builtin literals", function()
    expect({ class = "trivial", kind = "number", word = "42" }, target(buf, 2, "42"))
    expect({ class = "trivial", kind = "number", word = "0x1F" }, target(buf, 6, "0x1F"))
    expect({ class = "builtin", kind = "boolean", word = "true" }, target(buf, 2, "true"))
    expect({ class = "builtin", kind = "nil", word = "nil" }, target(buf, 2, "nil"))
  end)

  it("does not call code inside vim.cmd(...) a string literal", function()
    ok(target(buf, 9, "number").class ~= "trivial")
  end)

  it("reads declarations: kind and decl_line", function()
    check_lua_declarations(buf)
  end)

  it("reads declarations from the bundled fallback when the runtime has no locals query", function()
    without_locals_query(function()
      check_lua_declarations(buf)
    end)
  end)

  it("calls a global assigned in the buffer a variable declared on its line", function()
    local b = buffer("lua", { "m = {}", "print(m)" })
    expect({ class = "variable", kind = "variable", word = "m", decl_line = 1 }, target(b, 2, "m"))
  end)

  it("leaves builtins without a literal kind alone", function()
    local t = target(buf, 11, "print")
    eq("builtin", t.class)
    eq(nil, t.kind)
    eq(nil, t.decl_line)
  end)

  it("calls operators and punctuation trivial", function()
    expect({ class = "trivial", kind = "operator", word = ".." }, target(buf, 4, ".."))
    expect({ class = "trivial", kind = "punctuation", word = "(" }, target(buf, 3, "("))
  end)

  it("calls indentation and the space past the end of a line whitespace", function()
    expect({ class = "trivial", kind = "whitespace", word = "" }, target_col(buf, 4, 0))
    -- past the end of "end": nvim_win_set_cursor would clamp, so ask target_at directly
    expect({ class = "trivial", kind = "whitespace", word = "" }, classify.target_at(buf, 4, 3))
  end)

  it("keeps classify.at / classify.cursor returning plain classes", function()
    eq("trivial", at(buf, 1, "DevDocs"))
    eq("variable", at(buf, 4, "arg"))
  end)

  it("does not call a name inside a string capture a literal when its own capture is code", function()
    -- JS `${x}` / Python f"{x}": the highlights query captures the whole
    -- template as @string and the substitution's name as @variable. Simulate
    -- it with lua: a query that also captures call arguments as @string.
    local files = vim.treesitter.query.get_files("lua", "highlights")
    local src = {}
    for _, f in ipairs(files) do
      src[#src + 1] = table.concat(vim.fn.readfile(f), "\n")
    end
    local orig = table.concat(src, "\n")
    vim.treesitter.query.set("lua", "highlights", orig .. "\n(arguments) @string\n")
    local done, err = pcall(function()
      local t = target_col(buf, 11, 9) -- the n of `print(M, n)`
      ok(t.class ~= "trivial", "n in print(M, n): " .. vim.inspect(t))
      expect({ class = "variable", kind = "local", word = "n", decl_line = 2 }, t, "n")
    end)
    vim.treesitter.query.set("lua", "highlights", orig)
    assert(done, err)
  end)

  it("looks up declarations only for names a popup or hover may cover", function()
    local orig = classify.locals_query
    local calls = 0
    classify.locals_query = function(...)
      calls = calls + 1
      return orig(...)
    end
    local done, err = pcall(function()
      eq("builtin", target(buf, 11, "print").class)
      eq("keyword", target(buf, 3, "function").class)
      eq(0, calls, "locals query runs for builtins and keywords")
      eq(3, target(buf, 4, "arg").decl_line)
      ok(calls > 0, "locals query runs for a variable")
    end)
    classify.locals_query = orig
    assert(done, err)
  end)
end)

describe("classify.target (treesitter, c)", function()
  local buf = buffer("c", C_EXPLAIN)

  it("keeps an #include header out of the trivial strings", function()
    ok(target(buf, 1, "stdio").class ~= "trivial")
  end)

  it("reads the # of a preprocessor directive as part of the directive, not an operator", function()
    expect({ class = "keyword", word = "#include" }, target(buf, 1, "#"))
  end)

  it("reads builtin types, keywords and NULL", function()
    local t = target(buf, 2, "int")
    eq("builtin", t.class)
    eq(nil, t.kind)
    expect({ class = "builtin", kind = "nil", word = "NULL" }, target(buf, 3, "NULL"))
    eq("keyword", target(buf, 6, "return").class)
  end)

  it("reads parameters, locals and the function name", function()
    expect({ class = "variable", kind = "parameter", decl_line = 2 }, target(buf, 2, "count"))
    local fn = target(buf, 2, "helper")
    ok(fn.class ~= "trivial")
    eq("function", fn.kind)
    eq(2, fn.decl_line)
    expect({ class = "variable", kind = "local", decl_line = 4 }, target(buf, 4, "total"))
    expect({ class = "variable", kind = "local", decl_line = 4 }, target(buf, 5, "total"))
  end)

  it("calls comments, strings and chars trivial", function()
    expect({ class = "trivial", kind = "comment" }, target(buf, 3, "note"))
    expect({ class = "trivial", kind = "comment" }, target(buf, 5, "done"))
    expect({ class = "trivial", kind = "string", word = "'a'" }, target(buf, 4, "'a'"))
    local lit = C_EXPLAIN[5]:match '"[^"]*"' -- the whole literal, quotes included
    expect({ class = "trivial", kind = "string", word = lit }, target(buf, 5, "%d"))
  end)

  it("calls punctuation, operators and numbers trivial", function()
    expect({ class = "trivial", kind = "punctuation", word = ";" }, target(buf, 3, ";"))
    expect({ class = "trivial", kind = "operator", word = ">" }, target(buf, 6, ">"))
    expect({ class = "trivial", kind = "operator", word = "?" }, target(buf, 6, "?"))
    expect({ class = "trivial", kind = "number", word = "1" }, target(buf, 6, "1"))
  end)

  it("reads declarations from the bundled fallback when the runtime has no locals query", function()
    without_locals_query(function()
      expect({ class = "variable", kind = "parameter", decl_line = 2 }, target(buf, 2, "count"))
      expect({ class = "variable", kind = "local", decl_line = 4 }, target(buf, 5, "total"))
      local fn = target(buf, 2, "helper")
      eq("function", fn.kind)
      eq(2, fn.decl_line)
    end)
  end)
end)

describe("classify.target without a parser", function()
  it("reads LSP semantic tokens (word falls back to the word under the cursor)", function()
    local buf = buffer("devdocs_no_such_lang", { 'x = "hi" -- c' })
    with_tokens({ { type = "string", modifiers = {} } }, function()
      expect({ class = "trivial", kind = "string", word = "hi" }, target(buf, 1, "hi"))
    end)
    with_tokens({ { type = "comment", modifiers = {} } }, function()
      expect({ class = "trivial", kind = "comment", word = "" }, target(buf, 1, "c"))
    end)
    with_tokens({ { type = "number", modifiers = {} } }, function()
      expect({ class = "trivial", kind = "number" }, target(buf, 1, "hi"))
    end)
    with_tokens({ { type = "regexp", modifiers = {} } }, function()
      expect({ class = "trivial", kind = "string" }, target(buf, 1, "hi"))
    end)
    with_tokens({ { type = "variable", modifiers = {} } }, function()
      ok(target(buf, 1, "hi").class ~= "trivial")
    end)
  end)

  it("takes the token's own range as the word when it has one", function()
    local buf = buffer("devdocs_no_such_lang", { 'x = "hi" -- c' })
    with_tokens({ { type = "string", modifiers = {}, line = 0, start_col = 4, end_col = 8 } }, function()
      expect({ class = "trivial", kind = "string", word = '"hi"' }, target(buf, 1, "hi"))
    end)
  end)

  local has_python = (function()
    local loaded, res = pcall(vim.treesitter.language.add, "python")
    return loaded and res == true -- a missing parser returns nil, err instead of raising
  end)()

  it("reads legacy :syntax groups through their link chain", function()
    if has_python then
      return -- a real python parser would answer first
    end
    local function groups()
      local set = {}
      for _, a in ipairs(vim.api.nvim_get_autocmds {}) do
        set[a.group_name or ""] = true
      end
      return set
    end
    local before = groups()
    pcall(vim.cmd, "syntax enable") -- headless `-l` raises E495 from a BufReadPost autocmd but still enables it
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".py") -- named: other BufEnter autocmds choke on E495 otherwise
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = "hi there"  # note', "y = 42 + z", 'w = f"a {name} b"' })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "python"
    local done, err = pcall(function()
      -- the word is the whole :syntax run (quotes included), not the word under the cursor
      expect({ class = "trivial", kind = "string", word = '"hi there"' }, target(buf, 1, "there"))
      expect({ class = "trivial", kind = "string", word = '"hi there"' }, target(buf, 1, '"'))
      expect({ class = "trivial", kind = "comment" }, target(buf, 1, "note"))
      expect({ class = "trivial", kind = "number", word = "42" }, target(buf, 2, "42"))
      expect({ class = "trivial", kind = "operator", word = "+" }, target(buf, 2, "+"))
      ok(target(buf, 2, "z").class ~= "trivial")
      -- code inside an f-string is not part of the literal; the text around it is
      ok(target(buf, 3, "name").class ~= "trivial", 'name in f"{name}"')
      expect({ class = "trivial", kind = "string" }, target(buf, 3, "a {"))
    end)
    -- do not leak :syntax, or the autocmds it brings (a BufEnter one raises E495 on nameless buffers), into later specs
    pcall(vim.cmd, "syntax off")
    for name in pairs(groups()) do
      if name ~= "" and not before[name] then
        pcall(vim.api.nvim_del_augroup_by_name, name)
      end
    end
    if not done then
      error(err, 0)
    end
  end)

  it("is unknown for a buffer that is not in the current window", function()
    local other = vim.api.nvim_create_buf(false, true)
    eq({ class = "unknown", word = "" }, classify.target(other))
  end)
end)

describe("classify.literal_from_nodes", function()
  local function lit(types)
    return { classify.literal_from_nodes(types) }
  end

  it("finds the outermost string node", function()
    eq({ "string", 2 }, lit { "string_content", "string", "arguments" })
    eq({ "string", 2 }, lit { "string_fragment", "template_string", "arguments" })
    eq({ "string", 2 }, lit { "escape_sequence", "string_literal" })
    eq({ "string", 2 }, lit { "regex_pattern", "regex" })
    eq({ "string", 2 }, lit { "character", "char_literal" })
    for _, t in ipairs { "interpreted_string_literal", "raw_string_literal", "rune_literal", "char_literal" } do
      eq({ "string", 1 }, lit { t })
    end
  end)

  it("finds comments", function()
    -- the plan says index 2, but its own loop matches `comment_content` first (it contains
    -- "comment"); the index does not matter for a comment, so only the kind is asserted
    eq("comment", (classify.literal_from_nodes { "comment_content", "comment", "chunk" }))
    eq({ "comment", 1 }, lit { "line_comment", "source_file" })
    eq({ "comment", 1 }, lit { "block_comment" })
  end)

  it("is nil inside an interpolation", function()
    eq({}, lit { "identifier", "template_substitution", "template_string" })
    eq({}, lit { "identifier", "interpolation", "string" })
  end)

  it("finds numbers, booleans and nil literals only at the node itself or its parent", function()
    eq({ "number", 1 }, lit { "number_literal", "init_declarator" })
    for _, t in ipairs { "integer", "float", "int_literal", "integer_literal", "number", "imaginary_literal" } do
      eq({ "number", 1 }, lit { t })
    end
    for _, t in ipairs { "true", "false", "boolean_literal" } do
      eq({ "boolean", 1 }, lit { t })
    end
    for _, t in ipairs { "nil", "null", "none", "undefined", "nullptr" } do
      eq({ "nil", 1 }, lit { t })
    end
    eq({}, lit { "identifier", "argument_list", "call_expression", "expression_statement", "number" })
  end)

  it("is nil for a C system header and for plain identifiers", function()
    eq({}, lit { "system_lib_string", "preproc_include" })
    eq({}, lit { "identifier", "call_expression" })
  end)
end)

describe("classify.literal_kind", function()
  it("maps capture names", function()
    eq("comment", classify.literal_kind { "comment", "spell" })
    eq("comment", classify.literal_kind { "comment.documentation" })
    eq("string", classify.literal_kind { "string.escape" })
    eq("string", classify.literal_kind { "character" })
    eq("number", classify.literal_kind { "number.float" })
    eq(nil, classify.literal_kind { "boolean" })
    eq(nil, classify.literal_kind { "variable" })
    eq(nil, classify.literal_kind {})
  end)
end)

describe("classify.semantic_literal / syntax_literal", function()
  it("maps the first literal semantic token", function()
    eq("comment", classify.semantic_literal { { type = "comment" } })
    eq("string", classify.semantic_literal { { type = "regexp" } })
    eq("number", classify.semantic_literal { { type = "variable" }, { type = "number" } })
    eq(nil, classify.semantic_literal(nil))
  end)

  it("maps the first literal syntax group of a link chain", function()
    for _, g in ipairs {
      "javaScriptEmbed",
      "jsTemplateExpression",
      "pythonFStringField",
      "rubyInterpolation",
      "shCommandSub",
    } do
      ok(classify.syntax_code_in_string(g), g)
    end
    for _, g in ipairs { "pythonString", "javaScriptStringT", "Comment", "cFormat" } do
      ok(not classify.syntax_code_in_string(g), g)
    end
    eq("number", classify.syntax_literal { "pythonNumber", "Number", "Constant" })
    eq("string", classify.syntax_literal { "pythonString", "String", "Constant" })
    eq("string", classify.syntax_literal { "cCharacter", "Character" })
    eq("number", classify.syntax_literal { "Float" })
    eq("comment", classify.syntax_literal { "Todo", "Comment" })
    eq(nil, classify.syntax_literal { "Identifier" })
  end)
end)

describe("classify.nonword_kind", function()
  it("sorts the character under the cursor", function()
    eq({ "operator", "==" }, { classify.nonword_kind("a == b", 2) })
    eq({ "whitespace", "" }, { classify.nonword_kind("a == b", 1) })
    eq({ "punctuation", "(" }, { classify.nonword_kind("f(x)", 1) })
    eq({ "punctuation", ";" }, { classify.nonword_kind("x;", 1) })
    eq({ "whitespace", "" }, { classify.nonword_kind("", 0) })
    eq({ "whitespace", "" }, { classify.nonword_kind("abc", 10) })
    eq({ "operator", ".." }, { classify.nonword_kind("a..b", 1) })
    eq({ "punctuation", "." }, { classify.nonword_kind("a.b", 1) })
    eq({ "operator", "#" }, { classify.nonword_kind("#t", 0) })
  end)
end)

describe("classify.innermost_captures", function()
  it("drops literal captures when the innermost captured node is code", function()
    eq({ "variable" }, classify.innermost_captures({ "string", "variable" }, { 15, 1 })) -- JS `${x}`
    eq({ "punctuation.special" }, classify.innermost_captures({ "string", "punctuation.special" }, { 15, 2 }))
  end)

  it("keeps them when the innermost node is the literal itself", function()
    eq({ "string", "spell" }, classify.innermost_captures({ "string", "spell" }, { 9, 9 }))
    eq({ "string", "string.escape" }, classify.innermost_captures({ "string", "string.escape" }, { 9, 2 }))
    eq({ "string.special.path" }, classify.innermost_captures({ "string.special.path" }, { 7 }))
    eq({}, classify.innermost_captures({}, {}))
  end)
end)
