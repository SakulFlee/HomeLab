{ ... }: {
  imports = [
    ./dns.nix
    ../../modules
  ];

  networking.hostName = "dns";

  system.stateVersion = "26.05";
}
