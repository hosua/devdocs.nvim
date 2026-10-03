--- Classify: what kind of name is under the cursor, so a lookup can tell a
--- language keyword or library API (worth a doc page) from a variable the
--- project declared (worth an LSP hover). LSP semantic tokens win when the
--- server sends them (they know defaultLibrary from user code); otherwise the
--- treesitter highlight captures decide. Anything ambiguous is "unknown" and
--- the lookup behaves as it did before.
---
--- Classes:
---   "keyword"  language keyword or operator word (local, return, sizeof)
---   "builtin"  treesitter *.builtin capture (print, int, nil, self)
---   "library"  semantic token with the defaultLibrary modifier
---   "variable" a local, parameter or field the project declared
---   "symbol"   a project function/type, or a variable that is part of a
---              chain (`t.field`, `vim.api`): docs first, hover when they
---              have nothing
---   "unknown"  no parser, no tokens, or nothing decisive
local M = {}

--- @alias DevDocsTokenClass "keyword"|"builtin"|"library"|"variable"|"symbol"|"unknown"

--- Separators that make the word after them a member of what precedes it.
local MEMBER_SEPS = { "::", "->", ".", ":" }
--- A member of these is the object's own state, so it is a project variable.
local SELF_NAMES = { self = true, this = true, cls = true }

local SEMANTIC_VARIABLES = { variable = true, parameter = true, property = true, typeParameter = true }
local SEMANTIC_KEYWORDS = { keyword = true, modifier = true, operator = true }
local SEMANTIC_SYMBOLS = {
  ["function"] = true,
  method = true,
  class = true,
  struct = true,
  interface = true,
  enum = true,
  enumMember = true,
  type = true,
  macro = true,
  decorator = true,
  event = true,
}

local function is_word_char(ch)
  return ch ~= "" and ch:match "[%w_]" ~= nil
end

--- 0-based inclusive byte range of the identifier at `col`, or of the next one
--- on the line when the cursor is on whitespace/punctuation (what <cword> does).
--- @param line string
--- @param col integer 0-based
--- @return integer|nil start, integer|nil finish
function M.word_at(line, col)
  local i = col + 1
  if i > #line then
    return nil
  end
  if not is_word_char(line:sub(i, i)) then
    local next_at = line:find("[%w_]", i)
    if not next_at then
      return nil
    end
    i = next_at
  end
  local s, e = i, i
  while s > 1 and is_word_char(line:sub(s - 1, s - 1)) do
    s = s - 1
  end
  while e < #line and is_word_char(line:sub(e + 1, e + 1)) do
    e = e + 1
  end
  return s - 1, e - 1
end

