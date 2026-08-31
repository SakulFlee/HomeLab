{ config, ... }: {
  imports = [
    ./gpu-mesa.nix
  ];

  services.xserver.videoDrivers = [
    "amdgpu"
  ];

  hardware.graphics = {
    enable = true;
  };
}
