{ pkgs, ... }: {
  users.users.sakulflee = {
    description = "SakulFlee";
    initialPassword = "nixos";
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" "video" "render" "uinput" "i2c" "media" ];
    shell = pkgs.zsh;
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "@SakulFlee | Lukas Weber";
        email = "dev@sakul-flee.de";
        signingKey = "0A96C9AA72DB019DE171E7F77F0C6AF1F56A9E05";
      };
      commit.gpgsign = true;
      init.defaultBranch = "main";
      pull.rebase = true;
      credential.helper = "store";
      remote.origin.fetch = "+refs/pull/*/head:refs/remotes/origin/pr/*";
    };
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = { SetEnv.TERM = "xterm-256color"; };
  };

  programs.zsh = {
    enable = true;
    shellAliases = { n = "nvim"; lg = "lazygit"; };
    initContent = ''
      if [ -z "$SSH_AUTH_SOCK" ]; then
        eval "$(ssh-agent >/dev/null 2>&1)"
      fi
      export PATH="$PATH:$HOME/.local/bin"
    '';
  };
}
