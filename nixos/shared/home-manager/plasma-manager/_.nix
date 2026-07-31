{ inputs, pkgs, lib, config, ... }: {
  imports = [
    inputs.plasma-manager.homeModules.plasma-manager
    ./ktrashrc.nix
    ./workspace.nix
    ./desktop.nix
    ./panels.nix
    ./shortcuts.nix
    ./cursor.nix
  ];

  programs.plasma.enable = true;

  # Clear Plasma caches before applying config so it's not ignored on next login
  home.activation.cleanPlasmaCache = lib.mkBefore ''
    ${pkgs.coreutils}/bin/rm -rf \
      "${config.home.homeDirectory}/.cache/plasma*" \
      "${config.home.homeDirectory}/.local/share/plasma*"
  '';
}
