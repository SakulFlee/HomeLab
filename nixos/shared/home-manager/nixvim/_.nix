{ inputs, pkgs, ... }: {
  imports = [
    inputs.nixvim.homeModules.nixvim
    ./plugins.nix
    ./lsp.nix
    ./dap.nix
  ];

  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    colorschemes.kanagawa = {
      enable = true;
      settings.theme = "dragon";
    };

    opts = {
      relativenumber = true;
      number = true;
      signcolumn = "yes";
      wrap = true;
      spell = true;
      spelllang = "en_us";
      termguicolors = true;
      updatetime = 250;
      conceallevel = 2;
      cmdheight = 0;
      winborder = "rounded";
      expandtab = true;
      tabstop = 4;
      softtabstop = 4;
      shiftwidth = 4;
    };

    globals = {
      mapleader = " ";
      maplocalleader = ",";
    };

    clipboard = {
      register = "unnamedplus";
      providers.wl-copy.enable = true;
    };

    # ── Extra plugins (not in nixvim module) ──────────────────
    extraPlugins = [
      pkgs.vimPlugins.heirline-nvim
      pkgs.vimPlugins.nvim-lsp-file-operations
    ];

    # ── Lua configuration ─────────────────────────────────────
    extraConfigLuaPre = builtins.readFile ./keymaps.lua;
    extraConfigLua    = builtins.readFile ./heirline.lua + ''
      require("snacks.notifier")
    '';

    extraConfigLuaPost = builtins.readFile ./autocmds.lua;
  };

  # CLI tools that plugins shell out to
  home.packages = with pkgs; [
    ripgrep
    fd
    tree-sitter
    opencode
    vscode-extensions.vadimcn.vscode-lldb.adapter
  ];
}
