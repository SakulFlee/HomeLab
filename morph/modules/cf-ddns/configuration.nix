{
  config,
  pkgs,
  lib,
  ...
}:

let
  scriptFile = builtins.readFile ./script.sh;
  settingsFile = builtins.readFile ./settings;
  settingsFileDerivation = pkgs.writeText "cf-ddns-settings" settingsFile;
  settingsTargetPath = "/opt/cf_ddns/settings";
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
      preStart = ''
        mkdir -p "$(dirname ${settingsTargetPath})"
        ln -sf ${settingsFileDerivation} ${settingsTargetPath}
      '';

      script = scriptFile;

      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
    };

    environment.systemPackages = with pkgs; [
      bash
      curl
      gnused
      jq
    ];
  };
}
