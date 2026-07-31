{ pkgs, ... }:
let
  paperJar = pkgs.fetchurl {
    url = "https://fill-data.papermc.io/v1/objects/d30fae0c74092b10855f0412ca6b265c60301a013d34bc28a2a41bf5682dd80b/paper-26.1.2-69.jar";
    hash = "sha256-0w+uDHQJKxCFXwQSymsmXGAwGgE9NLwooqQb9Wgt2As=";
  };
in {
  users.groups.minecraft = {};
  users.users.minecraft = {
    isSystemUser = true;
    group = "minecraft";
    home = "/var/lib/minecraft";
    createHome = true;
  };

  systemd.services.minecraft = {
    description = "Minecraft Paper Server";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "forking";
      User = "minecraft";
      Group = "minecraft";
      WorkingDirectory = "/var/lib/minecraft";
      ExecStart = "${pkgs.screen}/bin/screen -dmS minecraft ${pkgs.jdk25}/bin/java -Xms2G -Xmx4G -jar ${paperJar} nogui";
      ExecStop = let
        stopScript = pkgs.writeShellScript "minecraft-stop" ''
          exec ${pkgs.screen}/bin/screen -S minecraft -X stuff stop$(printf "\n")
        '';
      in "${stopScript}";
      Restart = "on-failure";
    };
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/minecraft" ];
  };

  environment.systemPackages = with pkgs; [ screen jdk25 ];
}
