{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    deskflow
    wl-clipboard
  ];

  networking.firewall.allowedTCPPorts = [ 24800 24801 ];
  networking.firewall.allowedUDPPorts = [ 24801 ];
}
