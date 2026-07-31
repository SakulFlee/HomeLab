-- ══════════════════════════════════════════════════════
-- Keymaps
-- ══════════════════════════════════════════════════════
local map = vim.keymap.set

-- ── Window navigation (smart-splits) ──────────────────
local ss_ok, smart_splits = pcall(require, "smart-splits")
if ss_ok then
  -- hjkl navigation
  map("n", "<C-h>", smart_splits.move_cursor_left,  { desc = "Move to left split" })
  map("n", "<C-j>", smart_splits.move_cursor_down,  { desc = "Move to below split" })
  map("n", "<C-k>", smart_splits.move_cursor_up,    { desc = "Move to above split" })
  map("n", "<C-l>", smart_splits.move_cursor_right, { desc = "Move to right split" })
  -- Ctrl+Arrow alternatives
  map("n", "<C-Left>",  smart_splits.move_cursor_left,  { desc = "Move to left split" })
  map("n", "<C-Down>",  smart_splits.move_cursor_down,  { desc = "Move to below split" })
  map("n", "<C-Up>",    smart_splits.move_cursor_up,    { desc = "Move to above split" })
  map("n", "<C-Right>", smart_splits.move_cursor_right, { desc = "Move to right split" })
  -- Resize splits (Ctrl+Shift+Arrow)
  map("n", "<C-S-Left>",  smart_splits.resize_left,  { desc = "Resize split left" })
  map("n", "<C-S-Down>",  smart_splits.resize_down,  { desc = "Resize split down" })
  map("n", "<C-S-Up>",    smart_splits.resize_up,    { desc = "Resize split up" })
  map("n", "<C-S-Right>", smart_splits.resize_right, { desc = "Resize split right" })
  -- Resize splits (Ctrl+Shift+HJKL alternative)
  map("n", "<C-S-h>", smart_splits.resize_left,  { desc = "Resize split left" })
  map("n", "<C-S-j>", smart_splits.resize_down,  { desc = "Resize split down" })
  map("n", "<C-S-k>", smart_splits.resize_up,    { desc = "Resize split up" })
  map("n", "<C-S-l>", smart_splits.resize_right, { desc = "Resize split right" })
end

-- ── Window splits ─────────────────────────────────────
map("n", "\\", "<cmd>split<cr>", { desc = "Horizontal split" })
map("n", "|", "<cmd>vsplit<cr>", { desc = "Vertical split" })

-- ── Buffer navigation ─────────────────────────────────
map("n", "]b", "<cmd>bnext<cr>", { desc = "Next buffer" })
map("n", "[b", "<cmd>bprevious<cr>", { desc = "Previous buffer" })
map("n", ">b", "<cmd>bmove +1<cr>", { desc = "Move buffer right" })
map("n", "<b", "<cmd>bmove -1<cr>", { desc = "Move buffer left" })
map("n", "<leader>bc", "<cmd>%bdelete|edit#|bdelete#<cr>", { desc = "Close all other buffers" })
map("n", "<leader>bd", function() Snacks.bufdelete() end, { desc = "Delete buffer" })
map("n", "<leader>bn", "<cmd>enew<cr>", { desc = "New buffer" })

-- ── Window management ─────────────────────────────────
map("n", "<C-s>", "<cmd>w<cr>", { desc = "Force write" })
map("n", "<C-q>", "<cmd>q<cr>", { desc = "Force quit" })
map("n", "<leader>q", "<cmd>q<cr>", { desc = "Quit" })

