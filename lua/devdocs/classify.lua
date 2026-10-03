--- Classify: what kind of name is under the cursor, so a lookup can tell a
--- language keyword or library API (worth a doc page) from a variable the
--- project declared (worth an LSP hover). LSP semantic tokens win when the
--- server sends them (they know defaultLibrary from user code); otherwise the
--- treesitter highlight captures decide. Anything ambiguous is "unknown".
--- "symbol", "library" and "unknown" all mean docs first, hover when the docs
--- have no entry named exactly like the word (lookup.lua).
---
--- Besides the class, target_at reports what the cursor is on: a string,
--- comment or number literal, whitespace, an operator or punctuation all give
--- the class "trivial" (nothing to document, lookup.lua shows a popup), and a
--- name carries its kind (local, parameter, function...) and the line of its
--- declaration in the buffer when treesitter finds one.
---
--- Classes:
---   "keyword"  language keyword or operator word (local, return, sizeof)
---   "builtin"  treesitter *.builtin capture (print, int, nil, self)
---   "library"  semantic token with the defaultLibrary modifier; not proof
---              the docs have it: lua_ls marks Neovim's vim.* API too
---   "variable" a local, parameter or field the project declared (from
---              treesitter only when the locals query finds its definition
---              in the buffer)
---   "symbol"   a project function/type, or a variable that is part of a
---              chain (`t.field`, `vim.api`)
---   "unknown"  no parser, no tokens, or nothing decisive
---   "trivial"  a string/char literal, comment, number, whitespace, operator
---              or punctuation: nothing to look up
local M = {}

--- @alias DevDocsTokenClass "keyword"|"builtin"|"library"|"variable"|"symbol"|"unknown"|"trivial"

--- What the cursor is on.
--- @class DevDocsTarget
--- @field class DevDocsTokenClass
--- @field kind string|nil  "string"|"comment"|"number"|"boolean"|"nil"|"whitespace"|"operator"|"punctuation"
---                          |"local"|"variable"|"parameter"|"field"|"function"|"type"|"macro"
--- @field word string      literal text / identifier / operator chars; "" for comment and whitespace
--- @field decl_line integer|nil  1-based line of the buffer-local declaration (treesitter locals only)

--- Separators that make the word after them a member of what precedes it.
local MEMBER_SEPS = { "::", "->", ".", ":" }
--- Languages where a single ":" calls a method (`obj:method()`); elsewhere it
--- is a slice, a ternary, a label or a type annotation.
local COLON_METHOD_LANGS = { lua = true }
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

local STRING_TYPES = {
  string = true,
  string_literal = true,
  string_content = true,
  string_fragment = true,
  raw_string_literal = true,
  interpreted_string_literal = true,
  template_string = true,
  char_literal = true,
  character_literal = true,
  rune_literal = true,
  character = true,
  regex = true,
  regex_pattern = true,
  concatenated_string = true,
  encapsed_string = true,
  heredoc_body = true,
  escape_sequence = true,
}
--- Node types that contain "string" but are not a literal: C `#include <stdio.h>`
--- names a header the docs cover.
local NOT_LITERAL = { system_lib_string = true }
--- Code inside a string: not a literal.
local INTERPOLATION = {
  template_substitution = true,
  interpolation = true,
  string_interpolation = true,
  interpolated_expression = true,
}
local NUMBER_TYPES = {
  number = true,
  number_literal = true,
  integer = true,
  float = true,
  integer_literal = true,
  float_literal = true,
  int_literal = true,
  imaginary_literal = true,
  decimal_integer_literal = true,
  hex_integer_literal = true,
  octal_integer_literal = true,
  binary_integer_literal = true,
  decimal_floating_point_literal = true,
  hex_floating_point_literal = true,
}
local BOOLEAN_TYPES = { ["true"] = true, ["false"] = true, boolean_literal = true, boolean = true }
local NIL_TYPES = { ["nil"] = true, null = true, none = true, nullptr = true, undefined = true, null_literal = true }
--- Languages injected into strings and comments that stay "not code".
local TRIVIAL_INJECTIONS = {
  comment = true,
  luadoc = true,
  jsdoc = true,
  doxygen = true,
  phpdoc = true,
  printf = true,
  regex = true,
  luap = true,
}
local OPERATOR_CHARS = "[%+%-%*/%%=<>!&|%^~%?#]"
local SEMANTIC_LITERALS = { comment = "comment", string = "string", regexp = "string", number = "number" }
local SYNTAX_LITERALS =
  { Comment = "comment", String = "string", Character = "string", Number = "number", Float = "number" }
