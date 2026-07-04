{ config, pkgs, lib, hermes-agent, ... }: {
  imports = [ hermes-agent.nixosModules.default ];

  sops.defaultSopsFile = ../../secrets/hermes-agent.sops.yaml;
  sops.secrets."hermes/env" = { };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    package = hermes-agent.packages.${pkgs.system}.minimal;
    extraDependencyGroups = [ "messaging" ];

    environmentFiles = [ config.sops.secrets."hermes/env".path ];

    settings = {
      model = "openai/deepseek-chat";

      terminal.backend = "local";
      toolsets = [ "all" ];

      compression = {
        enabled = true;
        threshold = 0.85;
      };

      messaging.discord.enabled = true;
    };
  };

  environment.systemPackages = with pkgs; [
    ripgrep
    ffmpeg
  ];
}
