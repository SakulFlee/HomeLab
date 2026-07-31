-- ══════════════════════════════════════════════════════
-- Heirline Configuration (AstroNvim-style)
-- ══════════════════════════════════════════════════════
local conditions = require("heirline.conditions")
local utils = require("heirline.utils")

local colors = {
  section_bg   = utils.get_highlight("StatusLine").bg,
  bright_bg    = utils.get_highlight("Normal").bg,
  red          = utils.get_highlight("DiagnosticError").fg,
  green        = utils.get_highlight("String").fg,
  blue         = utils.get_highlight("Function").fg,
  gray         = utils.get_highlight("NonText").fg,
  orange       = utils.get_highlight("Constant").fg,
  purple       = utils.get_highlight("Statement").fg,
  cyan         = utils.get_highlight("Special").fg,
  darkgray     = utils.get_highlight("CursorLine").bg,
  lightgray    = utils.get_highlight("Visual").bg,
}

local Align = { provider = "%=" }
local Space = { provider = " " }
local Separator = { provider = " | ", hl = { fg = colors.gray } }

-- ── Mode indicator ────────────────────────────────────
local ViMode = {
  init = function(self)
    self.mode = vim.fn.mode(1)
  end,
  static = {
    mode_names = {
      n = "NORMAL", i = "INSERT", v = "VISUAL", V = "V-LINE",
      ["\22"] = "V-BLOCK", c = "COMMAND", s = "SELECT", S = "S-LINE",
      ["\19"] = "S-BLOCK", R = "REPLACE", r = "REPLACE",
      ["!"] = "SHELL", t = "TERMINAL",
    },
    mode_colors = {
      n = colors.blue, i = colors.green, v = colors.purple,
      V = colors.purple, ["\22"] = colors.purple, c = colors.orange,
      s = colors.purple, S = colors.purple, ["\19"] = colors.purple,
      R = colors.red, r = colors.red, ["!"] = colors.cyan,
      t = colors.cyan,
    },
  },
  provider = function(self)
    return " " .. (self.mode_names[self.mode] or self.mode) .. " "
  end,
  hl = function(self)
    return { fg = colors.bright_bg, bg = self.mode_colors[self.mode], bold = true }
  end,
  update = { "ModeChanged", pattern = "*:*" },
}

-- ── File name block ───────────────────────────────────
local FileNameBlock = {
  init = function(self)
    self.filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":~:.")
    if self.filename == "" then self.filename = "[No Name]" end
  end,
}
local FileName = {
  provider = function(self) return self.filename end,
  hl = { bold = true },
}
local FileFlags = {
  { provider = function() return vim.bo.modified and " [+]" or "" end,
    hl = { fg = colors.green } },
  { provider = function() return (not vim.bo.modifiable or vim.bo.readonly) and " [-]" or "" end,
    hl = { fg = colors.red } },
}
local FileNameModBlock = utils.insert(FileNameBlock, FileName, FileFlags)

-- ── Git branch ────────────────────────────────────────
local GitBranch = {
  condition = conditions.is_git_repo,
  init = function(self)
    local ok, gitsigns = pcall(require, "gitsigns")
    self.branch = (ok and gitsigns.get_head and gitsigns.get_head()) or ""
  end,
  provider = function(self)
    return self.branch ~= "" and (" " .. self.branch .. " ") or ""
  end,
  hl = { fg = colors.purple, bold = true },
}

-- ── Diagnostics ───────────────────────────────────────
local Diagnostics = {
  condition = conditions.has_diagnostics,
  init = function(self)
    self.errors = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.ERROR })
    self.warnings = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.WARN })
    self.hints = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.HINT })
    self.info = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.INFO })
  end,
  {
    provider = function(self) return self.errors > 0 and " " .. self.errors .. " " or "" end,
    hl = { fg = colors.red },
  },
  {
    provider = function(self) return self.warnings > 0 and " " .. self.warnings .. " " or "" end,
    hl = { fg = colors.orange },
  },
  {
    provider = function(self) return self.hints > 0 and " " .. self.hints .. " " or "" end,
    hl = { fg = colors.cyan },
  },
  {
    provider = function(self) return self.info > 0 and " " .. self.info .. " " or "" end,
    hl = { fg = colors.blue },
  },
}

