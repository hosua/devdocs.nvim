--- Float: the one module that opens windows. A scratch buffer in a
--- centered float (or a split / tab per view.mode), sized from the editor,
--- re-laid-out on VimResized, with a title, a footer and buffer-local keys.
--- Highlight groups are `default = true` links, re-applied on every open
--- because NvChad's base46 switches themes without a ColorScheme autocmd.
local config = require "devdocs.config"

local M = {}

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
  DevDocsKey = "Special",
  DevDocsLink = "Underlined",
  DevDocsMark = "DiagnosticHint",
}

function M.apply_highlights()
  for name, target in pairs(M.HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
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

--- Size and position of a centered float.
--- @param width number fraction (<= 1) or columns
--- @param height number fraction (<= 1) or rows
--- @return { width: integer, height: integer, row: integer, col: integer }
function M.layout(width, height)
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  local w = width <= 1 and math.floor(cols * width) or width
  local h = height <= 1 and math.floor(lines * height) or height
  w = math.max(20, math.min(w, cols - 2))
  h = math.max(5, math.min(h, lines - 2))
  return { width = w, height = h, row = math.floor((lines - h) / 2), col = math.floor((cols - w) / 2) }
end

--- Fit a title/footer string into a width, truncating the middle.
--- @param s string
--- @param width integer
--- @return string
function M.fit(s, width)
  local w = vim.fn.strdisplaywidth(s)
  if w <= width then
    return s
  end
  local keep = math.max(0, math.floor((width - 1) / 2))
  return vim.fn.strcharpart(s, 0, keep) .. "…" .. vim.fn.strcharpart(s, vim.fn.strchars(s) - keep, keep)
end

--- @class DevDocsFloatOpts
--- @field lines string[]
--- @field title string|nil
--- @field footer string|nil
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
--- @field set_title fun(self: DevDocsFloat, title: string|nil, footer: string|nil)
--- @field close fun(self: DevDocsFloat)
--- @field valid fun(self: DevDocsFloat): boolean

--- @param opts DevDocsFloatOpts
--- @return DevDocsFloat
function M.open(opts)
  M.apply_highlights()
  local cfg = config.get().view
  local mode = opts.mode or cfg.mode
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  if opts.name then
    pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  end

  local self = { buf = buf, title = opts.title, footer = opts.footer, mode = mode }

  local function win_config()
    local l = M.layout(opts.width or cfg.width, opts.height or cfg.height)
    local wc = {
      relative = "editor",
      width = l.width,
      height = l.height,
      row = l.row,
      col = l.col,
      style = "minimal",
      border = M.border(),
      zindex = 50,
    }
    if self.title and self.title ~= "" then
      wc.title = " " .. M.fit(self.title, l.width - 4) .. " "
      wc.title_pos = "center"
    end
    if self.footer and self.footer ~= "" then
      wc.footer = " " .. M.fit(self.footer, l.width - 4) .. " "
      wc.footer_pos = "center"
    end
    return wc
  end

  local win
  if mode == "float" then
    win = vim.api.nvim_open_win(buf, true, win_config())
    vim.wo[win].winhighlight =
      "NormalFloat:DevDocsNormal,FloatBorder:DevDocsBorder,FloatTitle:DevDocsTitle,FloatFooter:DevDocsFooter"
  else
    if mode == "tab" then
      vim.cmd "tabnew"
    elseif mode == "vsplit" then
      vim.cmd "vsplit"
    else
      vim.cmd "split"
    end
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  self.win = win

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
    return self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_buf_is_valid(self.buf)
  end

  function self:set_lines(lines)
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false
    vim.bo[self.buf].modified = false
  end

  function self:set_title(title, footer)
    self.title, self.footer = title, footer
    if self.mode == "float" and self:valid() then
      vim.api.nvim_win_set_config(self.win, win_config())
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

  self:set_lines(opts.lines or {})
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
    pcall(vim.treesitter.start, buf, opts.filetype)
  end

  for lhs, fn in pairs(opts.keys or {}) do
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  local group = vim.api.nvim_create_augroup("devdocs_float_" .. buf, { clear = true })
  if mode == "float" then
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      callback = function()
        if self:valid() then
          vim.api.nvim_win_set_config(self.win, win_config())
        end
      end,
    })
  end
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
  return self
end

--- A yes/no confirmation that names what will happen.
--- @param msg string
--- @return boolean
function M.confirm(msg)
  return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
end

return M
