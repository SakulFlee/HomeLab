{ ... }: {
  imports = [
    ./mautrix-discord.nix
    ../../modules
  ];

  networking.hostName = "mautrix-discord";

  system.stateVersion = "26.05";
}
