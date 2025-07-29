{
  config,
  pkgs,
  lib,
  ...
}:

let
  minecraftServerDataDir = "/var/lib/minecraft";
  java = pkgs.temurin-bin;
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
      default = "1.21.8";
    };
    build = lib.mkOption {
      type = lib.types.int;
      default = 1;
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
        pname = "paper-jar";
        version = "${config.services.minecraft.version}-b${toString config.services.minecraft.build}";

        dontUnpack = true;
        src = pkgs.fetchurl {
          url = "https://api.papermc.io/v2/projects/paper/versions/${config.services.minecraft.version}/builds/${toString config.services.minecraft.build}/downloads/paper-${config.services.minecraft.version}-${toString config.services.minecraft.build}.jar";
          sha256 = "sha256-mR3yv8RlcWe2ERctjDyx2rD3If5DmCyqRqH1MrlVc70=";
        };
        installPhase = "mkdir -p $out/jar; cp $src $out/jar/server.jar;";
      };

      prepareMinecraftScript = pkgs.writeScript "prepare-minecraft-data-dir" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        ${pkgs.coreutils}/bin/install -m 0644 "${paperJarDerivation}/jar/server.jar" "${minecraftServerDataDir}/server.jar"

        mkdir -p "${minecraftServerDataDir}/plugins"
        chown -R minecraft:minecraft "${minecraftServerDataDir}/plugins"

        find "${minecraftServerDataDir}/plugins" -maxdepth 1 -name "*.jar" -delete || true

        cp -r "${config.services.minecraft.pluginsJarsSource}/." "${minecraftServerDataDir}/plugins/" || true

        if [ ! -f "${minecraftServerDataDir}/eula.txt" ]; then
          echo "eula=true" > "${minecraftServerDataDir}/eula.txt"
        fi
      '';
      minecraftScript = pkgs.writeScript "prepare-minecraft-data-dir" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        cd "${minecraftServerDataDir}"

        "${java}/bin/java" -Xms512M -Xmx${config.services.minecraft.memoryLimit} -jar "${minecraftServerDataDir}/server.jar" nogui
      '';
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

          Restart = "on-failure";
          RestartSec = "10s";

          MemoryMax = config.services.minecraft.memoryLimit;
          CPUAccounting = true;
          IOAccounting = true;
          StandardInput = "tty";
          StandardOutput = "journal";
          StandardError = "journal";

          StateDirectory = "minecraft";

          ExecStartPre = "${prepareMinecraftScript}";
          ExecStart = "${minecraftScript}";
        };
      };

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
