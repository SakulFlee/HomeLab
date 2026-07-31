{ config, lib, pkgs, modulesPath, ... }: {
  imports = [
    ../../shared/hardware/_.nix
    ../../shared/hardware/gpu-nvidia-prime.nix
    ../../shared/hardware/gpu-amdgpu.nix    
    ../../shared/hardware/wifi-mt7921e.nix
    ../../shared/hardware/touchpad.nix
  ];

  # Needs to be set by every platform host
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Additional boot arguments should _mostly_ stay in the host config as they tend to highly customized between hosts
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Disk config
  fileSystems."/" =
    { device = "/dev/disk/by-uuid/1f439d9c-9091-443f-bfe5-26268bd52d03";
      fsType = "btrfs";
    };

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/1f439d9c-9091-443f-bfe5-26268bd52d03";
      fsType = "btrfs";
      options = [ "subvol=home" ];
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/1f439d9c-9091-443f-bfe5-26268bd52d03";
      fsType = "btrfs";
      options = [ "subvol=nix" ];
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/91F6-9D00";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/417a545e-a9a0-472b-adc1-2428812c1110"; }
    ];
  boot.resumeDevice = "/dev/disk/by-uuid/417a545e-a9a0-472b-adc1-2428812c1110";

  # NVIDIA PRIME
  hardware.nvidia.prime = {
    nvidiaBusId = "PCI:1:0:0";
    amdgpuBusId = "PCI:5:0:0";
  };
}
