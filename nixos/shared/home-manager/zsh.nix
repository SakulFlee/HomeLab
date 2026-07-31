{ pkgs, lib, ... }: {
  home.packages = [ pkgs.zsh-powerlevel10k ];

  home.file.".p10k.zsh".text = builtins.readFile ../../users/sakulflee/p10k.zsh;

  programs.zsh = {
    enable = true;

    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "z"
      ];
    };

    history.size = 10000;

    sessionVariables = {
      WEBKIT_DISABLE_COMPOSITING_MODE = "1";
      EDITOR = "nvim";
    };

    initContent = lib.mkBefore ''
      if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
        source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
      fi

      source ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme

      [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
    '';
  };
}
