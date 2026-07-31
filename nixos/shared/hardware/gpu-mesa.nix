{ pkgs, ... }: {
  hardware.graphics = {
    enable = true;
    extraPackages = [ pkgs.mesa ];
  };
}
