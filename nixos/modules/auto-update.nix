{ config, pkgs, ... }: {
  systemd.services.nixos-auto-update = {
    description = "Auto-update NixOS configuration from Git";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ git nixos-rebuild nix procps ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
    };
    script = ''
      if pgrep -x nixos-rebuild > /dev/null 2>&1; then
        echo "nixos-rebuild already running, skipping auto-update"
        exit 0
      fi
      git remote set-url origin https://forgejo.sakul-flee.de/SakulFlee/HomeLab.git
      git fetch origin main
      git reset --hard origin/main
      nixos-rebuild switch --flake "/etc/nixos/nixos#${config.networking.hostName}" --show-trace
      nix-collect-garbage --delete-old
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
