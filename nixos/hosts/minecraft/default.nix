{ ... }: {
  imports = [
    ./minecraft.nix
    ../../modules
  ];

  networking.hostName = "minecraft";

  system.stateVersion = "26.05";
}
