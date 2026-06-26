{ ... }: {
  imports = [
    ./caddy.nix
    ../../modules
  ];

  networking.hostName = "caddy";

  system.stateVersion = "26.05";
}
