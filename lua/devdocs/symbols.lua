--- Symbols: what is under the cursor, as an ordered list of names to look
--- up. Treesitter gives the qualified chain when a parser is installed
--- ("std::cout", "os.path.join", "arr.map"); the word under the cursor is
--- the fallback. Language rules then add what the docs actually call
--- things: C++ entries are "std::x", so a bare "cout" under
--- `using namespace std;` becomes "std::cout" first.
local M = {}

--- Node types whose text is a qualified name, per parser language.
local CHAIN_NODES = {
  cpp = { qualified_identifier = true, field_expression = true, template_function = true, scoped_identifier = true },
  c = { field_expression = true },
  python = { attribute = true },
  javascript = { member_expression = true },
  typescript = { member_expression = true },
  tsx = { member_expression = true },
  lua = { dot_index_expression = true, method_index_expression = true },
  go = { selector_expression = true },
  rust = { scoped_identifier = true, field_expression = true },
  java = { field_access = true, method_invocation = false, scoped_identifier = true },
  kotlin = { navigation_expression = true },
  php = { member_access_expression = true, scoped_call_expression = true, class_constant_access_expression = true },
  ruby = { scope_resolution = true, call = false },
  css = { pseudo_class_selector = true, pseudo_element_selector = true },
}

local SEPARATORS = { "::", "->", ".", ":" }

