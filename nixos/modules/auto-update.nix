{ config, pkgs, ... }: {
  systemd.services.nixos-auto-update = {
    description = "Auto-update NixOS configuration from Git";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ git nixos-rebuild ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
    };
    script = ''
      git pull origin main
      nixos-rebuild switch --flake "/etc/nixos/nixos#${config.networking.hostName}" --show-trace
    '';
  };

  systemd.timers.nixos-auto-update = {
    description = "Hourly timer for NixOS auto-update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "5min";
    };
  };
}