-- ── LSP keymaps ───────────────────────────────────────
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("UserLspConfig", { clear = true }),
  callback = function(ev)
    local opts_buf = function(desc)
      return { buffer = ev.buf, desc = desc }
    end

    map("n", "K", vim.lsp.buf.hover, opts_buf("Hover document"))
    map("n", "gd", vim.lsp.buf.definition, opts_buf("Go to definition"))
    map("n", "gD", vim.lsp.buf.declaration, opts_buf("Go to declaration"))
    map("n", "gy", vim.lsp.buf.type_definition, opts_buf("Go to type definition"))
    map("n", "gri", vim.lsp.buf.implementation, opts_buf("Go to implementation"))
    map("n", "grr", vim.lsp.buf.references, opts_buf("References"))
    map("n", "gra", vim.lsp.buf.code_action, opts_buf("Code action"))
    map("n", "grn", vim.lsp.buf.rename, opts_buf("Rename"))
    map("n", "gO", vim.lsp.buf.document_symbol, opts_buf("Document symbols"))

    map("n", "<leader>lf", vim.lsp.buf.format, opts_buf("Format document"))
    map("n", "<leader>lh", vim.lsp.buf.signature_help, opts_buf("Signature help"))
    map("n", "<leader>lw", vim.lsp.buf.workspace_symbol, opts_buf("Workspace symbols"))
    map("n", "<leader>lS", "<cmd>AerialToggle!<cr>", opts_buf("Symbols outline"))

    map("n", "<leader>lD", vim.diagnostic.setloclist, opts_buf("Workspace diagnostics"))
    map("n", "]d", function() vim.diagnostic.jump({ count = 1 }) end, opts_buf("Next diagnostic"))
    map("n", "[d", function() vim.diagnostic.jump({ count = -1 }) end, opts_buf("Previous diagnostic"))
    map("n", "]e", function() vim.diagnostic.jump({ count = 1, severity = vim.diagnostic.severity.ERROR }) end, opts_buf("Next error"))
    map("n", "[e", function() vim.diagnostic.jump({ count = -1, severity = vim.diagnostic.severity.ERROR }) end, opts_buf("Previous error"))
    map("n", "]w", function() vim.diagnostic.jump({ count = 1, severity = vim.diagnostic.severity.WARN }) end, opts_buf("Next warning"))
    map("n", "[w", function() vim.diagnostic.jump({ count = -1, severity = vim.diagnostic.severity.WARN }) end, opts_buf("Previous warning"))
  end,
})

-- ── DAP keymaps ───────────────────────────────────────
local dap_ok, dap = pcall(require, "dap")
if dap_ok then
  map("n", "<leader>dc", dap.continue, { desc = "Continue" })
  map("n", "<leader>dp", dap.pause, { desc = "Pause" })
  map("n", "<leader>dr", dap.restart, { desc = "Restart" })
  map("n", "<leader>ds", dap.run_to_cursor, { desc = "Run to cursor" })
  map("n", "<leader>dq", dap.terminate, { desc = "Terminate" })
  map("n", "<leader>dQ", dap.terminate, { desc = "Terminate" })
  map("n", "<leader>db", dap.toggle_breakpoint, { desc = "Toggle breakpoint" })
  map("n", "<leader>dC", function()
    dap.set_breakpoint(vim.fn.input("Condition: "))
  end, { desc = "Conditional breakpoint" })
  map("n", "<leader>dB", dap.clear_breakpoints, { desc = "Clear breakpoints" })
  map("n", "<leader>do", dap.step_over, { desc = "Step over" })
  map("n", "<leader>di", dap.step_into, { desc = "Step into" })
  map("n", "<leader>dO", dap.step_out, { desc = "Step out" })
  map("n", "<leader>dh", function()
    dap.repl.open({ bufnr = 0 }, "hover")
  end, { desc = "Hover" })
  map("n", "<leader>de", function()
    dap.eval()
  end, { desc = "Evaluate expression" })
  map("n", "<leader>du", function()
    require("dapui").toggle()
  end, { desc = "Toggle DAP UI" })
  map("n", "<F5>", dap.continue, { desc = "Continue" })
  map("n", "<F6>", dap.pause, { desc = "Pause" })
  map("n", "<F9>", dap.toggle_breakpoint, { desc = "Toggle breakpoint" })
  map("n", "<F10>", dap.step_over, { desc = "Step over" })
  map("n", "<F11>", dap.step_into, { desc = "Step into" })
  map("n", "<S-F11>", dap.step_out, { desc = "Step out" })
  map("n", "<S-F5>", dap.terminate, { desc = "Terminate" })
  map("n", "<S-F9>", function()
    dap.set_breakpoint(vim.fn.input("Condition: "))
  end, { desc = "Conditional breakpoint" })
end

-- ── Terminal keymaps ──────────────────────────────────
map("n", "<leader>tf", function() Snacks.terminal(nil, { win = { position = "float" } }) end, { desc = "Floating terminal" })
map("n", "<leader>th", function() Snacks.terminal(nil, { win = { position = "bottom", height = 0.3 } }) end, { desc = "Horizontal terminal" })
map("n", "<leader>tv", function() Snacks.terminal(nil, { win = { position = "right", width = 0.4 } }) end, { desc = "Vertical terminal" })
map("n", "<leader>tl", function() Snacks.lazygit() end, { desc = "Lazygit" })
map({ "n", "t" }, "<F7>", function() Snacks.terminal.toggle() end, { desc = "Toggle terminal" })

-- ── UI Toggle keymaps (AstroNvim-style) ──────────────
map("n", "<leader>uw", function()
  vim.wo.wrap = not vim.wo.wrap
  Snacks.notify("Wrap: " .. (vim.wo.wrap and "ON" or "OFF"))
end, { desc = "Toggle wrap" })

