{ config, pkgs, lib, ... }:

let
  stateDir  = "/var/lib/palworld";
  serverDir = "${stateDir}/server";
  palworldSh =
    "${serverDir}/steamapps/common/PalServer/PalServer.sh";

  steam-run = "${pkgs.steam-run}/bin/steam-run";
  steamcmd  = "${pkgs.steamcmd}/bin/steamcmd";

  updateScript = pkgs.writeShellScript "update-palworld" ''
    set -euo pipefail
    echo "[palworld] Updating server..."
    ${steam-run} ${steamcmd} \
      +force_install_dir ${serverDir} \
      +login anonymous \
      +app_update 2394010 validate \
      +quit
    echo "[palworld] Update complete."
  '';
in {
  # steam-run and steamcmd are unfree
  nixpkgs.config.allowUnfree = true;

  # ---- User & group ----
  users.users.palworld = {
    isSystemUser = true;
    group = "palworld";
    home = stateDir;
    createHome = true;
  };
  users.groups.palworld = { };

  # ---- Oneshot: download server on first boot ----
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
      TimeoutSec     = 600;            # first download can be slow
      WorkingDirectory = stateDir;
    };
    script = ''
      if [ ! -x "${palworldSh}" ]; then
        echo "[palworld] Server not found — downloading via SteamCMD..."
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

  # ---- Main server service ----
  systemd.services.palworld-server = {
    description = "Palworld Dedicated Server";
    after    = [ "network.target" "palworld-download.service" ];
    wants    = [ "palworld-download.service" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ steam-run ];
    serviceConfig = {
      Type           = "simple";
      User           = "palworld";
      Group          = "palworld";
      WorkingDirectory = "${serverDir}/steamapps/common/PalServer";
      ExecStart      = "${steam-run} ${palworldSh} -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS";
      Restart        = "on-failure";
      RestartSec     = 10;
      TimeoutStopSec = 30;
    };
  };

  # ---- Update service (triggered by timer or manually) ----
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
    };
    script = updateScript;
  };

  # Weekly automatic update check
  systemd.timers.palworld-update = {
    description = "Weekly Palworld server update check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  # ---- Firewall ----
  networking.firewall.allowedUDPPorts = [ 8211 8212 ];
}
