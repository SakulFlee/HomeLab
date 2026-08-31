{ pkgs, ... }: {
  users.users.root = { shell = pkgs.zsh; };
  programs.zsh.enable = true;
}
