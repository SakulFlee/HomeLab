{ pkgs, ... }: {
  imports = [
    ./vscodium.nix
    ./android.nix
    ./jetbrains.nix
  ];

  home.packages = with pkgs; [
    git
    wl-clipboard
    renderdoc
    kitty

    jetbrains.jdk

    vscode-runner # Open VSCode workspaces from KDE 
  ];
}
