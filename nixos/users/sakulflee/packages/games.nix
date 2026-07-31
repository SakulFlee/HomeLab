{ pkgs, ... }: {
  home.packages = with pkgs; [
    # Proton manager
    pkgs.protonplus
    # FFXIV
    xivlauncher
    # Minecraft
    prismlauncher
  ];
}

