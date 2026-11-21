--- Key hints: popup.hints with devdocs colors. The logic lives in popup.nvim;
--- this binds the highlight groups once so call sites keep passing just
--- width, prefix and sep. Keys are DevDocsKey, actions DevDocsDim, help table
--- headers DevDocsHelpHeader, help titles DevDocsHeader.
local popup_hints = require "popup.hints"

local M = {}

M.SEP = popup_hints.SEP

local HL = {
  key_hl = "DevDocsKey",
  action_hl = "DevDocsDim",
  header_hl = "DevDocsHelpHeader",
  title_hl = "DevDocsHeader",
}

local function bind(opts)
  return vim.tbl_extend("force", HL, opts or {})
end

--- @alias DevDocsHint { [1]: string, [2]: string, keep?: boolean } key, action; keep: never dropped from a narrow footer

M.text = popup_hints.text
M.wrap = popup_hints.wrap

function M.line(hints, opts)
  return popup_hints.line(hints, bind(opts))
end

function M.chunks(hints, width, opts)
  return popup_hints.chunks(hints, width, bind(opts))
end

function M.table(tbl, opts)
  return popup_hints.table(tbl, bind(opts))
end

function M.help(blocks, opts)
  return popup_hints.help(blocks, bind(opts))
end

return M
