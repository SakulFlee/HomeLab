{ config, pkgs, lib, ... }: {
  sops.defaultSopsFile = ../../secrets/woodpecker.sops.yaml;
  sops.secrets = {
    forgejo_client = { };
    forgejo_secret = { };
    agent_secret = { };
  };
  sops.templates."woodpecker-server.env" = {
    content = ''
      WOODPECKER_OPEN=true
      WOODPECKER_HOST=https://woodpecker.sakul-flee.de
      WOODPECKER_ADMIN=sakulflee
      WOODPECKER_FORGEJO=true
      WOODPECKER_FORGEJO_URL=https://forgejo.sakul-flee.de
      WOODPECKER_FORGEJO_CLIENT=%{forgejo_client}
      WOODPECKER_FORGEJO_SECRET=%{forgejo_secret}
      WOODPECKER_DATABASE_DRIVER=postgres
      WOODPECKER_DATABASE_DATASOURCE=postgres://woodpecker@127.0.0.1:5432/woodpecker?sslmode=disable
      WOODPECKER_AGENT_SECRET=%{agent_secret}
      WOODPECKER_BACKEND=docker
      DOCKER_HOST=unix:///run/podman/podman.sock
    '';
    owner = "woodpecker";
    group = "woodpecker";
    mode = "0600";
  };

  users.groups.woodpecker = { };
  users.users.woodpecker = {
    isSystemUser = true;
    group = "woodpecker";
    extraGroups = [ "podman" ];
    home = "/var/lib/woodpecker";
    createHome = true;
  };

  systemd.services.woodpecker-server = {
    description = "Woodpecker CI server";
    documentation = [ "https://woodpecker-ci.org/docs/administration/server-config" ];
    after = [ "network.target" "postgresql.service" ];
    wants = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "woodpecker";
      Group = "woodpecker";
      EnvironmentFile = [ config.sops.templates."woodpecker-server.env".path ];
      ExecStart = "${pkgs.woodpecker-server}/bin/woodpecker-server";
      WorkingDirectory = "/var/lib/woodpecker";
      StateDirectory = "woodpecker";
      Restart = "on-failure";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8000 ];
}
