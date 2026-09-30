{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ../../hardware/firmware.nix
    ../../hardware/microcode.nix
    ../../hardware/i2c.nix
    ../../hardware/gpu-amdgpu.nix
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

  # Incus storage pools: a sibling subvolume on the same SSD, so source data
  # stays on the SSD and the restic repo stays on the NVMe. Incus' own state
  # directory (/var/lib/incus -- dqlite DB, sockets, logs) remains on the NVMe,
  # since only the pools are mounted here.
  #
  # The subvolume must exist before this mounts, and NixOS does not create btrfs
  # subvolumes, so it was created once on the server (2026-09-30). It is a true
  # top-level sibling of 'storage' -- both report top level 5 -- rather than
  # nested inside it, so it survives k3s' removal in the final migration phase
  # and stays clean under quota/snapshot tooling:
  #
  #   sudo mkdir -p /mnt/incus-tmp
  #   sudo mount -t btrfs -o subvol=/ \
  #     /dev/disk/by-uuid/a8ab0668-28ae-437c-96dc-bed48481b2c0 /mnt/incus-tmp
  #   sudo btrfs subvolume create /mnt/incus-tmp/incus-pools
  #   sudo umount /mnt/incus-tmp && sudo rmdir /mnt/incus-tmp
  #
  # Verify with: sudo btrfs subvolume list /var/lib/rancher/k3s/storage
  #
  # No compression at the mount level: it would also apply to VM disk images
  # later, where compression and Incus' CoW-off optimisation are mutually
  # exclusive. Per-volume compression is set in Incus itself instead.
  #
  # neededForBoot = false so a missing subvolume cannot block boot; incus.service
  # has requires/after on this .mount unit, so it refuses to start rather than
  # silently creating pool directories on the NVMe root filesystem.
  fileSystems."/var/lib/incus/pools" =
    { device = "/dev/disk/by-uuid/a8ab0668-28ae-437c-96dc-bed48481b2c0";
      fsType = "btrfs";
      options = [ "subvol=incus-pools" ];
      neededForBoot = false;
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