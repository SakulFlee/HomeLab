{ config, ... }: {
  imports = [
    ./gpu-mesa.nix
  ];

  services.xserver.videoDrivers = [
    "nvidia"
  ];

  hardware.graphics = {
    enable = true;
  };

  hardware.nvidia = {
    # Modesetting
    modesetting.enable = true;

    # Experimental!
    powerManagement.enable = true;

    # Driver version
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    open = true;

    # Include nvidia settings app
    nvidiaSettings = true;
  };
}
