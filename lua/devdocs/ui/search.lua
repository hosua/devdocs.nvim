--- Search picker (telescope). Two modes, toggled with <C-t>:
---   grep     every keystroke reruns `rg --json` over the pages of the
---            requested docs (an async job telescope cancels and restarts),
---            results from the current buffer's docs first
---   entries  fuzzy over entry names, like the search box on devdocs.io
--- `@slug ` at the start of the prompt restricts either mode to one doc.
--- Without telescope, init.search() greps into the quickfix list instead.
local config = require "devdocs.config"
local detect = require "devdocs.detect"
local index = require "devdocs.index"
local paths = require "devdocs.paths"
local picker = require "devdocs.ui.picker"
local search = require "devdocs.search"
local store = require "devdocs.store"
local viewer = require "devdocs.ui.viewer"

local M = {}

--- Doc name shown in a result row.
local function doc_label(slug)
  local meta = store.meta(slug) or {}
  local v = meta.doc_version
  return (meta.name or slug) .. ((v and v ~= "") and (" " .. v) or "")
end

--- Slugs to search for the prompt: an @slug prefix, else the buffer order.
--- @param prompt string
--- @param order string[]
--- @return string[] slugs, string text
local function scope(prompt, order)
  local slug_filter, text = search.parse_query(prompt)
  if slug_filter then
    local matches = vim.tbl_filter(function(s)
      return s == slug_filter or vim.startswith(s, slug_filter)
    end, store.installed())
    return matches, text
  end
  return order, text
end