map("n", "<leader>un", function()
  if vim.wo.relativenumber then
    vim.wo.relativenumber = false
    vim.wo.number = true
  elseif vim.wo.number then
    vim.wo.number = false
  else
    vim.wo.relativenumber = true
    vim.wo.number = true
  end
  local mode = vim.wo.relativenumber and "relative" or (vim.wo.number and "absolute" or "off")
  Snacks.notify("Line numbers: " .. mode)
end, { desc = "Toggle line numbers" })

map("n", "<leader>us", function()
  vim.wo.spell = not vim.wo.spell
  Snacks.notify("Spell: " .. (vim.wo.spell and "ON" or "OFF"))
end, { desc = "Toggle spellcheck" })

map("n", "<leader>u|", function()
  Snacks.toggle.indent()
end, { desc = "Toggle indent guides" })

map("n", "<leader>ug", function()
  if vim.wo.signcolumn == "yes" then
    vim.wo.signcolumn = "no"
  elseif vim.wo.signcolumn == "no" then
    vim.wo.signcolumn = "auto"
  else
    vim.wo.signcolumn = "yes"
  end
  Snacks.notify("Signcolumn: " .. vim.wo.signcolumn)
end, { desc = "Toggle signcolumn" })

map("n", "<leader>ud", function()
  if vim.diagnostic.is_enabled() then
    vim.diagnostic.enable(false)
    Snacks.notify("Diagnostics: OFF")
  else
    vim.diagnostic.enable(true)
    Snacks.notify("Diagnostics: ON")
  end
end, { desc = "Toggle diagnostics" })

-- ── Inlay hints ─────────────────────────────────────────
local inlay_hints_enabled = true
map("n", "<leader>uh", function()
  inlay_hints_enabled = not inlay_hints_enabled
  vim.lsp.inlay_hint.enable(inlay_hints_enabled)
  Snacks.notify(inlay_hints_enabled and "Inlay hints enabled" or "Inlay hints disabled")
end, { desc = "Toggle inlay hints" })

-- ── Picker keymaps (snacks.picker) ────────────────────
map("n", "<leader>ff", function() Snacks.picker.files() end, { desc = "Find files" })
map("n", "<leader>fb", function() Snacks.picker.buffers() end, { desc = "Buffers" })
map("n", "<leader>fw", function() Snacks.picker.grep() end, { desc = "Live grep" })
map("n", "<leader>fh", function() Snacks.picker.help() end, { desc = "Help tags" })
map("n", "<leader>fr", function() Snacks.picker.registers() end, { desc = "Registers" })
map("n", "<leader>fs", function() Snacks.picker.smart() end, { desc = "Smart find" })
map("n", "<leader>fg", function() Snacks.picker.git_files() end, { desc = "Git files" })
map("n", "<leader>fc", function() Snacks.picker.grep_word() end, { desc = "Grep word at cursor" })
map("n", "<leader>fn", function() Snacks.picker.notifications() end, { desc = "Notification history" })
map("n", "<leader>fC", function() Snacks.picker.commands() end, { desc = "Commands" })
map("n", "<leader>fm", function() Snacks.picker.man() end, { desc = "Man pages" })
map("n", "<leader>fk", function() Snacks.picker.keymaps() end, { desc = "Keymaps" })
map("n", "<leader>ft", function() Snacks.picker.colorschemes() end, { desc = "Colorschemes" })
map("n", "<leader>fd", function() Snacks.picker.diagnostics() end, { desc = "Diagnostics" })
map("n", "<leader>fo", function() Snacks.picker.recent() end, { desc = "Recent files" })
-- ── Explorer / Outline ────────────────────────────────
map("n", "<leader>e", "<cmd>Neotree toggle<cr>", { desc = "File explorer" })
map("n", "<leader>uo", "<cmd>Neotree source=document_symbols<cr>", { desc = "Symbols outline" })

-- ── Session keymaps (auto-session) ────────────────────
local gs_ok, gs = pcall(require, "auto-session")
if gs_ok then
  map("n", "<leader>SS", gs.SaveSession,    { desc = "Save session" })
  map("n", "<leader>SL", gs.RestoreSession, { desc = "Restore session" })
  map("n", "<leader>SD", gs.DeleteSession,  { desc = "Delete session" })
end

-- ── Git keymaps ───────────────────────────────────────
map("n", "<leader>gg", function() Snacks.lazygit() end, { desc = "Lazygit" })
map("n", "<leader>go", function()
  Snacks.picker.git_status()
end, { desc = "Git status" })
map("n", "<leader>gc", function()
  Snacks.picker.git_log()
end, { desc = "Git commits" })
map("n", "<leader>gb", function()
  Snacks.picker.git_branches()
end, { desc = "Git branches" })
local gs_ok, gitsigns = pcall(require, "gitsigns")
if gs_ok then
  map("n", "<leader>gB", gitsigns.blame_line, { desc = "Git blame" })
