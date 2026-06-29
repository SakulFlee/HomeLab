{ config, pkgs, lib, ... }: {
  sops.defaultSopsFile = ../../secrets/woodpecker.sops.yaml;
  sops.secrets."woodpecker-server-env" = { };

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
      EnvironmentFile = [ config.sops.secrets."woodpecker-server-env".path ];
      ExecStart = "${pkgs.woodpecker-server}/bin/woodpecker-server";
      WorkingDirectory = "/var/lib/woodpecker";
      StateDirectory = "woodpecker";
      Restart = "on-failure";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8000 ];
}
