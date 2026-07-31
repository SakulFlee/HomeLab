{ config, pkgs, ... }: {
  sops.secrets."renovate-env" = {};

  environment.etc."renovate/config.js" = {
    text = ''
      module.exports = {
        platform: 'forgejo',
        endpoint: 'https://forgejo.sakul-flee.de/api/v1',
        autodiscover: true,
        allowedUnsafeExecutions: ['gradleWrapper'],
      };
    '';
    mode = "0644";
  };

  users.groups.renovate = {};
  users.users.renovate = {
    isSystemUser = true;
    group = "renovate";
    home = "/var/lib/renovate";
    createHome = true;
  };

  systemd.services.renovate = {
    description = "Renovate dependency dashboard bot";
    after = [ "network.target" ];
    wants = [ "network.target" ];
    path = with pkgs; [ nodejs cargo rustc go jdk21 gradle maven dotnet-sdk python3 git ];
    serviceConfig = {
      Type = "oneshot";
      User = "renovate";
      Group = "renovate";
      EnvironmentFile = [ config.sops.secrets."renovate-env".path ];
      ExecStart = "${pkgs.renovate}/bin/renovate";
    };
  };

  systemd.timers.renovate = {
    description = "Run Renovate bot hourly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  environment.systemPackages = with pkgs; [
    nodejs cargo rustc go jdk21 gradle maven dotnet-sdk python3 git
  ];
}
