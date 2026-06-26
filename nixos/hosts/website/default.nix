{ ... }: {
  imports = [
    ./website.nix
    ../../modules
  ];

  networking.hostName = "website";

  system.stateVersion = "26.05";
}
