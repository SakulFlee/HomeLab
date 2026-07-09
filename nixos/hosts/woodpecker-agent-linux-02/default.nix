{ config, pkgs, lib, ... }: {
  imports = [
    ../../modules
    ../../modules/woodpecker-agent.nix
  ];

  networking.hostName = "woodpecker-agent-linux-02";
  system.stateVersion = "26.05";

  sops.defaultSopsFile = ../../secrets/woodpecker.sops.yaml;
  sops.secrets."woodpecker-agent-env" = { };

  services.woodpecker-agent = {
    enable = true;
    agentName = "woodpecker-agent-linux-02";
    environmentFile = config.sops.secrets."woodpecker-agent-env".path;
  };

  nixpkgs.config.allowUnfree = true;
}