--- Parts of `:syntax` group names that mark code embedded in a string.
local SYNTAX_CODE_IN_STRING = { "Embed", "Interp", "Subst", "Expression", "CommandSub", "Deref", "StringField" }
local SEMANTIC_KIND = {
  variable = "variable",
  parameter = "parameter",
  property = "field",
  typeParameter = "type",
  ["function"] = "function",
  method = "function",
  class = "type",
  struct = "type",
  interface = "type",
  enum = "type",
  type = "type",
  macro = "macro",
}
local DECL_KIND = {
  parameter = "parameter",
  var = "variable",
  variable = "variable",
  constant = "variable",
  ["function"] = "function",
  method = "function",
  macro = "macro",
  type = "type",
  field = "field",
}
--- Ancestor node types that make a declared variable a "local" (function-scoped).
local LOCAL_SCOPE = {
  lua = { variable_declaration = true },
  c = { compound_statement = true },
  cpp = { compound_statement = true },
}
--- Classes whose declaration line and kind matter (lookup.lua's popup and
--- hover); keywords, builtins and library names never look for one.
local NEEDS_DECLARATION = { variable = true, symbol = true, unknown = true }

--- Identifier bytes: ASCII word characters and every byte of a multibyte
--- UTF-8 character, so `café` stays one word.
local WORD_CLASS = "[%w_\128-\255]"

local function is_word_char(ch)
  return ch ~= "" and ch:match(WORD_CLASS) ~= nil
end