--- Split "std::vector::push_back" or "os.path.join" into its parts.
--- @param chain string
--- @return string[]
function M.split(chain)
  local parts = {}
  local s = chain
  while s ~= "" do
    local best_at, best_sep
    for _, sep in ipairs(SEPARATORS) do
      local at = s:find(sep, 1, true)
      if at and (not best_at or at < best_at) then
        best_at, best_sep = at, sep
      end
    end
    if not best_at then
      parts[#parts + 1] = s
      break
    end
    if best_at > 1 then
      parts[#parts + 1] = s:sub(1, best_at - 1)
    end
    s = s:sub(best_at + #best_sep)
  end
  return parts
end

--- Candidates from a qualified chain and the word the cursor is on:
--- the chain up to that word, then every shorter suffix, then the word.
--- @param chain string      "os.path.join"
--- @param word string|nil   "path" (nil: the last part)
--- @param sep string        separator the docs use (".", "::")
--- @return string[]
function M.from_chain(chain, word, sep)
  local parts = M.split(chain)
  if #parts == 0 then
    return word and { word } or {}
  end
  local stop = #parts
  if word then
    for i, p in ipairs(parts) do
      if p == word then
        stop = i
        break
      end
    end
  end
  local out, seen = {}, {}
  local function add(s)
    if s ~= "" and not seen[s] then
      seen[s] = true
      out[#out + 1] = s
    end
  end
  for start = 1, stop do
    add(table.concat(vim.list_slice(parts, start, stop), sep))
  end
  if stop < #parts then
    add(table.concat(parts, sep))
  end
  if word then
    add(word)
  end
  return out
end

--- Separator used in the docs of a filetype.
--- @param ft string
--- @return string
function M.separator(ft)
  if ft == "cpp" or ft == "c" or ft == "rust" or ft == "php" or ft == "ruby" then
    return "::"
  end
  return "."
end

--- Language rules applied to the candidate list.
--- @type table<string, fun(cands: string[], ctx: { lines: string[], word: string }): string[]>
M.rules = {
  cpp = function(cands, ctx)
    local using_std = false
    for _, l in ipairs(ctx.lines) do
      if l:match "using%s+namespace%s+std%s*;" then
        using_std = true
        break
      end
    end
    local out = {}
    for _, c in ipairs(cands) do
      if using_std and not c:find("::", 1, true) then
        out[#out + 1] = "std::" .. c
      end
      out[#out + 1] = c
    end
    if not using_std then
      for _, c in ipairs(cands) do
        if not c:find("::", 1, true) then
          out[#out + 1] = "std::" .. c
        end
      end
    end
    return out
  end,
  c = function(cands)
    return cands
  end,
  javascript = function(cands, ctx)
    -- "arr.map" is documented as "Array.prototype.map()"; the bare method finds it
    local out = vim.list_slice(cands)
    if ctx.word and ctx.word ~= "" then
      out[#out + 1] = ctx.word
    end
    return out
  end,
  css = function(cands, ctx)
    -- CSS names carry dashes and colons that iskeyword drops
    local out = {}
    if ctx.css_word and ctx.css_word ~= "" then
      out[#out + 1] = ctx.css_word
      local bare = ctx.css_word:gsub("^[:@]+", "")
      if bare ~= ctx.css_word then
        out[#out + 1] = bare
      end
    end
    for _, c in ipairs(cands) do
      out[#out + 1] = c
    end
    return out
  end,
}
M.rules.typescript = M.rules.javascript
M.rules.typescriptreact = M.rules.javascript
M.rules.javascriptreact = M.rules.javascript
M.rules.scss = M.rules.css
M.rules.less = M.rules.css

local function dedupe(list)
  local out, seen = {}, {}
  for _, c in ipairs(list) do
    if c ~= "" and not seen[c] then
      seen[c] = true
      out[#out + 1] = c
    end
  end
  return out
end

--- The qualified chain around the cursor via treesitter, or nil.
--- @param bufnr integer
--- @param row integer 0-based
--- @param col integer 0-based
--- @return string|nil chain
function M.ts_chain(bufnr, row, col)
  local lang_ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not lang_ok or not parser then
    return nil
  end
  -- headless (and a freshly opened buffer) has no tree yet
  pcall(parser.parse, parser, { row, row })
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col }, ignore_injections = false })
  if not ok or not node then
    return nil
  end
  local lang = parser:language_for_range({ row, col, row, col }):lang()
  local chain_types = CHAIN_NODES[lang]
  if not chain_types then
    return nil
  end
  local top = nil
  local cur = node
  while cur do
    if chain_types[cur:type()] then
      top = cur
    elseif top then
      break
    end
    cur = cur:parent()
  end
  if not top then
    return nil
  end
  local text = vim.treesitter.get_node_text(top, bufnr)
  -- keep only the name part: drop call arguments, template args, index brackets
  text = text:gsub("%b()", ""):gsub("%b<>", ""):gsub("%b[]", "")
  text = text:match "^[%w_%.:%->@$]+" or text
  return text ~= "" and text or nil
end

--- The CSS-ish token under the cursor: letters, digits, "-", ":" and "@".
local function css_word(line, col)
  local s, e = col + 1, col + 1
  local function is(ch)
    return ch:match "[%w_%-:@]" ~= nil
  end
  if not line:sub(s, s):match "[%w_%-:@]" then
    return nil
  end
  while s > 1 and is(line:sub(s - 1, s - 1)) do
    s = s - 1
  end
  while e < #line and is(line:sub(e + 1, e + 1)) do
    e = e + 1
  end
  return (line:sub(s, e):gsub(":+$", ""))
end

--- Ordered lookup candidates for the cursor position.
--- @param bufnr integer|nil
--- @param opts { text?: string }|nil an explicit selection to use instead of the cursor
--- @return string[]
function M.candidates(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local ft = vim.bo[bufnr].filetype
  if opts.text and opts.text ~= "" then
    local t = vim.trim(opts.text)
    return dedupe(vim.list_extend({ t }, M.from_chain(t, nil, M.separator(ft))))
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    win = vim.fn.bufwinid(bufnr)
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local word = vim.fn.expand "<cword>"
  if word == "" or not line:find(word, 1, true) then
    word = nil
  end
  local sep = M.separator(ft)
  local chain = M.ts_chain(bufnr, row - 1, col)
  local cands = chain and M.from_chain(chain, word, sep) or (word and { word } or {})
  local rule = M.rules[ft]
  if rule then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(vim.api.nvim_buf_line_count(bufnr), 500), false)
    cands = rule(cands, { lines = lines, word = word or "", css_word = css_word(line, col) })
  end
  return dedupe(cands)
end

return M