end

-- ── Quickfix / Location list ──────────────────────────
map("n", "<leader>xq", "<cmd>copen<cr>", { desc = "Open quickfix list" })
map("n", "<leader>xl", "<cmd>lopen<cr>", { desc = "Open location list" })
map("n", "]q", "<cmd>cnext<cr>", { desc = "Next quickfix" })
map("n", "[q", "<cmd>cprevious<cr>", { desc = "Previous quickfix" })

-- ── Markdown preview ──────────────────────────────────
map("n", "<leader>mp", "<cmd>MarkdownPreviewToggle<cr>",
  { desc = "Markdown preview" })

-- ── Treesitter textobjects ────────────────────────────
local ts_to = function(query)
  return function()
    require("nvim-treesitter-textobjects.select").select_textobject("@" .. query, "textobjects")
  end
end

map({ "x", "o" }, "af", ts_to("function.outer"), { desc = "outer function" })
map({ "x", "o" }, "if", ts_to("function.inner"), { desc = "inner function" })
map({ "x", "o" }, "ac", ts_to("class.outer"), { desc = "outer class" })
map({ "x", "o" }, "ic", ts_to("class.inner"), { desc = "inner class" })
map({ "x", "o" }, "aa", ts_to("parameter.outer"), { desc = "outer parameter" })
map({ "x", "o" }, "ia", ts_to("parameter.inner"), { desc = "inner parameter" })
map({ "x", "o" }, "al", ts_to("loop.outer"), { desc = "outer loop" })
map({ "x", "o" }, "il", ts_to("loop.inner"), { desc = "inner loop" })

-- ── Notifications ──────────────────────────────────────
map("n", "<leader>uD", function() Snacks.notifier.hide() end, { desc = "Dismiss notifications" })
map("n", "<leader>n", function() Snacks.picker.notifications() end, { desc = "Notification history" })

-- ── Rust (rustaceanvim) keymaps ────────────────────────
local rust_ok, rustaceanvim = pcall(require, "rustaceanvim")
if rust_ok then
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "rust",
    callback = function()
      local rb = vim.api.nvim_get_current_buf()
      local ro = function(desc)
        return { buffer = rb, desc = desc, noremap = true, silent = true }
      end

      map("n", "<leader>lM", function() vim.cmd("RustExpandMacro") end, ro("Expand macro"))
      map("n", "<leader>lH", function() vim.cmd("RustHoverActions") end, ro("Hover actions"))
      map("n", "<leader>lW", function() vim.cmd("RustReloadWorkspace") end, ro("Reload workspace"))
      map("n", "<leader>lt", function() require("rustaceanvim.runnables").run() end, ro("Run nearest target"))
      map("n", "<leader>lT", function() vim.cmd("RustLsp runnables") end, ro("All targets (picker)"))
      map("n", "<leader>lC", function() vim.cmd("RustOpenCargo") end, ro("Open Cargo.toml"))
      map("n", "<leader>lP", function() vim.cmd("RustParentModule") end, ro("Parent module"))
    end,
  })
end

-- ══════════════════════════════════════════════════════
-- Which-Key Groups
-- ══════════════════════════════════════════════════════
local wk_ok, wk = pcall(require, "which-key")
if wk_ok then
  wk.add({
    { "<leader>f",  group = "Find" },
    { "<leader>b",  group = "Buffer" },
    { "<leader>d",  group = "Debug" },
    { "<leader>l",  group = "LSP" },
    { "<leader>t",  group = "Terminal" },
    { "<leader>S",  group = "Session" },
    { "<leader>g",  group = "Git" },
    { "<leader>x",  group = "List" },
    { "<leader>o",  group = "Opencode" },
    { "<leader>og", desc = "Toggle Opencode" },
    { "<leader>oi", desc = "Open input" },
    { "<leader>oI", desc = "Open input (new session)" },
    { "<leader>oo", desc = "Open output" },
    { "<leader>os", desc = "Select session" },
    { "<leader>oq", desc = "Close Opencode" },
    { "<leader>op", desc = "Configure provider" },
    { "<leader>c",  group = "Code" },
    { "<leader>.",  group = "Suggest" },
    { "<leader>h",  group = "Dashboard" },
    { "<leader>m",  group = "Markdown" },

    { "<leader>u",  group = "UI Toggle" },
    { "<leader>e",  group = "Explorer" },
    { "<leader>uo", group = "Outline" },
  })
end
