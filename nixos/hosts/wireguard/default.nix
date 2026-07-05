{ ... }: {
  imports = [
    ./wireguard.nix
    ./caddy.nix
    ../../modules
  ];

  networking.hostName = "wireguard";

  system.stateVersion = "26.05";
}
