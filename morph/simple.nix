let
  pkgs = import (import ./nixpkgs.nix) { };
in
{
  network = {
    inherit pkgs;
    description = "HomeLab";
    ordering = {
      tags = [
        "ddns"
        "web"
        "svc"
      ];
    };
  };

  "cf-ddns" = _: {
    deployment.tags = [ "ddns" ];
    system.stateVersion = "25.05";

    # LXC Containers don't boot
    boot.loader.grub.enable = false;

    fileSystems."/" = {
      device = "none";
      fsType = "rootfs";
      options = [ "rw" "relatime" ];
    };

    # Fix for mount bug in NixOS + LXC
    systemd.mounts = [{
      where = "/sys/kernel/debug";
      enable = false;
    }];
  };

  "caddy" = _: {
    deployment.tags = [ "web" ];
    system.stateVersion = "25.05";

    # LXC Containers don't boot
    boot.loader.grub.enable = false;

    fileSystems."/" = {
      device = "none";
      fsType = "rootfs";
      options = [ "rw" "relatime" ];
    };

    # Fix for mount bug in NixOS + LXC
    systemd.mounts = [{
      where = "/sys/kernel/debug";
      enable = false;
    }];
  };

  "syncthing" = _: {
    deployment.tags = [ "svc" ];
    system.stateVersion = "25.05";

    # LXC Containers don't boot
    boot.loader.grub.enable = false;

    fileSystems."/" = {
      device = "none";
      fsType = "rootfs";
      options = [ "rw" "relatime" ];
    };

    # Fix for mount bug in NixOS + LXC
    systemd.mounts = [{
      where = "/sys/kernel/debug";
      enable = false;
    }];
  };

  "minecraft" = _: {
    deployment.tags = [ "svc" ];
    system.stateVersion = "25.05";

    # LXC Containers don't boot
    boot.loader.grub.enable = false;

    fileSystems."/" = {
      device = "none";
      fsType = "rootfs";
      options = [ "rw" "relatime" ];
    };

    # Fix for mount bug in NixOS + LXC
    systemd.mounts = [{
      where = "/sys/kernel/debug";
      enable = false;
    }];
  };
}
