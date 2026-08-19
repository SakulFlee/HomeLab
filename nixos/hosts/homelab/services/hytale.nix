{ pkgs, ... }: {
  users.groups.hytale = {};
  users.users.hytale = {
    isSystemUser = true;
    group = "hytale";
    home = "/var/lib/hytale";
    createHome = true;
  };

  systemd.tmpfiles.rules = [
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    "d /var/lib/hytale 0755 hytale hytale -"
    "d /var/lib/hytale-downloader 0755 hytale hytale -"
  ];

  systemd.services.hytale = {
    description = "Hytale Dedicated Server";
    path = [ pkgs.jdk25 ];
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "forking";
      User = "hytale";
      Group = "hytale";
      WorkingDirectory = "/var/lib/hytale";
      ExecStart = "${pkgs.screen}/bin/screen -dmS hytale /var/lib/hytale/launch.sh";
      ExecStop = let
        stopScript = pkgs.writeShellScript "hytale-stop" ''
          exec ${pkgs.screen}/bin/screen -S hytale -X stuff stop$(printf "\n")
        '';
      in "${stopScript}";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  networking.firewall.allowedUDPPorts = [ 5520 ];

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/hytale" ];
  };

  environment.systemPackages = with pkgs; [ screen jdk25 ];
}
