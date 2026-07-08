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

    # ddgs provides DuckDuckGo web search — enables the built-in web_search
    # tool without needing terminal/curl (approval prompts). Installed as an
    # extraPythonPackage because it's not a declared dep of hermes-agent.
    # Click is stripped from ddgs's propagatedBuildInputs because it's already
    # in the hermes sealed venv — the collision checker rejects duplicates.
    extraPythonPackages = [
        (pkgs.python312Packages.ddgs.overridePythonAttrs (old: {
          propagatedBuildInputs = lib.filter
            (p: p.pname != "click")
            (old.propagatedBuildInputs or [ ]);
        }))
      ];

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

      matrix = {
        require_mention = false;
        auto_thread = true;
        session_scope = "room";
        e2ee_mode = "optional";
      };
    };
  };

  nix.settings.max-jobs = 1;

  environment.systemPackages = with pkgs; [
    ripgrep
    ffmpeg
  ];
}
