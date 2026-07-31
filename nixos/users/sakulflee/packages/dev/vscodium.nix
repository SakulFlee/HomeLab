{ pkgs, ... }: {
  programs.vscodium = {
    enable = true;

    package = pkgs.symlinkJoin {
      name = "vscodium-wrapped";
      paths = [ pkgs.vscodium ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/codium \
          --set XKB_DEFAULT_LAYOUT de
      '';
    };

    profiles.default = {
      userSettings = {
        "telemetry.telemetryLevel" = "off";
        "update.mode" = "none";
        "workbench.sideBar.location" = "right";
        "workbench.activityBar.location" = "top";
        "workbench.activityBar.compact" = true;
        "git.enableSmartCommit" = true;
        "git.alwaysSignOff" = true;
        "git.autofetch" = "all";
        "git.confirmSync" = false;
        "files.autoSave" = "onFocusChange";
        "keyboard.dispatch" = "keyCode";
        "terminal.integrated.fontFamily" = "'JetBrainsMono Nerd Font'";
        "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'Droid Sans Mono', 'monospace'";
        "editor.fontLigatures" = true;
        "diffEditor.hideUnchangedRegions.enabled" = true;
      };

      extensions = with pkgs.vscode-extensions; [
        # General
        fill-labs.dependi
        hbenl.vscode-test-explorer
        ms-vscode.test-adapter-converter
        vadimcn.vscode-lldb
        redhat.vscode-yaml
        christian-kohler.path-intellisense

        # Git tools
        (pkgs.vscode-utils.buildVscodeMarketplaceExtension {
          mktplcRef = {
            publisher = "iceinveins";
            name = "worktree-manager";
            version = "0.3.4";
            sha256 = "sha256-Y4eSo158wPksi/ZQs04FFPq5hA15R9MLE25PhPvovu4=";
          };
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ (pkgs.lib.getLib pkgs.stdenv.cc.cc) ];
        })
        (pkgs.vscode-utils.buildVscodeMarketplaceExtension {
          mktplcRef = {
            publisher = "asispts";
            name = "neo-git-graph";
            version = "0.4.0";
            sha256 = "sha256-tMd76ZQjiE/3U95/TFrbLG9TgIxpREhrSK/tXMfN2Yk=";
          };
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ (pkgs.lib.getLib pkgs.stdenv.cc.cc) ];
        })

        # Rust
        rust-lang.rust-analyzer
        tamasfe.even-better-toml
        (pkgs.vscode-utils.buildVscodeMarketplaceExtension {
          mktplcRef = {
            publisher = "Swellaby";
            name = "vscode-rust-test-adapter";
            version = "0.11.0";
            sha256 = "sha256-IgfcIRF54JXm9l2vVjf7lFJOVSI0CDgDjQT+Hw6FO4Q=";
          };
        })

        # Nix
        bbenoist.nix
        jnoortheen.nix-ide

        # Markdown & Typst
        myriad-dreamin.tinymist
        tomoki1207.pdf
        (pkgs.vscode-utils.buildVscodeMarketplaceExtension {
          mktplcRef = {
            publisher = "MermaidChart";
            name = "vscode-mermaid-chart";
            version = "2.7.2";
            sha256 = "sha256-hXJPKvmXpJi54O6xSJFR20jHOS6hzyPGFTu7JDSKe2s=";
          };
        })
      ];
    };
  };
}

