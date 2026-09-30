--- Picker: choose between several lookup hits. Telescope when it is
--- installed (the config has it), vim.ui.select otherwise, so the plugin
--- works with zero dependencies.
local store = require "devdocs.store"

local M = {}

--- @param hit DevDocsHit
--- @return string
function M.label(hit)
  local meta = store.meta(hit.slug) or {}
  local doc = (meta.name or hit.slug)
    .. ((meta.doc_version and meta.doc_version ~= "") and (" " .. meta.doc_version) or "")
  local typ = hit.entry.type ~= "" and (" · " .. hit.entry.type) or ""
  return ("%s  [%s%s]"):format(hit.entry.name, doc, typ)
end

--- @return boolean
function M.has_telescope()
  return pcall(require, "telescope")
end

--- @param hits DevDocsHit[]
--- @param prompt string
--- @param on_choice fun(hit: DevDocsHit)
function M.pick_hits(hits, prompt, on_choice)
  if #hits == 0 then
    return
  end
  if not M.has_telescope() then
    vim.ui.select(hits, { prompt = prompt, format_item = M.label }, function(choice)
      if choice then
        on_choice(choice)
      end
    end)
    return
  end
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local previewers = require "telescope.previewers"
  local index = require "devdocs.index"

  pickers
    .new({}, {
      prompt_title = prompt,
      finder = finders.new_table {
        results = hits,
        entry_maker = function(hit)
          local label = M.label(hit)
          return { value = hit, display = label, ordinal = label }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = previewers.new_buffer_previewer {
        title = "DevDocs",
        define_preview = function(self, entry)
          local lines = index.section(entry.value.slug, entry.value.entry.path) or { "(missing page)" }
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "markdown"
        end,
      },
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(bufnr)
          if sel then
            on_choice(sel.value)
          end
        end)
        return true
      end,
    })
    :find()
end

--- Choose one of several strings (slugs, versions).
--- @param items string[]
--- @param prompt string
--- @param on_choice fun(item: string)
function M.pick_string(items, prompt, on_choice)
  vim.ui.select(items, { prompt = prompt }, function(choice)
    if choice then
      on_choice(choice)
    end
  end)
end

return M
