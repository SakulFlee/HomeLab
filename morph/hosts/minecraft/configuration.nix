{
  config,
  pkgs,
  lib,
  ...
}:

let
  pluginsJarsPath = lib.cleanSource ./plugins;
  # The actual downloaded Paper JAR derivation (only the JAR, no plugins yet)
  paperJarDerivation = pkgs.stdenv.mkDerivation {
    pname = "paper-jar";
    version = "${minecraftVersion}-b${paperBuild}";

    src = pkgs.fetchurl {
      url = "https://api.papermc.io/v2/projects/paper/versions/${minecraftVersion}/builds/${paperBuild}/downloads/paper-${minecraftVersion}-${paperBuild}.jar";
      # IMPORTANT: Replace with the actual SHA256 for the specific version and build.
      # Get it by running `nix-prefetch-url URL`
      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # <--- UPDATE THIS SHA256
    };

    installPhase = ''
      mkdir -p $out/jar
      cp $src $out/jar/server.jar
    '';
  };

  # Common Java runtime for the server
  java = pkgs.temurin-bin-21-jre;

  # The persistent data directory for the Minecraft server
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

  # Define the Systemd Service for Minecraft
  services.minecraft = {
    enable = true;
    description = "Minecraft Paper Server v${minecraftVersion} Build ${paperBuild}";

    # User and group for the server to run as
    user = "minecraft";
    group = "minecraft";

    serviceConfig = {
      Type = "simple";
      # DynamicUser = true; # If you want to use a fixed user, comment this out and define the user/group below.
      # If this is active, systemd will create a temporary user/group each time.
      # If using DynamicUser, /var/lib/minecraft is created by default.
      # We explicitly want /opt/minecraft, so we'll ensure ownership with tmpfiles.

      # Set the working directory for the server
      WorkingDirectory = minecraftServerDataDir;

      # The actual command to start the server
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
        # Create the main server directory if it doesn't exist
        mkdir -p "${minecraftServerDataDir}"
        chown -R minecraft:minecraft "${minecraftServerDataDir}" # Ensure owned by minecraft user

        # 1. Copy the server JAR
        #    This ensures the server.jar is always present and updated if the derivation changes.
        cp "${paperJarDerivation}/jar/server.jar" "${minecraftServerDataDir}/server.jar"

        # 2. Handle plugins (only JARs)
        mkdir -p "${minecraftServerDataDir}/plugins"
        chown -R minecraft:minecraft "${minecraftServerDataDir}/plugins" # Ensure owned by minecraft user

        #    a. Remove old plugin JARs before copying new ones
        find "${minecraftServerDataDir}/plugins" -maxdepth 1 -name "*.jar" -delete || true

        #    b. Copy new plugin JARs
        #       Note: cp -r is used here to copy contents of the source directory.
        #       Using '.' ensures hidden files are copied too, though less likely for JARs.
        cp -r "${pluginsJarsSrc}/." "${minecraftServerDataDir}/plugins/" || true

        # 3. Handle EULA
        #    Create eula.txt if it doesn't exist in the data directory
        if [ ! -f "${minecraftServerDataDir}/eula.txt" ]; then
          echo "eula=true" > "${minecraftServerDataDir}/eula.txt"
        fi
      '';
    };
  };

  # Define the minecraft user and group explicitly
  # This is needed because we're not using StateDirectory and DynamicUser alone
  # for /opt/minecraft, which has a fixed path.
  users.groups.minecraft = { };
  users.users.minecraft = {
    isSystem = true;
    group = "minecraft";
    # uid = config.ids.uids.minecraft; # You could set a specific uid if desired
  };

  # Manage the /opt/minecraft directory with systemd-tmpfiles
  # This ensures the directory exists and has correct ownership/permissions on boot.
  systemd.tmpfiles.rules = [
    "d '${minecraftServerDataDir}' 0755 minecraft minecraft -"
    "d '${minecraftServerDataDir}/plugins' 0755 minecraft minecraft -" # Ensure plugins dir is also managed
  ];

  networking.firewall = {
    allowedTCPPorts = [
      25565
      8100
    ];
    allowedUDPPorts = [ 19132 ];
  };
}
