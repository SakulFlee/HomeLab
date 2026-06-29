{ config, pkgs, lib, ... }: {
  sops.defaultSopsFile = ../../secrets/woodpecker.sops.yaml;
  sops.secrets."woodpecker-agent-env" = { };

  virtualisation.podman = {
    enable = true;
    dockerSocket.enable = true;
  };

  systemd.services.woodpecker-agent = {
    description = "Woodpecker CI agent";
    documentation = [ "https://woodpecker-ci.org/docs/administration/agent-config" ];
    after = [ "network.target" "woodpecker-server.service" ];
    wants = [ "woodpecker-server.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "woodpecker";
      Group = "woodpecker";
      EnvironmentFile = [ config.sops.secrets."woodpecker-agent-env".path ];
      ExecStart = "${pkgs.woodpecker-agent}/bin/woodpecker-agent";
      WorkingDirectory = "/var/lib/woodpecker";
      StateDirectory = "woodpecker";
      Restart = "on-failure";
    };
  };
}
