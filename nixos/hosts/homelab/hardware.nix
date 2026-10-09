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
  # The mountpoint is /var/lib/incus/storage-pools specifically, NOT an arbitrary
  # directory under /var/lib/incus. Incus rejects any pool source that sits
  # under its state dir but outside that path:
  #   Failed to create storage pool "persistent": Only allowed source path under
  #   "/var/lib/incus" is "/var/lib/incus/storage-pools/persistent"
  # It is also the same convention the dir driver defaults to.
  #
  # No compression at the mount level: it would also apply to VM disk images
  # later, where compression and Incus' CoW-off optimisation are mutually
  # exclusive. Per-volume compression is set in Incus itself instead.
  #
  # neededForBoot = false so a missing subvolume cannot block boot; incus.service
  # has requires/after on this .mount unit, so it refuses to start rather than
  # silently creating pool directories on the NVMe root filesystem.
  fileSystems."/var/lib/incus/storage-pools" =
    { device = "/dev/disk/by-uuid/a8ab0668-28ae-437c-96dc-bed48481b2c0";
      fsType = "btrfs";
      options = [ "subvol=incus-pools" ];
      neededForBoot = false;
    };

  # The local media tree: the second option beside the NAS, so the layout is
  # not hard-wired to //192.168.178.250. modules/media-shares.nix is the source
  # of truth for which share resolves where, and the path inside every instance
  # is /mnt/nas/<share> either way -- so a share can move between the two trees
  # without any application config moving with it.
  #
  # Empty today and deliberately so, which is a measured decision rather than an
  # oversight. The NAS shares are:
  #
  #   Movies 73G   Shows 243G   NSFW 1.3T   qBittorrent 555G
  #
  # against sda1 at 932G with 320G available (2026-10-09). Nothing in the
  # library fits, least of all the 555G downloads share, so nothing has been
  # moved onto it. It exists so the alternative is real and testable before it
  # is needed, rather than a design that was never tried.
  #
  # Same subvolume recipe and the same reasoning as incus-pools above: a true
  # top-level sibling of 'storage' and 'incus-pools', so it stays clean under
  # quota/snapshot tooling and outlives k3s' removal. Created once on the
  # server, since NixOS does not create btrfs subvolumes:
  #
  #   sudo mkdir -p /mnt/media-tmp
  #   sudo mount -t btrfs -o subvol=/ \
  #     /dev/disk/by-uuid/a8ab0668-28ae-437c-96dc-bed48481b2c0 /mnt/media-tmp
  #   sudo btrfs subvolume create /mnt/media-tmp/media
  #   sudo umount /mnt/media-tmp && sudo rmdir /mnt/media-tmp
  #
  # Verify with: sudo btrfs subvolume list /var/lib/rancher/k3s/storage
  #
  # No quota on it. Capacity is explicitly deferred: with nothing stored here,
  # a limit would only be a guess, and modules/mount-media.nix records what the
  # first real limit should be sized against.
  #
  # neededForBoot = false so a missing subvolume cannot block boot. Unlike
  # incus-pools there is no service with requires/after on this .mount unit
  # (the instances bind-mount specific shares, not the tree root), so a missing
  # subvolume surfaces as a failed mount unit and a failed mount-media.service
  # rather than as data quietly landing on the NVMe root filesystem.
  fileSystems."/mnt/media" =
    { device = "/dev/disk/by-uuid/a8ab0668-28ae-437c-96dc-bed48481b2c0";
      fsType = "btrfs";
      options = [ "subvol=media" ];
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