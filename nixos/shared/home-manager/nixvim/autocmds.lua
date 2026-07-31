-- ══════════════════════════════════════════════════════
-- Open Dashboard on Startup (only when no files opened)
-- ══════════════════════════════════════════════════════
vim.api.nvim_create_autocmd("VimEnter", {
  nested = true,
  callback = function()
    if vim.fn.argc() == 0 then
      vim.schedule(function()
        local has_file = false
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_option(buf, "buftype") == ""
            and vim.api.nvim_buf_get_name(buf) ~= "" then
            has_file = true
            break
          end
        end
        if not has_file then
          Snacks.dashboard()
        end
      end)
    end
  end,
})

-- ══════════════════════════════════════════════════════
-- LSP Code Lenses (e.g. "Run Test", "Run", "Debug" annotations)
-- ══════════════════════════════════════════════════════
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("LspCodeLens", { clear = true }),
  callback = function(ev)
    local bufnr = ev.buf
    vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
    vim.lsp.codelens.refresh()
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
      buffer = bufnr,
      group = vim.api.nvim_create_augroup("LspCodeLensRefresh_" .. bufnr, { clear = true }),
      callback = function()
        vim.lsp.codelens.refresh()
      end,
    })
  end,
})

-- ══════════════════════════════════════════════════════
-- LSP File Operations (auto-update imports on rename)
-- ══════════════════════════════════════════════════════
local fileops_ok, fileops = pcall(require, "lsp-file-operations")
if fileops_ok then
  fileops.setup()
end

-- ══════════════════════════════════════════════════════
-- Code Actions (<leader>c)
-- ══════════════════════════════════════════════════════
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("CodeActions", { clear = true }),
  callback = function(ev)
    local opts_buf = function(desc)
      return { buffer = ev.buf, desc = desc }
    end

    -- Organize imports (TS-specific)
    map("n", "<leader>co", function()
      vim.lsp.buf.code_action({
        filter = function(action)
          return action.title and (
            action.title:find("Organize Imports") or
            action.title:find("organize imports") or
            action.title:find("Sort imports")
          )
        end,
        bufnr = ev.buf,
      })
    end, opts_buf("Organize imports"))

    -- Fix all (TS-specific)
    map("n", "<leader>cf", function()
      vim.lsp.buf.code_action({
        filter = function(action)
          return action.title and (
            action.title:find("Fix all") or
            action.title:find("fix all")
          )
        end,
        bufnr = ev.buf,
      })
    end, opts_buf("Fix all diagnostics"))

    -- Suggest / all code actions
    map("n", "<leader>.", function()
      vim.lsp.buf.code_action({
        bufnr = ev.buf,
      })
    end, opts_buf("Code suggestions"))
  end,
})
