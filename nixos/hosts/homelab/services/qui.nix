{ config, pkgs, ... }: let
  configDir = "/var/lib/qui";
in {
  systemd.tmpfiles.settings."qui" = {
    "${configDir}"."d" = {
      mode = "0755";
      user = "qui";
      group = "qui";
    };
  };

  users.groups.qui = {};
  users.users.qui = {
    isSystemUser = true;
    group = "qui";
    home = configDir;
    createHome = true;
  };

  systemd.services.qui = {
    description = "qui - Modern qBittorrent Web UI";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ qui ];
    serviceConfig = {
      Type = "simple";
      User = "qui";
      Group = "qui";
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'if [ ! -f ${configDir}/config.toml ]; then ${pkgs.qui}/bin/qui generate-config --config-dir ${configDir}; fi'";
      ExecStart = "${pkgs.qui}/bin/qui serve --config-dir ${configDir} --data-dir ${configDir}";
      Restart = "on-failure";
      RestartSec = 5;
      StateDirectory = "qui";
      WorkingDirectory = configDir;
    };
  };

  services.homelab-restic = {
    enable = true;
    paths = [ configDir ];
  };
}
