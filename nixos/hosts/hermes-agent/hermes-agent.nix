{ config, pkgs, lib, hermes-agent, ... }: {
  imports = [ hermes-agent.nixosModules.default ];

  sops.defaultSopsFile = ../../secrets/hermes-agent.sops.yaml;
  sops.secrets."hermes/env" = { };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    extraDependencyGroups = [ "messaging" ];
    environmentFiles = [ config.sops.secrets."hermes/env".path ];

    settings = {
      # Default model - change with `hermes model` after deploy
      model = "openai/deepseek-chat";

      terminal.backend = "local";
      toolsets = [ "all" ];

      compression = {
        enable = true;
        threshold = 0.85;
      };

      messaging.discord.enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    ripgrep
    ffmpeg
  ];
}
