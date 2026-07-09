{ config, pkgs, lib, ... }: {
  imports = [
    ../../modules
    ../../modules/woodpecker-agent.nix
  ];

  networking.hostName = "woodpecker-agent-1";
  system.stateVersion = "26.05";

  sops.defaultSopsFile = ../../secrets/woodpecker.sops.yaml;
  sops.secrets."woodpecker-agent-env" = { };

  services.woodpecker-agent = {
    enable = true;
    environmentFile = config.sops.secrets."woodpecker-agent-env".path;
  };

  # Allow unfree (podman pulls unfree images but the agent itself is free)
  nixpkgs.config.allowUnfree = true;
}
