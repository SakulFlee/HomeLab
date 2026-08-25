{ ... }: {
  imports = [
    ./auto-update.nix
    ./gc.nix
    ./boot-loader.nix
    ./experimental-features.nix 
    ./fonts.nix
    ./gpg.nix
    ./locale.nix
    ./mount-nas.nix
    ./nixpkgs-unfree.nix
    ./sops.nix
    ./ssh.nix
    ./system-packages.nix
    ./system-state.nix
    ./zram.nix
    ./zsh.nix
    ./dbus.nix
    ./home-manager.nix
    # ./llama-swap.nix
    # ./open-webui.nix
    ./srv.nix
  ];
}
