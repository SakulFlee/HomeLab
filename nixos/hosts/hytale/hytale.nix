{ config, pkgs, lib, ... }: {
  users.groups.hytale = { };
  users.users.hytale = {
    isSystemUser = true;
    group = "hytale";
    home = "/opt/hytale";
    createHome = true;
  };

  systemd.tmpfiles.rules = [
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    "d /opt/hytale 0755 hytale hytale -"
    "d /opt/hytale-downloader 0755 hytale hytale -"
  ];

  systemd.services.hytale = {
    description = "Hytale Dedicated Server";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "forking";
      User = "hytale";
      Group = "hytale";
      WorkingDirectory = "/opt/hytale";
      ExecStart = "${pkgs.screen}/bin/screen -dmS hytale /opt/hytale/launch.sh";
      ExecStop = let
        stopScript = pkgs.writeShellScript "hytale-stop" ''
          exec ${pkgs.screen}/bin/screen -S hytale -X stuff stop$(printf "\n")
        '';
      in "${stopScript}";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];

  environment.systemPackages = with pkgs; [ screen jdk25 ];
}
