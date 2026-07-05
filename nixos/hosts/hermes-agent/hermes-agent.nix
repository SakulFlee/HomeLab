{ config, pkgs, lib, hermes-agent, ... }: {
  imports = [ hermes-agent.nixosModules.default ];

  sops.defaultSopsFile = ../../secrets/hermes-agent.sops.yaml;
  sops.secrets."hermes-env" = { };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    # Use the upstream "full" hermes-agent package (= `default`), which
    # ships a pre-baked venv with anthropic, messaging, matrix, honcho,
    # voice, and all platform backends (nix/packages.nix:46).
    #
    # extraDependencyGroups stays empty: when non-empty, the NixOS module
    # rebuilds the venv via `package.override { extraDependencyGroups = ...; }`
    # in nix/nixosModules.nix:13-16, hitting a uv2nix quirk where only
    # the first named group is honored.
    package = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
    extraDependencyGroups = [ ];

    environmentFiles = [ config.sops.secrets."hermes-env".path ];

    authFile = pkgs.writeText "auth.json" "{}";

    settings = {
      model = {
        provider = "opencode-go";
        default = "deepseek-v4-flash";
      };

      terminal.backend = "local";
      terminal.cwd = "/var/lib/hermes/workspace";
      toolsets = [ "all" ];

      compression = {
        enabled = true;
        threshold = 0.85;
      };

      messaging.discord.enabled = true;
    };
  };

  nix.settings.max-jobs = 1;

  environment.systemPackages = with pkgs; [
    ripgrep
    ffmpeg
  ];
}
