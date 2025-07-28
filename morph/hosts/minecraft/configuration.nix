{
  config,
  pkgs,
  lib,
  ...
}:

let
  minecraftVersion = "1.21.6";
  paperBuild = "17";
  
  pluginsJarsPath = lib.cleanSource ./plugins;
  paperJarDerivation = pkgs.stdenv.mkDerivation {
    pname = "paper-jar";
    version = "${minecraftVersion}-b${paperBuild}";

    src = pkgs.fetchurl {
      url = "https://api.papermc.io/v2/projects/paper/versions/${minecraftVersion}/builds/${paperBuild}/downloads/paper-${minecraftVersion}-${paperBuild}.jar";
    };

    installPhase = ''
      mkdir -p $out/jar
      cp $src $out/jar/server.jar
    '';
  };

  java = pkgs.temurin-bin-21-jre;

  minecraftServerDataDir = "/opt/minecraft";
in
{
  deployment.tags = [ "minecraft" ];

  imports = [
    ../common/state.nix
    ../common/lxc.nix
    ../common/gc.nix
    ../common/networking.nix
    ../common/ssh.nix
    ../common/common_packages.nix
  ];

  services.minecraft = {
    enable = true;
    description = "Minecraft Paper Server v${minecraftVersion} Build ${paperBuild}";

    user = "minecraft";
    group = "minecraft";

    serviceConfig = {
      Type = "simple";

      WorkingDirectory = minecraftServerDataDir;

      ExecStart = "${java}/bin/java -Xms512M -Xmx${memoryLimit} -jar ${minecraftServerDataDir}/server.jar nogui";

      Restart = "on-failure";
      RestartSec = "10s";
      MemoryMax = memoryLimit; # Match Java -Xmx
      CPUAccounting = true;
      IOAccounting = true;
      StandardInput = "tty"; # Needed for console input via `systemctl attach minecraft`
      StandardOutput = "journal";
      StandardError = "journal";

      # Pre-start commands to set up directories, EULA, and manage plugin JARs
      ExecStartPre = ''
        # Create directory and set permissions
        mkdir -p "${minecraftServerDataDir}"
        chown -R minecraft:minecraft "${minecraftServerDataDir}"

        # Copy server jar
        cp "${paperJarDerivation}/jar/server.jar" "${minecraftServerDataDir}/server.jar"

        # Create plugin directory and set permissions
        mkdir -p "${minecraftServerDataDir}/plugins"
        chown -R minecraft:minecraft "${minecraftServerDataDir}/plugins"

        # Delete all existing plugin JARs
        find "${minecraftServerDataDir}/plugins" -maxdepth 1 -name "*.jar" -delete || true

        # Copy expected plugin JARs
        cp -r "${pluginsJarsSrc}/." "${minecraftServerDataDir}/plugins/" || true

        # Handle EULA
        echo "eula=true" > "${minecraftServerDataDir}/eula.txt"
      '';
    };
  };

  users.groups.minecraft = { };
  users.users.minecraft = {
    isSystem = true;
    group = "minecraft";
  };

  systemd.tmpfiles.rules = [
    "d '${minecraftServerDataDir}' 0755 minecraft minecraft -"
    "d '${minecraftServerDataDir}/plugins' 0755 minecraft minecraft -"
  ];

  networking.firewall = {
    allowedTCPPorts = [
      25565
      8100
    ];
    allowedUDPPorts = [ 19132 ];
  };
}
