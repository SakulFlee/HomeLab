{ config, pkgs, lib, ... }: {
  imports = [
    ./mautrix-whatsapp.nix
    ../../modules
  ];

  networking.hostName = "mautrix-whatsapp";

  system.stateVersion = "26.05";
}
