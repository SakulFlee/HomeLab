let
  pkgs = import (import ./nixpkgs.nix) { };
in
{
  network = {
    inherit pkgs;
    specialArgs = {
      systemdBoot = true;
    };
    description = "simple hosts";
    ordering = {
      tags = [
        "db"
        "web"
      ];
    };
  };

  # CF-DDNS
  "192.168.178.199" = _: {
    { systemdBoot, ... }:
    {
      deployment.tags = [ "web" ];

      boot.loader.systemd-boot.enable = systemdBoot;
      boot.loader.efi.canTouchEfiVariables = true;

      system.stateVersion = "25.05";

      services.nginx.enable = true;

      fileSystems = {
        "/" = {
          label = "nixos";
          fsType = "ext4";
        };
        "/boot" = {
          label = "boot";
          fsType = "vfat";
        };
      };
    };

  # Caddy
  "192.168.178.201" = _: {
    deployment.tags = [ "db" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    system.stateVersion = "25.05";

    services.postgresql.enable = true;

    fileSystems = {
      "/" = {
        label = "nixos";
        fsType = "ext4";
      };
      "/boot" = {
        label = "boot";
        fsType = "vfat";
      };
    };
  };

  # Syncthing
  "192.168.178.202" = _: {
    deployment.tags = [ "db" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    system.stateVersion = "25.05";

    services.postgresql.enable = true;

    fileSystems = {
      "/" = {
        label = "nixos";
        fsType = "ext4";
      };
      "/boot" = {
        label = "boot";
        fsType = "vfat";
      };
    };
  };

  # Minecraft
  "192.168.178.203" = _: {
    deployment.tags = [ "db" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    system.stateVersion = "25.05";

    services.postgresql.enable = true;

    fileSystems = {
      "/" = {
        label = "nixos";
        fsType = "ext4";
      };
      "/boot" = {
        label = "boot";
        fsType = "vfat";
      };
    };
  };
}
