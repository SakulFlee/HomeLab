{ pkgs, ... }:

let
  stateDir  = "/var/lib/palworld";
  serverDir = "${stateDir}/server";
  palworldSh = "${serverDir}/PalServer.sh";

  steam-run = "${pkgs.steam-run}/bin/steam-run";
  steamcmd  = "${pkgs.steamcmd}/bin/steamcmd";

  updateScript = pkgs.writeShellScript "update-palworld" ''
    set -euo pipefail
    echo "[palworld] Stopping server..."
    systemctl stop palworld-server.service 2>/dev/null || true
    echo "[palworld] Updating server via SteamCMD..."
    ${steam-run} ${steamcmd} \
      +force_install_dir ${serverDir} \
      +login anonymous \
      +app_update 2394010 validate \
      +quit
    echo "[palworld] Update complete. Starting server..."
    systemctl start palworld-server.service 2>/dev/null || true
    echo "[palworld] Done."
  '';
in {
  nixpkgs.config.allowUnfree = true;

  users.users.palworld = {
    isSystemUser = true;
    group = "palworld";
    home = stateDir;
    createHome = true;
  };
  users.groups.palworld = {};

  systemd.services.palworld-download = {
    description = "Download Palworld Dedicated Server";
    after  = [ "network.target" ];
    before = [ "palworld-server.service" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ steam-run steamcmd ];
    serviceConfig = {
      Type           = "oneshot";
      User           = "palworld";
      Group          = "palworld";
      RemainAfterExit = true;
      StateDirectory = "palworld";
      TimeoutSec     = 600;
      WorkingDirectory = stateDir;
    };
    script = ''
      if [ ! -x "${palworldSh}" ]; then
        echo "[palworld] Server not found -- downloading via SteamCMD..."
        ${steam-run} ${steamcmd} \
          +force_install_dir ${serverDir} \
          +login anonymous \
          +app_update 2394010 validate \
          +quit
        echo "[palworld] Download complete."
      else
        echo "[palworld] Server already present, skipping download."
      fi
    '';
  };

  systemd.services.palworld-server = {
    description = "Palworld Dedicated Server";
    after    = [ "network.target" "palworld-download.service" ];
    requires = [ "palworld-download.service" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ steam-run ];
    serviceConfig = {
      Type           = "simple";
      User           = "palworld";
      Group          = "palworld";
      ExecStart      = "${steam-run} ${palworldSh} -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS";
      Restart        = "on-failure";
      RestartSec     = 10;
      TimeoutStopSec = 30;
    };
  };

  systemd.services.palworld-update = {
    description = "Update Palworld Dedicated Server";
    after  = [ "network.target" ];
    wants  = [ "network.target" ];
    path = with pkgs; [ steam-run steamcmd ];
    serviceConfig = {
      Type  = "oneshot";
      User  = "palworld";
      Group = "palworld";
      WorkingDirectory = stateDir;
      ExecStart = "${updateScript}";
    };
  };

  systemd.timers.palworld-update = {
    description = "Weekly Palworld server update check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  networking.firewall.allowedUDPPorts = [ 8211 ];

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/palworld" ];
  };
}
