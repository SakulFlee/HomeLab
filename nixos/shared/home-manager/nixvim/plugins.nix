{ pkgs, ... }: {
  programs.nixvim = {
    # ── Quality-of-life plugins ────────────────────────────────
    plugins = {
      web-devicons.enable = true;
      nvim-autopairs.enable = true;
      nvim-surround.enable = true;
      comment.enable          = true;
      todo-comments.enable    = true;
      gitsigns.enable         = true;

      # ── Completion: blink.cmp ──────────────────────────────
      blink-cmp = {
        enable = true;
        settings = {
          keymap = {
            preset = "default";
            "<Tab>" = [ "select_and_accept" "fallback" ];
            "<S-Tab>" = [ "select_prev" "fallback" ];
          };
          appearance.nerd_font_variant = "mono";
          completion = {
            documentation.auto_show = true;
            ghost_text.enabled = true;
          };
          sources = {
            default = [ "lazydev" "lsp" "path" "snippets" "buffer" ];
            providers = {
              lazydev = {
                name = "LazyDev";
                module = "lazydev.integrations.blink";
                score_offset = 100;
              };
            };
          };
          fuzzy.implementation = "prefer_rust_with_warning";
          signature.enabled = true;
        };
      };
      friendly-snippets.enable = true;
      lazydev.enable = true;

      # ── Snacks: expanded QoL suite ─────────────────────────
      snacks = {
        enable = true;
        settings = {
          notifier = {
            enabled = true;
            timeout = 3000;
          };
          picker = {
            enabled = true;
            sources = {
              files = {};
              grep = {};
              buffers = {};
            };
            win = {
              input.keys = {
                "<C-w>w" = { __unkeyed-1 = "cycle_win"; mode = [ "n" "i" ]; desc = "Cycle windows"; };
                "<C-w>j" = { __unkeyed-1 = "focus_list"; desc = "Focus list"; };
                "<C-w>l" = { __unkeyed-1 = "focus_preview"; desc = "Focus preview"; };
                "<Tab>"  = { __unkeyed-1 = "focus_preview"; mode = [ "n" "i" ]; desc = "Focus preview"; };
              };
              list.keys = {
                "<C-w>w" = { __unkeyed-1 = "cycle_win"; mode = "n"; desc = "Cycle windows"; };
                "<C-w>k" = { __unkeyed-1 = "focus_input"; desc = "Focus input"; };
                "<C-w>l" = { __unkeyed-1 = "focus_preview"; desc = "Focus preview"; };
                "<C-w>h" = { __unkeyed-1 = "focus_input"; desc = "Focus input"; };
                "<Tab>"  = { __unkeyed-1 = "focus_preview"; mode = "n"; desc = "Focus preview"; };
              };
              preview.keys = {
                "<C-w>w" = { __unkeyed-1 = "cycle_win"; mode = "n"; desc = "Cycle windows"; };
                "<C-w>h" = { __unkeyed-1 = "focus_input"; desc = "Focus input"; };
                "<C-w>j" = { __unkeyed-1 = "focus_list"; desc = "Focus list"; };
              };
            };
          };
          indent.enabled = true;
          words.enabled = true;
          scroll.enabled = true;
          quickfile.enabled = true;
          input.enabled = true;
          statuscolumn.enabled = true;
          scope.enabled = true;
          bigfile.enabled = true;
          lazygit.enabled = true;
          explorer.enabled = false;
        };
      };

      # ── Navigation & UI ────────────────────────────────────
      aerial = {
        enable   = true;
        settings.backends = [ "lsp" "treesitter" ];
      };
      neo-tree = {
        enable = true;
        settings = {
          auto_clean_after_session_restore = true;
          close_if_last_window = true;
          position = "right";
          window = {
            width = 25;
            mappings = {
              "<space>" = "noop";
            };
          };
          sources = [ "filesystem" "buffers" "git_status" "document_symbols" ];
          filesystem = {
            follow_current_file = {
              enabled = true;
              leave_dirs_open = false;
            };
            use_libuv_file_watcher = true;
          };
        };
      };
      which-key.enable = true;

      # ── Smart splits ───────────────────────────────────────
      smart-splits.enable = true;

      # ── Better escape ──────────────────────────────────────
      better-escape.enable = true;

      # ── Auto close/rename tags ─────────────────────────────
      ts-autotag.enable = true;

      # ── Guess indent ───────────────────────────────────────
      guess-indent = {
        enable = true;
        settings = {
          auto_cmd = true;
          filetype_blacklist = [ "rust" "python" "lua" "nix" "go" ];
        };
      };

      # ── Session manager (auto-session) ─────────────────────
      auto-session = {
        enable = true;
        settings = {
          auto_session_enable_last_session = true;
          auto_session_save_enabled         = true;
          auto_session_enabled              = true;
          auto_session_root_dir             = "~/.local/share/nvim/sessions";
        };
      };

      # ── Markdown ───────────────────────────────────────────
      render-markdown.enable  = true;
      markdown-preview.enable = true;

      # ── Formatters (conform.nvim) ──────────────────────────
      conform-nvim = {
        enable = true;
        settings = {
          formatters_by_ft = {
            lua        = [ "stylua" ];
            nix        = [ "nixfmt" ];
            javascript = [ "prettier" ];
            typescript = [ "prettier" ];
            tsx        = [ "prettier" ];
            html       = [ "prettier" ];
            css        = [ "prettier" ];
            json       = [ "prettier" ];
            yaml       = [ "prettier" ];
            toml       = [ "taplo" ];
            markdown   = [ "prettier" ];
          };
          format_on_save = {
            lsp_fallback = true;
            timeout_ms = 1000;
          };
        };
      };

      # ── Treesitter ─────────────────────────────────────────
      treesitter = {
        enable = true;
        settings = {
          highlight.enable = true;
          indent.enable    = true;
        };
      };
      treesitter-textobjects.enable = true;

      # ── AI: opencode.nvim ─────────────────────────────────
      opencode = {
        enable = true;
        settings.keymap_prefix = "<leader>o";
      };

      # ── Git: lazygit ───────────────────────────────────────
      lazygit.enable = true;

      # ── Rust: rustaceanvim ─────────────────────────────────
      rustaceanvim.enable = true;
    };
  };
}
