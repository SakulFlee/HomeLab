{ config, pkgs, ... }: {
  imports = [ ./caddy.nix ];

  boot.isContainer = true;

  networking = {
    hostName = "caddy";
    useDHCP = false;
    interfaces.eth0.ipv4.addresses = [{
      address = "10.0.0.200";
      prefixLength = 24;
    }];
    defaultGateway = "10.0.0.1";
    nameservers = [ "1.1.1.1" "8.8.8.8" ];
  };

  systemd.services.nixos-auto-update = {
    description = "Auto-update NixOS configuration from Git";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ git nixos-rebuild ];
    environment.REPO_URL = "https://forgejo.sakul-flee.de/sakulflee/HomeLab.git";
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
    };
    script = ''
      if [ ! -d .git ]; then
        git init
        git remote add origin "$REPO_URL"
      fi

      git fetch origin main 2>/dev/null || exit 0
      BEHIND=$(git rev-list --count @..@{u} 2>/dev/null || echo 0)

      if [ "$BEHIND" -gt 0 ]; then
        echo "Upstream updates detected ($BEHIND commits behind)"
        git pull origin main
        nixos-rebuild switch --flake /etc/nixos#caddy --show-trace
      fi
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

  system.stateVersion = "26.05";
}
