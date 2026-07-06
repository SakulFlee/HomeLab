{ ... }: {
  imports = [
    ./synapse.nix
    ./postgres.nix
    ./element-web.nix
    ./bridges.nix
    ../../modules
  ];

  networking.hostName = "matrix";

  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  system.stateVersion = "26.05";
}
