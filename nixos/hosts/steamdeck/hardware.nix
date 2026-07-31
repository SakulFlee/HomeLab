{ config, lib, pkgs, modulesPath, ... }: {
  imports = [
    ../../shared/hardware/_.nix
  ];

  # Additional boot arguments should _mostly_ stay in the host config as they tend to highly customized between hosts
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # For SteamDecks horizontal layout
  boot.loader.systemd-boot.consoleMode = "5";

  # Disk config
  fileSystems."/" =
    { device = "/dev/disk/by-uuid/da954ab9-0559-4cf4-9004-2826a61078d1";
      fsType = "btrfs";
    };

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/da954ab9-0559-4cf4-9004-2826a61078d1";
      fsType = "btrfs";
      options = [ "subvol=home" ];
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/da954ab9-0559-4cf4-9004-2826a61078d1";
      fsType = "btrfs";
      options = [ "subvol=nix" ];
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/C78D-6801";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

  # Swap + hibernation
  swapDevices =
    [ { device = "/dev/disk/by-uuid/f2aef7fb-e914-4284-8b8d-c920a56d2a4a"; }
    ];
  boot.resumeDevice = "/dev/disk/by-uuid/f2aef7fb-e914-4284-8b8d-c920a56d2a4a";

  # Steam Hardware
  hardware.steam-hardware.enable = true;

  # GPU
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [ 
      amdgpu_top
    ];
    extraPackages32 = [];
  };
  environment.sessionVariables = {
    AMD_VULKAN_ICD = "RADV";
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
