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

  # The Incus pool and media subvolumes below live on the dedicated SSD
  # (/dev/sda1). The old k3s local-path `storage` subvolume is still on that
  # same filesystem, retained unmounted -- local-path Retain means its data
  # stays until it is migrated or explicitly deleted, never as a side effect
  # of removing the mount entry.
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
  # nofail here because of the same outage mode as any mount: without it this
  # entry is a hard member of local-fs.target, which carries
  # OnFailure= to emergency.target, so a missing 'incus-pools' subvolume reaches
  # Emergency Mode and, headless, that is no network and no way back in. Every
  # running instance's disk lives under this mount, so the blast radius of it
  # failing is larger than any other mount on this host.
  #
  # Dropping the implicit Before=local-fs.target ordering that nofail also
  # removes is safe here because every consumer of this mount orders itself
  # explicitly: incus.service and the nested
  # var-lib-incus-storage-pools-persistent.mount both carry After= and Requires=
  # on this unit. Checked before adding it, since this is the one thing nofail
  # quietly trades away. fstrim.service does not depend on this mount and simply
  # skips an absent filesystem, and the incus-apply-*.path units watch
  # /etc/nixos/nixos, which is on the NVMe root (subvolid 5) and not on this
  # subvolume, so losing their implicit sysinit.target chain costs nothing.
  #
  # If this mount does fail, incus.service refuses to start rather than silently
  # creating pool directories on the NVMe root filesystem -- running instances
  # keep running, and management is what is lost until the subvolume is back.
  fileSystems."/var/lib/incus/storage-pools" =
    { device = "/dev/disk/by-uuid/a8ab0668-28ae-437c-96dc-bed48481b2c0";
      fsType = "btrfs";
      options = [ "subvol=incus-pools" "nofail" ];
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