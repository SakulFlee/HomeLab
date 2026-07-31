{ config, ... }: {
  imports = [
    ./gpu-nvidia.nix
    ./gpu-mesa.nix
  ];

  hardware.nvidia = {
    # Experimental
    powerManagement.finegrained = true;

    # Prime
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };

      # NOTE: NEED TO SET BOTH BUS IDS IN HOST CONFIG!
      # Find them via: lspci | grep -E "VGA|3D"
      # Example:
      # nvidiaBusId = "PCI:1:0:0";
      # amdgpuBusId = "PCI:5:0:0";
    };
  };
}
