{ config, lib, pkgs, modulesPath, ... }: {
  imports = [
    ../../shared/hardware/_.nix
    ../../shared/hardware/gpu-nvidia.nix
    ../../shared/hardware/gpu-amdgpu.nix
  ];

  # Needs to be set by every platform host
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Additional boot arguments should _mostly_ stay in the host config as they tend to highly customized between hosts
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usb_storage" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Disk config
  fileSystems."/" =
    { device = "/dev/disk/by-uuid/20bdfb75-9bbc-4d5b-8b18-c20dfb2bbc22";
      fsType = "btrfs";
    };

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/20bdfb75-9bbc-4d5b-8b18-c20dfb2bbc22";
      fsType = "btrfs";
      options = [ "subvol=home" ];
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/20bdfb75-9bbc-4d5b-8b18-c20dfb2bbc22";
      fsType = "btrfs";
      options = [ "subvol=nix" ];
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/CD0F-328B";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };
  fileSystems."/mnt/ssd" =
    { device = "/dev/disk/by-uuid/02c8c213-7a5b-4bf1-97da-749dd87b3417";
      fsType = "btrfs";
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/66f414be-c83d-4b98-aa49-ca21bd57eb00"; }
    ];
  boot.resumeDevice = "/dev/disk/by-uuid/66f414be-c83d-4b98-aa49-ca21bd57eb00";
}
