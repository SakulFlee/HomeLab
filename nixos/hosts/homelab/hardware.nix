{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ../../shared/hardware/firmware.nix
    ../../shared/hardware/microcode.nix
    ../../shared/hardware/i2c.nix
    ../../shared/hardware/gpu-amdgpu.nix
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/f947dbe8-fde3-4002-92bf-fee906abab73";
      fsType = "btrfs";
    };

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/f947dbe8-fde3-4002-92bf-fee906abab73";
      fsType = "btrfs";
      options = [ "subvol=home" ];
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/f947dbe8-fde3-4002-92bf-fee906abab73";
      fsType = "btrfs";
      options = [ "subvol=nix" ];
    };

  # Cluster storage (k3s local-path tiers) lives on the dedicated SSD (/dev/sda1).
  # The local restic repository (/var/lib/backups) intentionally stays on the NVMe
  # so the source data and its backup are on separate disks.
  # noauto: mounted explicitly by k3s.service preStart so switch-to-configuration
  # never tries to unmount/remount it while k3s/containerd hold the path busy
  # (which hung rebuilds at "restarting sysinit-reactivation.target").
  fileSystems."/var/lib/rancher/k3s/storage" =
    { device = "/dev/disk/by-uuid/a8ab0668-28ae-437c-96dc-bed48481b2c0";
      fsType = "btrfs";
      options = [ "subvol=storage" "compress=zstd" "noauto" ];
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/5B72-9486";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/848a85dc-c812-478a-81fb-9e35926915b5"; }
    ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}