--- Whether the word at [s, e] (0-based, inclusive) is a member reached through
--- a separator (`t.field`, `p->x`) and whether it heads a chain (`vim` in
--- `vim.api`). A member of self/this counts as neither.
--- @param line string
--- @param s integer
--- @param e integer
--- @return { qualified: boolean, chain_head: boolean }
function M.context(line, s, e)
  local before = line:sub(1, s)
  local after = line:sub(e + 2)
  local qualified = false
  for _, sep in ipairs(MEMBER_SEPS) do
    if before:sub(-#sep) == sep then
      local rest = before:sub(1, -#sep - 1)
      -- `...args` and lua's `a..b` are not member access
      local dotted = sep == "." and rest:sub(-1) == "."
      -- `{ a: 1 }`, `x ? a : b`: a ":" only qualifies when glued to a name
      local loose = sep == ":" and not is_word_char(rest:sub(-1))
      if not dotted and not loose then
        local owner = rest:match "([%w_]+)$"
        qualified = not (owner and SELF_NAMES[owner])
      end
      break
    end
  end
  local chain_head = after:match "^%.[%a_]" ~= nil
    or after:match "^::" ~= nil
    or after:match "^%->" ~= nil
    or after:match "^:[%a_]" ~= nil
  return { qualified = qualified, chain_head = chain_head }
end

--- Class from treesitter highlight capture names (without the "@").
--- @param names string[]
--- @param ctx { qualified?: boolean, chain_head?: boolean }
--- @return DevDocsTokenClass
function M.from_captures(names, ctx)
  local keyword, builtin, variable, member, other = false, false, false, false, false
  for _, name in ipairs(names) do
    if name:sub(1, 1) == "_" or name == "spell" or name == "nospell" or name == "none" then
      -- private and spell captures say nothing about the token
    elseif name:match "^keyword" then
      keyword = true
    elseif name:match "%.builtin$" or name:match "%.builtin%." or name == "boolean" then
      builtin = true
    elseif name == "variable" or name == "variable.parameter" or name:match "^variable%.parameter%." then
      variable = true
    elseif name == "variable.member" or name == "property" or name:match "^variable%.member%." then
      member = true
    else
      other = true
    end
  end
  if keyword then
    return "keyword"
  end
  if builtin then
    return "builtin"
  end
  if other or not (variable or member) then
    return "unknown"
  end
  -- `t.field` or the `vim` of `vim.api` may belong to a library: docs first
  if ctx.qualified or ctx.chain_head then
    return "symbol"
  end
  return "variable"
end

--- Class from LSP semantic tokens covering the word, or nil when they say
--- nothing useful (no tokens, or only string/comment/number tokens).
--- @param tokens table[]|nil items of vim.lsp.semantic_tokens.get_at_pos()
--- @param ctx { qualified?: boolean, chain_head?: boolean }
--- @return DevDocsTokenClass|nil
function M.from_semantic(tokens, ctx)
  local best
  for _, tok in ipairs(tokens or {}) do
    local mods = tok.modifiers or {}
    local class
    if mods.defaultLibrary then
      class = "library"
    elseif SEMANTIC_KEYWORDS[tok.type] then
      class = "keyword"
    elseif SEMANTIC_VARIABLES[tok.type] then
      -- part of a chain (`os.sep`, `vim.api`) may well be a library's: docs first
      class = (ctx.qualified or ctx.chain_head) and "symbol" or "variable"
    elseif SEMANTIC_SYMBOLS[tok.type] then
      class = "symbol"
    elseif tok.type == "namespace" then
      class = "unknown"
    end
    if class == "library" then
      return class
    end
    best = best or class
  end
  return best
end

--- Highlight capture names covering (row, col), from the buffer's parser and
--- the highlights query; independent of whether highlighting is enabled.
--- @return string[]
local function captures(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not ok or not parser then
    return {}
  end
  pcall(parser.parse, parser, { row, row + 1 })
  local tree_ok, ltree = pcall(parser.language_for_range, parser, { row, col, row, col })
  if not tree_ok or not ltree then
    return {}
  end
  local q_ok, query = pcall(vim.treesitter.query.get, ltree:lang(), "highlights")
  if not q_ok or not query then
    return {}
  end
  local names = {}
  for _, tstree in ipairs(ltree:trees()) do
    for id, node in query:iter_captures(tstree:root(), bufnr, row, row + 1) do
      if vim.treesitter.is_in_node_range(node, row, col) then
        names[#names + 1] = query.captures[id]
      end
    end
  end
  return names
end

--- Class of the identifier at (row, col) of `bufnr`.
--- @param bufnr integer
--- @param row integer 0-based
--- @param col integer 0-based byte
--- @return DevDocsTokenClass
function M.at(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return "unknown"
  end
  local s, e = M.word_at(line, col)
  if not s then
    return "unknown"
  end
  local ctx = M.context(line, s, e)
  local ok, tokens = pcall(vim.lsp.semantic_tokens.get_at_pos, bufnr, row, s)
  local class = ok and M.from_semantic(tokens, ctx) or nil
  if class then
    return class
  end
  local cap_ok, names = pcall(captures, bufnr, row, s)
  return M.from_captures(cap_ok and names or {}, ctx)
end

--- Class of the identifier under the cursor; "unknown" unless `bufnr` is the
--- current window's buffer (the cursor would be someone else's).
--- @param bufnr integer
--- @return DevDocsTokenClass
function M.cursor(bufnr)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return "unknown"
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return M.at(bufnr, row - 1, col)
end

return M
