{
  config,
  pkgs,
  lib,
  ...
}:

let
  scriptFile = builtins.readFile ./script.sh;
  settingsFile = pkgs.writeText "cf-ddns-settings" (builtins.readFile ./settings);
in
{
  options.services.cloudflare-ddns = {
    enable = lib.mkEnableOption "CloudFlare DDNS";
  };

  config = lib.mkIf config.services.cloudflare-ddns.enable {
    systemd.timers."cloudflare-ddns" = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "5m";
        Unit = "cloudflare-ddns.service";
      };
    };

    systemd.services."cloudflare-ddns" = {
      script = scriptFile;
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
    };

    systemd.tmpfiles.rules = [
      "d /opt/cf_ddns 0755 root root -"
      "L /opt/cf_ddns/settings - - - ${settingsFile}"
    ];

    environment.systemPackages = with pkgs; [
      bash
      curl
      gnused
      jq
    ];
  };
}
