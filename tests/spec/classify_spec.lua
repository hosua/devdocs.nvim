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

  it("is unknown when the cursor is on whitespace or punctuation (hover would not see the next word)", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq("unknown", classify.cursor(buf)) -- "  local": indentation, not `local`
    vim.api.nvim_win_set_cursor(0, { 2, 7 })
    eq("unknown", classify.cursor(buf)) -- the space before `count`
    local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
    vim.api.nvim_win_set_cursor(0, { 2, line:find("=", 1, true) - 1 })
    eq("unknown", classify.cursor(buf)) -- on `=`
  end)

  it("is unknown on empty and blank lines", function()
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    eq("unknown", classify.cursor(buf))
    vim.api.nvim_win_set_cursor(0, { 9, 5 })
    eq("unknown", classify.cursor(buf))
  end)

  it("is unknown after the last word on the line", function()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.cmd "normal! $"
    eq("variable", classify.cursor(buf)) -- on the last char of `param`
    local line = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
    eq("unknown", classify.at(buf, 4, #line + 3))
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

  it("downgrades a treesitter variable to symbol when the language has no locals query", function()
    local buf = buffer("lua", { "local count = 1", "print(count)" })
    local orig = vim.treesitter.query.get
    vim.treesitter.query.get = function(lang, name)
      if name == "locals" then
        return nil
      end
      return orig(lang, name)
    end
    local ok, err = pcall(function()
      eq("symbol", at(buf, 2, "count"))
    end)
    vim.treesitter.query.get = orig
    assert(ok, err)
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
    eq("unknown", classify.from_captures({ "comment", "spell" }, plain))
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
