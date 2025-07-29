{
  config,
  pkgs,
  lib,
  ...
}:

let
  minecraftServerDataDir = "/opt/minecraft";
  java = pkgs.temurin-bin-21-jre; # Using pkgs.temurin-bin-21-jre as previously discussed
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

  # The 'config' attribute is assigned the result of lib.mkIf
  config = lib.mkIf config.services.minecraft.enable (
    # The 'let ... in { ... }' block is now wrapped in parentheses,
    # making it a single expression (an attribute set) for lib.mkIf.
    let
      paperJarDerivation = pkgs.stdenv.mkDerivation {
        pname = "paper-jar"; # Corrected name
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
      # This is the attribute set that gets merged by lib.mkIf
      systemd.services.minecraft = {
        description =
          config.services.minecraft.description
          + " v${config.services.minecraft.version} Build ${toString config.services.minecraft.build}";
        serviceConfig = {
          Type = "simple";
          DynamicUser = true;
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

      # --- These are now within the conditionally merged attribute set ---
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
          25565 # Minecraft Java
          8100 # BlueMap
        ];
        allowedUDPPorts = [
          19132 # Minecraft Bedrock
        ];
      };
    } # Close the 'in' attribute set
  ); # Close the parenthesis for lib.mkIf
}
