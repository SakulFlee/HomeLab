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

  "cf-ddns" =
    { systemdBoot, ... }:
    {
      deployment.tags = [ "web" ];

      boot.loader.systemd-boot.enable = systemdBoot;
      boot.loader.efi.canTouchEfiVariables = true;

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

  "caddy" = _: {
    deployment.tags = [ "db" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

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

  "syncthing" = _: {
    deployment.tags = [ "db" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

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

  "minecraft" = _: {
    deployment.tags = [ "db" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

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