-- ── LSP clients ───────────────────────────────────────
local LspClient = {
  condition = conditions.lsp_attached,
  init = function(self)
    local names = {}
    for _, client in pairs(vim.lsp.get_clients({ bufnr = 0 })) do
      table.insert(names, client.name)
    end
    self.clients = names
  end,
  provider = function(self) return " " .. table.concat(self.clients, " | ") .. " " end,
  hl = { fg = colors.cyan },
}

-- ── Filetype ──────────────────────────────────────────
local FileType = {
  provider = function() return " " .. vim.bo.filetype:upper() .. " " end,
  hl = { fg = colors.gray },
}

-- ── Ruler ─────────────────────────────────────────────
local Ruler = {
  provider = " %l:%c ",
}

-- ── Progress ──────────────────────────────────────────
local Progress = {
  provider = " %P ",
}

-- ── StatusLine ────────────────────────────────────────
local StatusLine = {
  ViMode, Space, FileNameModBlock, Space,
  Diagnostics, Align,
  GitBranch, Separator, LspClient, Separator, FileType, Align,
  Ruler, Progress,
}

-- ── WinBar ────────────────────────────────────────────
local Navic = {
  condition = function()
    local ok, aerial = pcall(require, "aerial")
    if not ok then return false end
    local bn = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bn) then return false end
    local ok2, loc = pcall(aerial.get_location, true)
    return ok2 and #loc > 0
  end,
  provider = function()
    local aerial = require("aerial")
    local symbols = aerial.get_location(true)
    if #symbols == 0 then return "" end
    local parts = {}
    for i, symbol in ipairs(symbols) do
      table.insert(parts, symbol.name)
    end
    return " " .. table.concat(parts, " > ") .. " "
  end,
  hl = { fg = colors.gray },
}

local WinBar = {
  condition = function()
    local bn = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bn) then return false end
    return not conditions.buffer_matches({
      buftype = { "nofile", "prompt", "help", "quickfix" },
      filetype = { "^git.*", "fugitive", "neo-tree", "dashboard" },
    })
  end,
  Align, Navic,
}

-- ── TabLine ───────────────────────────────────────────
local TabLineBufnr = {
  provider = function(self) return self.bufnr end,
  hl = { bold = true },
}
local TabLineFileName = {
  provider = function(self)
    local name = vim.fn.bufname(self.bufnr)
    name = vim.fn.fnamemodify(name, ":~:.")
    if name == "" then name = "[No Name]" end
    return name:sub(1, 20)
  end,
}
local TabLineClose = {
  provider = function(self) return self.is_active and " " or "" end,
  hl = { fg = colors.gray },
}
local TabLine = utils.make_tablist(function(self)
  local tabnr = self.tabnr
  local buflist = vim.fn.tabpagebuflist(tabnr)
  local winnr = vim.fn.tabpagewinnr(tabnr)
  self.bufnr = buflist[winnr]
  self.is_active = vim.fn.tabpagenr() == tabnr
  return {
    Space, TabLineBufnr, Space, TabLineFileName, TabLineClose,
    hl = self.is_active
      and { fg = colors.bright_bg, bg = colors.darkgray, bold = true }
      or { fg = colors.gray },
  }
end)

require("heirline").setup({
  statusline = StatusLine,
  winbar = WinBar,
  tabline = TabLine,
  opts = {
    disable_winbar_cb = function(args)
      if not vim.api.nvim_buf_is_valid(args.buf) then return true end
      return conditions.buffer_matches({
        buftype = { "nofile", "prompt", "help", "quickfix" },
        filetype = { "^git.*", "fugitive", "neo-tree", "dashboard" },
      }, args.buf)
    end,
  },
})
