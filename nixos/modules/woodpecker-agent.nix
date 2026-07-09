{ config, pkgs, lib, ... }:

let
  cfg = config.services.woodpecker-agent;
in {
  options.services.woodpecker-agent = {
    enable = lib.mkEnableOption "Woodpecker CI agent";

    agentName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Display name in Woodpecker UI. Defaults to hostname.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to env file with WOODPECKER_SERVER and WOODPECKER_AGENT_SECRET.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.woodpecker = { };
    users.users.woodpecker = {
      isSystemUser = true;
      group = "woodpecker";
      extraGroups = [ "podman" ];
      home = "/var/lib/woodpecker";
      createHome = true;
    };

    virtualisation.podman = {
      enable = true;
      dockerSocket.enable = true;
    };

    systemd.services.woodpecker-agent = {
      description = "Woodpecker CI agent";
      documentation = [ "https://woodpecker-ci.org/docs/administration/agent-config" ];
      after    = [ "network.target" ];
      wants    = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "woodpecker";
        Group = "woodpecker";
        Environment = [
          "WOODPECKER_MAX_WORKFLOWS=1"
          "WOODPECKER_BACKEND_ENGINE=docker"
          "WOODPECKER_AGENT_LABELS=type=linux"
        ] ++ lib.optional (cfg.agentName != null) "WOODPECKER_AGENT_NAME=${cfg.agentName}";
        ExecStart = "${pkgs.woodpecker-agent}/bin/woodpecker-agent";
        WorkingDirectory = "/var/lib/woodpecker";
        StateDirectory = "woodpecker";
        Restart = "on-failure";
        RestartSec = 5;
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
