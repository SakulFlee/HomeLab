{
  config,
  pkgs,
  lib,
  ...
}:

let
  minecraftServerDataDir = "/opt/minecraft";
  java = pkgs.temurin-bin-21-jre; # Using pkgs.temurin-bin-21-jre
in
{
  options.services.minecraft = {
    enable = lib.mkEnableOption "Minecraft Paper server";
    description = lib.mkOption {
      type = lib.types.str;
      default = "Minecraft Paper Server";
    };
    version = lib.mkOption {
      type = lib.types.str;
      default = "1.21.6";
    };
    build = lib.mkOption {
      type = lib.types.int;
      default = 17;
    };
    memoryLimit = lib.mkOption {
      type = lib.types.str;
      default = "8G";
    };
    pluginsJarsSource = lib.mkOption {
      type = lib.types.path;
      description = "Path to the directory containing plugin JAR files.";
    };
  };

  config = lib.mkIf config.services.minecraft.enable (
    let
      paperJarDerivation = pkgs.stdenv.mkDerivation {
        pname = "paper-jar"; # Renamed back to paper-jar for consistency
        version = "${config.services.minecraft.version}-b${toString config.services.minecraft.build}";

        src = pkgs.fetchurl {
          url = "https://api.papermc.io/v2/projects/paper/versions/${config.services.minecraft.version}/builds/${toString config.services.minecraft.build}/downloads/paper-${config.services.minecraft.version}-${toString config.services.minecraft.build}.jar";
          # IMPORTANT: Replace with the actual SHA256!
          sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # <--- REPLACE THIS
        };
        installPhase = "mkdir -p $out/jar; cp $src $out/jar/server.jar;";
      };
    in
    {
      systemd.services.minecraft = {
        description =
          config.services.minecraft.description
          + " v${config.services.minecraft.version} Build ${toString config.services.minecraft.build}";
        serviceConfig = {
          Type = "simple";
          DynamicUser = true;
          User = "minecraft";
          Group = "minecraft";
          WorkingDirectory = minecraftServerDataDir;
          ExecStart = "${java}/bin/java -Xms512M -Xmx${config.services.minecraft.memoryLimit} -jar ${minecraftServerDataDir}/server.jar nogui";
          Restart = "on-failure";
          RestartSec = "10s";
          MemoryMax = config.services.minecraft.memoryLimit;
          CPUAccounting = true;
          IOAccounting = true;
          StandardInput = "tty";
          StandardOutput = "journal";
          StandardError = "journal";

          ExecStartPre = ''
            mkdir -p "${minecraftServerDataDir}"
            # chown is still needed to ensure the persistent user owns the directory
            chown -R minecraft:minecraft "${minecraftServerDataDir}"

            cp "${paperJarDerivation}/jar/server.jar" "${minecraftServerDataDir}/server.jar"

            mkdir -p "${minecraftServerDataDir}/plugins"
            chown -R minecraft:minecraft "${minecraftServerDataDir}/plugins"

            find "${minecraftServerDataDir}/plugins" -maxdepth 1 -name "*.jar" -delete || true

            cp -r "${config.services.minecraft.pluginsJarsSource}/." "${minecraftServerDataDir}/plugins/" || true

            if [ ! -f "${minecraftServerDataDir}/eula.txt" ]; then
              echo "eula=true" > "${minecraftServerDataDir}/eula.txt"
            fi
          '';
        };
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
  );
}
