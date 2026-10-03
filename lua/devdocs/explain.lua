--- Explain: the "nothing to document" popup. Turns a classify.lua target into
--- one line of text ("42 is a number literal: nothing to document.") and shows
--- it in a small popup at the cursor (ui/float.lua note). Targets that still
--- deserve a doc lookup (keywords, plain builtins) have no message.
local M = {}

--- Longest subject (in characters) quoted in a message.
M.MAX_SUBJECT = 40

local LITERAL_LABELS = {
  string = "a string literal",
  number = "a number literal",
  boolean = "a boolean literal",
  nil_ = "a null literal",
  operator = "an operator",
  punctuation = "punctuation",
}

local NAME_LABELS = {
  ["local"] = "a local variable",
  variable = "a variable",
  parameter = "a parameter",
  field = "a field",
  ["function"] = "a function",
  type = "a type",
  macro = "a macro",
}

local NAME_CLASSES = { variable = true, symbol = true, unknown = true, library = true }

--- The first line of `text`, cut to MAX_SUBJECT characters; "…" marks a cut.
--- @param text string
--- @return string
function M.subject(text)
  local first = text:match "^[^\n]*"
  local cut = first ~= text
  if vim.fn.strchars(first) > M.MAX_SUBJECT then
    first = vim.fn.strcharpart(first, 0, M.MAX_SUBJECT - 1)
    cut = true
  end
  return cut and (first .. "…") or first
end

--- @param target DevDocsTarget
--- @return string|nil text, integer|nil subject_start, integer|nil subject_end (exclusive, bytes)
function M.message(target)
  local kind = target.kind or (target.class == "variable" and "variable" or nil)
  local literal = target.class == "trivial" or (target.class == "builtin" and (kind == "boolean" or kind == "nil"))
  if literal then
    if kind == "comment" then
      return "This is a comment: nothing to document."
    elseif kind == "whitespace" then
      return "Nothing under the cursor to look up."
    end
    local label = LITERAL_LABELS[kind == "nil" and "nil_" or kind]
    if not label then
      return nil
    end
    local sub = M.subject(target.word or "")
    if sub == "" then
      -- lookup.lua already chose the popup: say what it is rather than show nothing
      return ("This is %s: nothing to document."):format(label)
    end
    return ("%s is %s: nothing to document."):format(sub, label), 0, #sub
  end
  local label = NAME_CLASSES[target.class] and NAME_LABELS[kind or ""]
  local word = target.word or ""
  if not label or word == "" then
    return nil
  end
  if target.decl_line then
    return ("%s is %s (declared on line %d): no documentation."):format(word, label, target.decl_line), 0, #word
  end
  return ("%s is %s: no documentation."):format(word, label), 0, #word
end

--- Show the popup for `target`.
--- @param target DevDocsTarget
--- @return integer|nil win nil when the target has no message
function M.show(target)
  local msg, s, e = M.message(target)
  if not msg then
    return nil
  end
  local _, win = require("devdocs.ui.float").note({ msg }, { subject = s and { 0, s, e } or nil })
  return win
end

return M
