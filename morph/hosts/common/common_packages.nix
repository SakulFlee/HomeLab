{ config, ... }:

{
  environment.systemPackages = with pkgs; [
    neovim
    curl
  ];
}
