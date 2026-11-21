--- Float: the one module that opens devdocs windows. A scratch buffer in a
--- centered float (or a split / tab per view.mode), sized from the editor,
--- re-laid-out on VimResized, with a title, a footer and buffer-local keys.
--- Floats, notes and the blocking menu come from popup.nvim (popup.float,
--- popup.geometry, popup.confirm); split and tab modes are ours.
--- Highlight groups are `default = true` links, re-applied on every open
--- because NvChad's base46 switches themes without a ColorScheme autocmd.
local config = require "devdocs.config"
local geometry = require "popup.geometry"
local highlights = require "popup.highlights"
local hints = require "devdocs.ui.hints"
local popup_confirm = require "popup.confirm"
local popup_float = require "popup.float"

local M = {}

M.NS = vim.api.nvim_create_namespace "devdocs_float"

--- Highlight `spans` ({ row (1-based), col_start, col_end (byte columns),
--- hl }) in a buffer, in namespace `ns`.
--- @param buf integer
--- @param ns integer
--- @param spans table[]
function M.highlight(buf, ns, spans)
  for _, s in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, s.row - 1, s.col_start, { end_col = s.col_end, hl_group = s.hl })
  end
end

M.HIGHLIGHTS = {
  DevDocsNormal = "NormalFloat",
  DevDocsBorder = "FloatBorder",
  DevDocsTitle = "FloatTitle",
  DevDocsFooter = "Comment",
  DevDocsHeader = "Title",
  DevDocsDim = "Comment",
  DevDocsMatch = "Search",
  DevDocsInstalled = "DiagnosticOk",
  DevDocsOutdated = "DiagnosticWarn",
  DevDocsError = "DiagnosticError",
  DevDocsProgress = "DiagnosticInfo",
  -- keys in hint lines / footers / help (actions use DevDocsDim): teal in
  -- NvChad's starlight (#13C299), cyan in Neovim's default scheme (#8cf8f7);
  -- Special, the old link, is red in starlight
  DevDocsKey = "@type.builtin",
  DevDocsLink = "Underlined",
  -- column headers of the help tables: neovim has no Bold group
  DevDocsHelpHeader = { bold = true },
  DevDocsMark = "DiagnosticHint",
  DevDocsCost = "DiagnosticError",
  DevDocsFreed = "DiagnosticOk",
  -- the small "nothing to document" popup at the cursor (M.note)
  DevDocsNote = "NormalFloat",
  DevDocsNoteSubject = "Identifier",
}

local WINHL = highlights.winhl {
  { "NormalFloat", "DevDocsNormal" },
  { "FloatBorder", "DevDocsBorder" },
  { "FloatTitle", "DevDocsTitle" },
  { "FloatFooter", "DevDocsFooter" },
}

function M.apply_highlights()
  highlights.define(M.HIGHLIGHTS)
end

--- A small non-focusable popup at the cursor. `opts.subject` =
--- { row, start_col, end_col } (0-based, byte) is highlighted as
--- DevDocsNoteSubject.
--- @param lines string[]
--- @param opts { subject?: integer[] }|nil
--- @return integer buf, integer win
function M.note(lines, opts)
  M.apply_highlights()
  return popup_float.note(lines, {
    subject = opts and opts.subject or nil,
    subject_hl = "DevDocsNoteSubject",
    border = M.border(),
    winhl = "NormalFloat:DevDocsNote,FloatBorder:DevDocsBorder",
    focus_id = "devdocs_note",
    max_width = 80,
  })
end

--- @return string|table
function M.border()
  local cfg = config.get().view
  if cfg.border ~= nil then
    return cfg.border
  end
  local wb = vim.o.winborder
  if wb == nil or wb == "" then
    return "rounded"
  end
  return wb
end

--- @class DevDocsFloatOpts
--- @field lines string[]
--- @field title string|nil
--- @field footer string|DevDocsHint[]|nil plain text, or key hints (keys in DevDocsKey)
--- @field spans table[]|nil highlights { row, col_start, col_end, hl } for `lines`
--- @field filetype string|nil
--- @field width number|nil
--- @field height number|nil
--- @field mode "float"|"split"|"vsplit"|"tab"|nil
--- @field keys table<string, fun()>|nil buffer-local normal-mode keys
--- @field on_close fun()|nil
--- @field name string|nil buffer name, e.g. "devdocs://css/properties/grid"
--- @field wrap boolean|nil
--- @field conceal boolean|nil

--- @class DevDocsFloat
--- @field buf integer
--- @field win integer
--- @field set_lines fun(self: DevDocsFloat, lines: string[])
--- @field set_title fun(self: DevDocsFloat, title: string|nil, footer: string|DevDocsHint[]|nil)
--- @field close fun(self: DevDocsFloat)
--- @field valid fun(self: DevDocsFloat): boolean

--- @param opts DevDocsFloatOpts
--- @return DevDocsFloat
function M.open(opts)
  M.apply_highlights()
  local cfg = config.get().view
  local mode = opts.mode or cfg.mode
  local self = { title = opts.title, footer = opts.footer, mode = mode }

  --- Rectangle, title and footer for the float at the current editor size.
  local function frame()
    local rect = geometry.fractional(geometry.env(), opts.width or cfg.width, opts.height or cfg.height)
    local title
    if self.title and self.title ~= "" then
      title = " " .. geometry.fit(self.title, rect.width - 4) .. " "
    end
    local footer
    if type(self.footer) == "table" and #self.footer > 0 then
      footer = hints.chunks(self.footer, rect.width - 2)
    elseif type(self.footer) == "string" and self.footer ~= "" then
      footer = " " .. geometry.fit(self.footer, rect.width - 4) .. " "
    end
    return rect, title, footer
  end

  local paint = { base = 1, safe = true }
  local pf
  if mode == "float" then
    local rect, title, footer = frame()
    pf = popup_float.open {
      rect = rect,
      title = title,
      footer = footer,
      footer_pos = "center",
      border = M.border(),
      zindex = 50,
      winhl = WINHL,
      ns = M.NS,
      lines = opts.lines or {},
      spans = opts.spans,
      paint = paint,
    }
  else
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    if mode == "tab" then
      vim.cmd "tabnew"
    elseif mode == "vsplit" then
      vim.cmd "vsplit"
    else
      vim.cmd "split"
    end
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    pf = { buf = buf, win = win, ns = M.NS }
    popup_float.paint(pf, { lines = opts.lines or {}, spans = opts.spans }, paint)
  end
  local buf, win = pf.buf, pf.win
  self.buf, self.win = buf, win
  if opts.name then
    pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  end

  vim.wo[win].wrap = opts.wrap ~= false and cfg.wrap or false
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].foldenable = false
  vim.wo[win].spell = false
  if opts.conceal ~= false and cfg.conceal then
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "nc"
  end

  function self:valid()
    return popup_float.is_open(pf)
  end

  function self:set_lines(lines)
    popup_float.paint(pf, { lines = lines }, paint)
  end

  local function reconfigure()
    local rect, title, footer = frame()
    popup_float.configure(pf, rect, title, footer, { footer_pos = "center" })
  end

  function self:set_title(title, footer)
    self.title, self.footer = title, footer
    if self.mode == "float" and self:valid() then
      reconfigure()
    end
  end

  function self:close()
    if self.win and vim.api.nvim_win_is_valid(self.win) then
      if self.mode == "tab" then
        pcall(vim.cmd, "tabclose")
      else
        pcall(vim.api.nvim_win_close, self.win, true)
      end
    end
  end

  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
    pcall(vim.treesitter.start, buf, opts.filetype)
  end

  for lhs, fn in pairs(opts.keys or {}) do
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  local group = vim.api.nvim_create_augroup("devdocs_float_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      if opts.on_close then
        pcall(opts.on_close)
      end
    end,
  })
  if mode == "float" then
    popup_float.on_resize(pf, reconfigure)
  end
  return self
end

--- A modal yes/no menu in a centered float (popup.confirm.choose): shows
--- `opts.lines` (with `opts.spans` highlighted), then reads keys until one of
--- them answers. y / <CR> say yes, n / q / <Esc> say no, j / k / <C-d> / <C-u>
--- scroll a tall menu. Blocks, so a BufWriteCmd can ask before it returns.
---
--- choose opens its window and starts reading keys in one call, so the
--- devdocs look (border, highlight groups, window options) is applied from a
--- vim.schedule callback that runs while it waits for the first key.
--- @param opts { lines: string[], spans: table[]|nil, title: string|nil, width: integer|nil }
--- @return boolean
function M.choose(opts)
  M.apply_highlights()
  local before = vim.api.nvim_get_current_win()
  vim.schedule(function()
    local win = vim.api.nvim_get_current_win()
    if win == before or vim.api.nvim_win_get_config(win).relative == "" then
      return
    end
    pcall(vim.api.nvim_win_set_config, win, { border = M.border() })
    vim.wo[win].winhighlight = WINHL
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldenable = false
  end)
  return popup_confirm.choose(opts)
end

--- A yes/no confirmation that names what will happen.
--- @param msg string
--- @return boolean
function M.confirm(msg)
  return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
end

return M