--- @param mode "grep"|"entries"
--- @param prompt string|nil
--- @param bufnr integer
function M.open_mode(mode, prompt, bufnr)
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local sorters = require "telescope.sorters"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local previewers = require "telescope.previewers"
  local cfg = config.get()
  local order = detect.lookup_order(bufnr)
  if #order == 0 then
    vim.notify("devdocs: no docs installed yet (:DevDocs install, :DevDocs list)", vim.log.levels.WARN)
    return
  end
  local priority = {}
  for i, s in ipairs(order) do
    priority[s] = i
  end

  local finder, sorter, title
  if mode == "grep" then
    title = "DevDocs grep  (<C-t> entry names, @doc to narrow)"
    finder = finders.new_async_job {
      command_generator = function(p)
        local slugs, text = scope(p or "", order)
        if text == "" or #slugs == 0 then
          return nil
        end
        local cmd = {
          cfg.search.rg,
          "--json",
          "--smart-case",
          "--fixed-strings",
          "--max-count",
          "3",
          "--max-columns",
          "240",
          "--max-columns-preview",
          "--no-messages",
          "-g",
          "*.md",
          "-e",
          text,
        }
        for _, s in ipairs(slugs) do
          if store.is_installed(s) then
            cmd[#cmd + 1] = paths.pages_dir(s)
          end
        end
        return cmd
      end,
      entry_maker = function(line)
        local ok, ev = pcall(vim.json.decode, line)
        if not ok or type(ev) ~= "table" or ev.type ~= "match" then
          return nil
        end
        local d = ev.data
        local file = d.path and d.path.text
        if not file then
          return nil
        end
        local slug, page = paths.page_from_file(file)
        if not slug or not page then
          return nil
        end
        local text = vim.trim((d.lines and d.lines.text or ""):gsub("\n", ""))
        local sub = d.submatches and d.submatches[1]
        local value = {
          slug = slug,
          page = page,
          line = d.line_number,
          col = sub and (sub.start + 1) or 1,
          text = text,
          priority = priority[slug] or #order + 1,
        }
        local display = ("[%s] %s: %s"):format(doc_label(slug), page, text)
        return { value = value, display = display, ordinal = display, filename = file, lnum = d.line_number }
      end,
    }
    -- rg already filtered the lines; order by doc priority only
    sorter = sorters.Sorter:new {
      scoring_function = function(_, _, _, entry)
        return entry.value.priority
      end,
    }
  else
    title = "DevDocs entries  (<C-t> grep, @doc to narrow)"
    finder = finders.new_dynamic {
      fn = function(p)
        local slugs, text = scope(p or "", order)
        if text == "" then
          -- empty prompt: list the buffer's own entries
          local out = {}
          for _, s in ipairs(vim.list_slice(slugs, 1, 1)) do
            for _, e in ipairs(store.entries(s)) do
              out[#out + 1] = { slug = s, entry = e, score = 0 }
              if #out >= 200 then
                break
              end
            end
          end
          return out
        end
        return search.entries(text, slugs, { limit = 100 })
      end,
      entry_maker = function(hit)
        local label = picker.label(hit)
        return {
          value = { slug = hit.slug, page = hit.entry.path, entry = hit.entry, priority = priority[hit.slug] or 99 },
          display = label,
          ordinal = label,
        }
      end,
    }
    sorter = sorters.Sorter:new {
      scoring_function = function(_, _, _, entry)
        -- search.entries() already ranked; keep its order
        return entry.index or 0
      end,
    }
  end

  local function open(value, view_mode)
    local v = {
      slug = value.slug,
      path = value.page,
      entry = value.entry or index.entry_for_path(value.slug, value.page),
      mode = value.entry and "section" or "page",
      line = value.line,
    }
    if view_mode then
      v.view_mode = view_mode
    end
    viewer.open(v)
  end

  pickers
    .new({}, {
      prompt_title = title,
      default_text = prompt,
      finder = finder,
      sorter = sorter,
      previewer = previewers.new_buffer_previewer {
        title = "DevDocs",
        define_preview = function(self, entry)
          local v = entry.value
          local lines = (v.entry and index.section(v.slug, v.entry.path))
            or index.page(v.slug, v.page)
            or { "(missing page)" }
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "markdown"
          if v.line and not v.entry then
            vim.schedule(function()
              if vim.api.nvim_win_is_valid(self.state.winid) then
                pcall(vim.api.nvim_win_set_cursor, self.state.winid, { v.line, 0 })
                vim.api.nvim_win_call(self.state.winid, function()
                  vim.cmd "normal! zz"
                end)
              end
            end)
          end
        end,
      },
      attach_mappings = function(prompt_bufnr, map)
        local function with_selection(fn)
          return function()
            local sel = action_state.get_selected_entry()
            if not sel then
              return
            end
            actions.close(prompt_bufnr)
            fn(sel.value)
          end
        end
        actions.select_default:replace(with_selection(function(v)
          open(v)
        end))
        actions.select_horizontal:replace(with_selection(function(v)
          open(v, "split")
        end))
        actions.select_vertical:replace(with_selection(function(v)
          open(v, "vsplit")
        end))
        actions.select_tab:replace(with_selection(function(v)
          open(v, "tab")
        end))
        map(
          { "i", "n" },
          "<C-o>",
          with_selection(function(v)
            pcall(vim.ui.open, paths.browser_url(v.slug, v.page))
          end)
        )
        map({ "i", "n" }, "<C-y>", function()
          local sel = action_state.get_selected_entry()
          if sel then
            local url = paths.browser_url(sel.value.slug, sel.value.page)
            vim.fn.setreg("+", url)
            vim.notify("devdocs: yanked " .. url)
          end
        end)
        map({ "i", "n" }, "<C-t>", function()
          local text = action_state.get_current_line()
          actions.close(prompt_bufnr)
          vim.schedule(function()
            M.open_mode(mode == "grep" and "entries" or "grep", text, bufnr)
          end)
        end)
        return true
      end,
    })
    :find()
end

--- @param prompt string|nil initial text ("@css grid", "map")
function M.open(prompt)
  if not picker.has_telescope() then
    vim.notify(
      "devdocs: telescope.nvim is not installed; :DevDocs search <query> greps into the quickfix list",
      vim.log.levels.WARN
    )
    return
  end
  M.open_mode("grep", prompt, vim.api.nvim_get_current_buf())
end

return M
