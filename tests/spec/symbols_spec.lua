local symbols = require "devdocs.symbols"

local function buffer(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  vim.api.nvim_set_current_buf(buf)
  return buf
end

describe("symbols", function()
  it("splits qualified chains on every separator", function()
    eq({ "std", "vector", "push_back" }, symbols.split "std::vector::push_back")
    eq({ "os", "path", "join" }, symbols.split "os.path.join")
    eq({ "ptr", "field" }, symbols.split "ptr->field")
    eq({ "obj", "method" }, symbols.split "obj:method")
    eq({ "plain" }, symbols.split "plain")
    eq({}, symbols.split "")
  end)

  it("builds candidates from a chain up to the cursor word, then suffixes", function()
    eq({ "os.path.join", "path.join", "join" }, symbols.from_chain("os.path.join", "join", "."))
    eq({ "os.path", "path", "os.path.join" }, symbols.from_chain("os.path.join", "path", "."))
    eq({ "std::cout", "cout" }, symbols.from_chain("std::cout", "cout", "::"))
    eq({ "a.b", "b" }, symbols.from_chain("a.b", nil, "."))
    eq({ "x" }, symbols.from_chain("", "x", "."))
  end)

  it("prefers std:: first under `using namespace std`, last otherwise", function()
    local with = symbols.rules.cpp(
      { "cout" },
      { lines = { "#include <iostream>", "using namespace std;" }, word = "cout" }
    )
    eq({ "std::cout", "cout" }, with)
    local without = symbols.rules.cpp({ "cout" }, { lines = { "#include <iostream>" }, word = "cout" })
    eq({ "cout", "std::cout" }, without)
    eq({ "std::cout" }, symbols.rules.cpp({ "std::cout" }, { lines = {}, word = "cout" }))
  end)

  it("keeps dashed and pseudo names for css", function()
    eq({ "grid-template-areas" }, symbols.rules.css({}, { css_word = "grid-template-areas", word = "grid" }))
    eq({ ":hover", "hover" }, symbols.rules.css({}, { css_word = ":hover", word = "hover" }))
  end)

  it("takes an explicit selection as the first candidate", function()
    buffer({ "x" }, "python")
    eq({ "os.path.join", "path.join", "join" }, symbols.candidates(nil, { text = " os.path.join " }))
  end)

  it("falls back to the word under the cursor without a parser", function()
    buffer({ "hello world" }, "nonesuchft")
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    eq({ "world" }, symbols.candidates())
  end)

  it("uses the treesitter chain when a parser is available (lua ships with nvim)", function()
    if not pcall(vim.treesitter.language.add, "lua") then
      ok(true, "no lua parser; skipped")
      return
    end
    buffer({ "local s = string.format('%d', 1)" }, "lua")
    vim.treesitter.start(0, "lua")
    vim.api.nvim_win_set_cursor(0, { 1, 18 }) -- on "format"
    eq({ "string.format", "format" }, symbols.candidates())
    vim.api.nvim_win_set_cursor(0, { 1, 11 }) -- on "string"
    eq({ "string", "string.format" }, symbols.candidates())
  end)

  it("reads css tokens with dashes at the cursor", function()
    buffer({ "a { grid-template-areas: none; }" }, "css")
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    local c = symbols.candidates()
    eq("grid-template-areas", c[1])
  end)
end)