--- 0-based inclusive byte range of the identifier at `col`, or nil when the
--- cursor is not on one. Unlike <cword> it never jumps ahead to the next word:
--- LSP hover asks about the cursor position itself, so classifying a word the
--- cursor is not on would send hover somewhere else.
--- @param line string
--- @param col integer 0-based
--- @return integer|nil start, integer|nil finish
function M.word_at(line, col)
  local i = col + 1
  if i > #line or not is_word_char(line:sub(i, i)) then
    return nil
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
--- `vim.api`). A member of self/this counts as neither. A single ":" is member
--- access only in `lang`s where it calls a method (lua).
--- @param line string
--- @param s integer
--- @param e integer
--- @param lang string|nil filetype of the line
--- @return { qualified: boolean, chain_head: boolean }
function M.context(line, s, e, lang)
  local colon_method = COLON_METHOD_LANGS[lang or ""] == true
  local before = line:sub(1, s)
  local after = line:sub(e + 2)
  local qualified = false
  for _, sep in ipairs(MEMBER_SEPS) do
    -- "::" is checked first, so a lone ":" here is never half of it
    local colon = sep == ":"
    if before:sub(-#sep) == sep and (colon_method or not colon) then
      local rest = before:sub(1, -#sep - 1)
      -- `...args` and lua's `a..b` are not member access
      local dotted = sep == "." and rest:sub(-1) == "."
      -- `{ a: 1 }`, `x ? a : b`: a ":" only qualifies when glued to a name
      local loose = sep == ":" and not is_word_char(rest:sub(-1))
      if not dotted and not loose then
        local owner = rest:match("(" .. WORD_CLASS .. "+)$")
        qualified = not (owner and SELF_NAMES[owner])
      end
      break
    end
  end
  local chain_head = after:match "^%.[%a_]" ~= nil
    or after:match "^::" ~= nil
    or after:match "^%->" ~= nil
    or (colon_method and after:match "^:[%a_]" ~= nil)
  return { qualified = qualified, chain_head = chain_head }
end

local function is_comment_type(t)
  return t:find("comment", 1, true) ~= nil
end

local function is_string_type(t)
  return not NOT_LITERAL[t] and (STRING_TYPES[t] or t:find("string", 1, true) ~= nil) or false
end

--- Literal kind of a node and its ancestors (treesitter node types, innermost
--- first), plus the index of the outermost node that is part of the literal
--- (the whole string, quotes included). Code interpolated into a string is not
--- a literal. A number or true/nil only counts at the node itself or its parent.
--- @param types string[]
--- @return string|nil kind "comment"|"string"|"number"|"boolean"|"nil"
--- @return integer|nil index
function M.literal_from_nodes(types)
  for i, t in ipairs(types) do
    if INTERPOLATION[t] or NOT_LITERAL[t] then
      return nil
    elseif is_comment_type(t) then
      local j = i
      while types[j + 1] and is_comment_type(types[j + 1]) do
        j = j + 1
      end
      return "comment", j
    elseif is_string_type(t) then
      local j = i
      while types[j + 1] and is_string_type(types[j + 1]) do
        j = j + 1
      end
      return "string", j
    elseif i <= 2 then
      if NUMBER_TYPES[t] then
        return "number", i
      elseif BOOLEAN_TYPES[t] then
        return "boolean", i
      elseif NIL_TYPES[t] then
        return "nil", i
      end
    end
  end
  return nil
end

--- Literal kind from treesitter highlight capture names (without the "@").
--- @param names string[]
--- @return string|nil kind "comment"|"string"|"number"
function M.literal_kind(names)
  for _, name in ipairs(names) do
    if name:match "^comment" then
      return "comment"
    elseif name:match "^string" or name:match "^character" then
      return "string"
    elseif name:match "^number" then
      return "number"
    end
  end
  return nil
end

--- Literal kind from LSP semantic tokens covering a position.
--- @param tokens table[]|nil
--- @return string|nil kind
function M.semantic_literal(tokens)
  for _, tok in ipairs(tokens or {}) do
    if SEMANTIC_LITERALS[tok.type] then
      return SEMANTIC_LITERALS[tok.type]
    end
  end
  return nil
end

--- Literal kind from `:syntax` group names (a group's own name, then the
--- groups it links to).
--- @param names string[]
--- @return string|nil kind
function M.syntax_literal(names)
  for _, name in ipairs(names) do
    if SYNTAX_LITERALS[name] then
      return SYNTAX_LITERALS[name]
    end
  end
  return nil
end

--- Whether a `:syntax` group name is code embedded in a string: JS
--- javaScriptEmbed / jsTemplateExpression, Python pythonFStringField /
--- pythonStrInterpRegion, Ruby rubyInterpolation, shell shCommandSub /
--- shDerefSimple.
--- @param name string
--- @return boolean
function M.syntax_code_in_string(name)
  for _, part in ipairs(SYNTAX_CODE_IN_STRING) do
    if name:find(part, 1, true) then
      return true
    end
  end
  return false
end

--- What a position that is not on an identifier holds.
--- @param line string
--- @param col integer 0-based byte
--- @return string kind "whitespace"|"operator"|"punctuation"
--- @return string text
function M.nonword_kind(line, col)
  local ch = line:sub(col + 1, col + 1)
  if ch == "" or ch:match "%s" then
    return "whitespace", ""
  end
  if ch == "." then
    -- a lone "." is punctuation (member access); `..` and `...` are operators
    local s, e = col + 1, col + 1
    while s > 1 and line:sub(s - 1, s - 1) == "." do
      s = s - 1
    end
    while e < #line and line:sub(e + 1, e + 1) == "." do
      e = e + 1
    end
    if e > s then
      return "operator", line:sub(s, e)
    end
    return "punctuation", "."
  end
  if ch:match(OPERATOR_CHARS) then
    local s, e = col + 1, col + 1
    while s > 1 and line:sub(s - 1, s - 1):match(OPERATOR_CHARS) do
      s = s - 1
    end
    while e < #line and line:sub(e + 1, e + 1):match(OPERATOR_CHARS) do
      e = e + 1
    end
    return "operator", line:sub(s, e)
  end
  return "punctuation", ch
end

--- Class from treesitter highlight capture names (without the "@").
--- @param names string[]
--- @param ctx { qualified?: boolean, chain_head?: boolean }
--- @return DevDocsTokenClass
function M.from_captures(names, ctx)
  if M.literal_kind(names) then
    return "trivial"
  end
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
--- @return string|nil token_type the type of the token that decided
local function semantic_pick(tokens, ctx)
  local best, best_type
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
      return class, tok.type
    end
    if class and not best then
      best, best_type = class, tok.type
    end
  end
  return best, best_type
end

--- @param tokens table[]|nil
--- @param ctx { qualified?: boolean, chain_head?: boolean }
--- @return DevDocsTokenClass|nil
function M.from_semantic(tokens, ctx)
  return (semantic_pick(tokens, ctx))
end

--- The buffer's parsed language tree at (row, col), or nil.
--- @return vim.treesitter.LanguageTree|nil
local function language_tree(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  pcall(parser.parse, parser, { row, row + 1 })
  local tree_ok, ltree = pcall(parser.language_for_range, parser, { row, col, row, col })
  if not tree_ok or not ltree then
    return nil
  end
  return ltree
end

--- Highlight capture names covering (row, col), from the highlights query;
--- independent of whether highlighting is enabled.
--- @param ltree vim.treesitter.LanguageTree
--- @return string[] names
--- @return integer[] sizes byte length of each capture's node
local function captures(ltree, bufnr, row, col)
  local q_ok, query = pcall(vim.treesitter.query.get, ltree:lang(), "highlights")
  if not q_ok or not query then
    return {}, {}
  end
  local names, sizes = {}, {}
  for _, tstree in ipairs(ltree:trees()) do
    for id, node in query:iter_captures(tstree:root(), bufnr, row, row + 1) do
      if vim.treesitter.is_in_node_range(node, row, col) then
        local _, _, sb = node:start()
        local _, _, eb = node:end_()
        names[#names + 1] = query.captures[id]
        sizes[#sizes + 1] = eb - sb
      end
    end
  end
  return names, sizes
end

--- Capture names without the literal ones (@string, @comment, @number) when
--- the innermost captured node is not a literal: the `x` of JS `${x}` or
--- Python f"{x}" sits inside a template captured as @string, but its own
--- node is captured as code.
--- @param names string[]
--- @param sizes integer[]
--- @return string[]
function M.innermost_captures(names, sizes)
  local min
  for _, size in ipairs(sizes) do
    min = (not min or size < min) and size or min
  end
  local inner = {}
  for i, name in ipairs(names) do
    if sizes[i] == min then
      inner[#inner + 1] = name
    end
  end
  if M.literal_kind(inner) then
    return names
  end
  local code = {}
  for _, name in ipairs(names) do
    if not M.literal_kind { name } then
      code[#code + 1] = name
    end
  end
  return code
end

--- Declarations for parsers Neovim ships without a locals query (its runtime
--- has highlights but no locals.scm for lua and c; nvim-treesitter adds them).
--- Only the names a function body declares: locals, parameters, loop names.
M.LOCALS_FALLBACK = {
  lua = [[
    (variable_declaration (variable_list (identifier) @local.definition.var))
    (variable_declaration (assignment_statement (variable_list (identifier) @local.definition.var)))
    (assignment_statement (variable_list (identifier) @local.definition.var))
    (function_declaration name: (identifier) @local.definition.function)
    (for_generic_clause (variable_list (identifier) @local.definition.var))
    (for_numeric_clause name: (identifier) @local.definition.var)
    (parameters (identifier) @local.definition.parameter)
  ]],
  c = [[
    (function_declarator declarator: (identifier) @local.definition.function)
    (pointer_declarator declarator: (identifier) @local.definition.var)
    (parameter_declaration declarator: (identifier) @local.definition.parameter)
    (init_declarator declarator: (identifier) @local.definition.var)
    (array_declarator declarator: (identifier) @local.definition.var)
    (declaration declarator: (identifier) @local.definition.var)
    (preproc_def name: (identifier) @local.definition.macro)
    (preproc_function_def name: (identifier) @local.definition.macro)
  ]],
}

local fallback_queries = {} --- lang -> parsed query, or false when it does not parse

--- The locals query of `lang`: the runtime's, else the bundled fallback, else nil.
--- @param lang string
--- @return vim.treesitter.Query|nil
function M.locals_query(lang)
  local q_ok, query = pcall(vim.treesitter.query.get, lang, "locals")
  if q_ok and query then
    return query
  end
  local src = M.LOCALS_FALLBACK[lang]
  if not src then
    return nil
  end
  if fallback_queries[lang] == nil then
    local ok, parsed = pcall(vim.treesitter.query.parse, lang, src)
    fallback_queries[lang] = ok and parsed or false
  end
  return fallback_queries[lang] or nil
end

--- The buffer's definition of `name` (a @local.definition* capture of the
--- locals query with that text): the latest one at or before `row`, else the
--- first one after it. nil without a locals query: a highlight capture alone
--- cannot tell a project's `count` from lua's `error` or C's `errno` used as a
--- value.
--- @param ltree vim.treesitter.LanguageTree
--- @param name string
--- @param row integer 0-based cursor row
--- @return TSNode|nil node, string|nil suffix "var", "function", ... ("" for a bare @local.definition)
local function find_definition(ltree, bufnr, name, row)
  local query = M.locals_query(ltree:lang())
  if not query then
    return nil
  end
  local best, best_suffix, best_row
  for _, tstree in ipairs(ltree:trees()) do
    for id, node in query:iter_captures(tstree:root(), bufnr, 0, -1) do
      local cap = query.captures[id]
      if
        (cap == "local.definition" or cap:sub(1, 17) == "local.definition.")
        and vim.treesitter.get_node_text(node, bufnr) == name
      then
        local r = node:start()
        local better
        if not best then
          better = true
        elseif r <= row then
          better = best_row > row or r >= best_row
        else
          better = best_row > row and r < best_row
        end
        if better then
          best, best_suffix, best_row = node, cap:match "^local%.definition%.(.+)$" or "", r
        end
      end
    end
  end
  return best, best_suffix
end

--- Whether `node` sits inside one of the ancestor types of `scopes`.
local function inside(node, scopes)
  local p = node:parent()
  while p do
    if scopes[p:type()] then
      return true
    end
    p = p:parent()
  end
  return false
end

--- The treesitter parser of `bufnr`, or nil.
local function host_parser(bufnr, row)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  pcall(parser.parse, parser, { row, row + 1 })
  return parser
end

--- A literal (string, comment, number, true/nil...) from the host-language
--- syntax tree at (row, col), ignoring injections so `"..."` stays a string.
--- Code injected into a string (`vim.cmd("set number")`) is not a literal.
--- @return DevDocsTarget|nil
local function host_literal(parser, bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col }, ignore_injections = true })
  if not ok or not node then
    return nil
  end
  local types, nodes = {}, {}
  local n = node
  while n do
    types[#types + 1] = n:type()
    nodes[#nodes + 1] = n
    n = n:parent()
  end
  if NOT_LITERAL[types[1]] or NOT_LITERAL[types[2] or ""] then
    return nil
  end
  local kind, idx = M.literal_from_nodes(types)
  if not kind then
    return nil
  end
  local function text()
    local t_ok, t = pcall(vim.treesitter.get_node_text, nodes[idx], bufnr)
    return t_ok and t or ""
  end
  if kind == "comment" then
    return { class = "trivial", kind = "comment", word = "" }
  elseif kind == "string" then
    local l_ok, ltree = pcall(parser.language_for_range, parser, { row, col, row, col })
    local inj = l_ok and ltree and ltree:lang() or parser:lang()
    if inj ~= parser:lang() and not TRIVIAL_INJECTIONS[inj] then
      return nil
    end
    return { class = "trivial", kind = "string", word = text() }
  elseif kind == "number" then
    return { class = "trivial", kind = "number", word = text() }
  end
  return { class = "builtin", kind = kind, word = text() }
end

--- The text of the host-language token at (row, col) when it is one leaf that
--- starts with a non-word character and holds a word (`#include`, `#define`):
--- the cursor is on a directive, not an operator. nil otherwise.
--- @return string|nil
local function directive_token(parser, bufnr, row, col)
  local trees = parser:trees()
  local root = trees[1] and trees[1]:root()
  if not root then
    return nil
  end
  local ok, node = pcall(root.descendant_for_range, root, row, col, row, col + 1)
  if not ok or not node or node:child_count() > 0 then
    return nil
  end
  local t_ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not t_ok or text:find("\n", 1, true) or is_word_char(text:sub(1, 1)) or not text:find(WORD_CLASS) then
    return nil
  end
  return text
end

--- Word of a literal found without treesitter: the semantic token's text, else
--- the identifier under the cursor, "" for a comment.
local function literal_word(kind, line, col, tok, row)
  if kind == "comment" then
    return ""
  end
  if tok and tok.line == row and tok.start_col and tok.end_col then
    return line:sub(tok.start_col + 1, tok.end_col)
  end
  local s, e = M.word_at(line, col)
  return s and line:sub(s + 1, e + 1) or ""
end

--- Literal kind from `:syntax` at (row, col) of the current buffer; follows
--- each group's link chain (pythonNumber -> Constant, not Number).
--- @return string|nil
local function syntax_kind(row, col)
  local ok, stack = pcall(vim.fn.synstack, row + 1, col + 1)
  if not ok or type(stack) ~= "table" then
    return nil
  end
  -- innermost group first: code embedded in a string (`${x}`, f"{x}") is
  -- not part of the literal around it
  for i = #stack, 1, -1 do
    local names = {}
    local name = vim.fn.synIDattr(stack[i], "name")
    if M.syntax_code_in_string(name) then
      return nil
    end
    for _ = 1, 10 do
      if not name or name == "" then
        break
      end
      names[#names + 1] = name
      local h_ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = true })
      name = h_ok and hl and hl.link or nil
    end
    local kind = M.syntax_literal(names)
    if kind then
      return kind
    end
  end
  return nil
end

--- Longest literal one :syntax run checks per side; a string longer than
--- this is cut (explain.lua quotes at most 40 characters anyway).
local SYNTAX_RUN_MAX = 200

--- The text around `col` that :syntax gives the same literal kind (the whole
--- string, quotes included), so the popup quotes `"hi there"`, not `there`.
--- @return string
local function syntax_run(line, row, col, kind)
  local s, e = col, col
  while s > 0 and col - s < SYNTAX_RUN_MAX and syntax_kind(row, s - 1) == kind do
    s = s - 1
  end
  while e + 1 < #line and e - col < SYNTAX_RUN_MAX and syntax_kind(row, e + 1) == kind do
    e = e + 1
  end
  return line:sub(s + 1, e + 1)
end

--- Whether the host-language node at (row, col) is a NOT_LITERAL one.
local function in_not_literal(bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col }, ignore_injections = true })
  if not ok or not node then
    return false
  end
  local parent = node:parent()
  return NOT_LITERAL[node:type()] == true or (parent ~= nil and NOT_LITERAL[parent:type()] == true)
end

--- Target for the identifier at [s, e] (0-based, inclusive) of `line`.
--- @return DevDocsTarget
local function identifier_target(bufnr, row, s, e, line)
  local word = line:sub(s + 1, e + 1)
  local ctx = M.context(line, s, e, vim.bo[bufnr].filetype)
  -- Semantic tokens know the whole program: their "variable" needs no check.
  local ok, tokens = pcall(vim.lsp.semantic_tokens.get_at_pos, bufnr, row, s)
  local class, token_type
  if ok then
    class, token_type = semantic_pick(tokens, ctx)
  end
  local ltree = language_tree(bufnr, row, s)
  local names = {}
  if not class then
    if not ltree then
      class = "unknown"
    else
      local c_ok, found, sizes = pcall(captures, ltree, bufnr, row, s)
      names = c_ok and M.innermost_captures(found, sizes) or {}
      class = M.from_captures(names, ctx)
    end
  end
  if class == "trivial" and in_not_literal(bufnr, row, s) then
    -- C `#include <stdio.h>`: highlighted as a string, but a header the docs cover
    class = "unknown"
  end
  if class == "trivial" then
    local kind = M.literal_kind(names)
    return { class = "trivial", kind = kind, word = kind == "comment" and "" or word }
  end
  -- Scanning the buffer's declarations costs a full locals-query pass (about
  -- 100 ms in a 50k-line file): only names a popup or hover may cover need it.
  local def_node, suffix
  if ltree and not ctx.qualified and NEEDS_DECLARATION[class] then
    local d_ok, node, sfx = pcall(find_definition, ltree, bufnr, word, row)
    if d_ok then
      def_node, suffix = node, sfx
    end
  end
  -- a "variable" from highlights must be declared in the buffer, else it may be a library name
  if class == "variable" and not token_type and not def_node then
    class = "symbol"
  end
  local kind
  if def_node then
    kind = DECL_KIND[suffix or ""]
    if kind == "variable" and inside(def_node, LOCAL_SCOPE[ltree:lang()] or {}) then
      kind = "local"
    end
  end
  -- a declared variable wins over highlight noise (lua's @constant on an all-caps `M`)
  if class == "unknown" and not token_type and (kind == "variable" or kind == "local" or kind == "parameter") then
    class = "variable"
  end
  kind = kind or SEMANTIC_KIND[token_type or ""] or (class == "variable" and "variable" or nil)
  return { class = class, kind = kind, word = word, decl_line = def_node and (def_node:start() + 1) or nil }
end

--- What is at (row, col) of `bufnr`: the class and, when it can tell, the kind
--- of literal or name and where the name was declared.
--- @param bufnr integer
--- @param row integer 0-based
--- @param col integer 0-based byte
--- @return DevDocsTarget
function M.target_at(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return { class = "unknown", word = "" }
  end
  local parser = host_parser(bufnr, row)
  if parser then
    local lit = host_literal(parser, bufnr, row, col)
    if lit then
      return lit
    end
  else
    local ok, tokens = pcall(vim.lsp.semantic_tokens.get_at_pos, bufnr, row, col)
    local kind = ok and M.semantic_literal(tokens) or nil
    if kind then
      local tok
      for _, t in ipairs(tokens) do
        if SEMANTIC_LITERALS[t.type] == kind then
          tok = t
          break
        end
      end
      return { class = "trivial", kind = kind, word = literal_word(kind, line, col, tok, row) }
    end
    if bufnr == vim.api.nvim_get_current_buf() then
      kind = syntax_kind(row, col)
      if kind then
        return { class = "trivial", kind = kind, word = kind == "comment" and "" or syntax_run(line, row, col, kind) }
      end
    end
  end
  local s, e = M.word_at(line, col)
  if not s then
    local directive = parser and directive_token(parser, bufnr, row, col)
    if directive then
      -- the `#` of C's `#include`: part of a directive the docs cover, like the word after it
      return { class = "keyword", word = directive }
    end
    local kind, text = M.nonword_kind(line, col)
    return { class = "trivial", kind = kind, word = text }
  end
  return identifier_target(bufnr, row, s, e, line)
end

--- Class of the identifier at (row, col) of `bufnr`.
--- @param bufnr integer
--- @param row integer 0-based
--- @param col integer 0-based byte
--- @return DevDocsTokenClass
function M.at(bufnr, row, col)
  return M.target_at(bufnr, row, col).class
end

--- Target under the cursor; "unknown" unless `bufnr` is the current window's
--- buffer (the cursor would be someone else's).
--- @param bufnr integer
--- @return DevDocsTarget
function M.target(bufnr)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return { class = "unknown", word = "" }
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return M.target_at(bufnr, row - 1, col)
end

--- Class of the identifier under the cursor; "unknown" unless `bufnr` is the
--- current window's buffer (the cursor would be someone else's).
--- @param bufnr integer
--- @return DevDocsTokenClass
function M.cursor(bufnr)
  return M.target(bufnr).class
end

return M
