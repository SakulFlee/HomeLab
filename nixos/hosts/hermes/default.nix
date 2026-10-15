# NixOS system for the Incus instance "hermes".
#
# Hermes Agent (NousResearch hermes-agent), from upstream's own flake: the
# module runs the gateway (`hermes gateway`, systemd unit hermes-agent) and the
# browser dashboard (`hermes dashboard`, unit hermes-backend) as native systemd
# services -- not the upstream OCI container mode, which would have forced this
# instance down the "privileged or VM" fork every container runtime in this
# repository has already taken.
#
# Local models are served by Hermes's OWN managed llama.cpp runtime, not by an
# Ollama sibling: on first model add the package manager downloads a pinned
# llama.cpp build (vulkan backend for AMD) and the gateway supervises
# llama-server on 127.0.0.1:18434 with a persisted API key. The engine and the
# GGUF store both live under HERMES_HOME, i.e. on the hermes-state volume.
#
# See incus.nix for the container-level definition (limits, volumes, the GPU).
{ pkgs, inputs, ... }:
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  networking.hostName = "hermes";

  # Same firewall posture as every other instance: the host and Incus gate
  # inbound traffic -- Caddy's VPN gate on the vhosts, and there is no LAN
  # forward at all -- so a second firewall in the guest would only re-filter
  # what the host already let through.
  networking.firewall.enable = false;

  # Router DNS, same as the other instances (not the host's 192.168.178.200).
  # Needed in earnest here: the first model add downloads a llama.cpp build
  # and a GGUF from the internet.
  networking.nameservers = [ "192.168.178.1" ];

  # Not exposed: Incus reaches the instance via exec, and nothing forwards 22.
  services.openssh.enable = false;

  environment.systemPackages = [ pkgs.curl ];

  # -------------------------------------------------------------------------
  # Graphics stack: mesa's RADV vulkan driver and the loader, staged at
  # /run/opengl-driver.
  # -------------------------------------------------------------------------
  #
  # This is what the downloaded llama.cpp vulkan binary dlopens. Jellyfin
  # deliberately does NOT set this (its VAAPI path needs the state engine, not
  # a GL stack); here the GL stack is the entire point.
  #
  # The iGPU is a gfx1035 (RDNA3, Rembrandt). RADV supports it upstream; no
  # rocmOverrideGfx-style override exists for vulkan because the arch is
  # declared in the driver, not patched in by env.
  hardware.graphics.enable = true;

  # -------------------------------------------------------------------------
  # Hermes
  # -------------------------------------------------------------------------
  services.hermes-agent = {
    enable = true;

    # The host writes this file into the instance (renderedSecrets in
    # incus.nix) from the host's own sops secret hermes-env. It holds the
    # API_SERVER_KEY and the dashboard basic-auth pair -- the same values the
    # k3s deployment used, re-declared on the host so this instance gets bytes
    # and no decryption capability.
    #
    # The module merges this into $HERMES_HOME/.env at activation. That alone
    # is not enough on a first deploy: apply.sh renders the file AFTER the
    # instance is created, so the first activation reads nothing. Both units
    # also get it as a systemd EnvironmentFile below, which is read at every
    # start -- see the unit overrides under "Secrets" below.
    environmentFiles = [ "/var/lib/incus-secrets/hermes-env" ];

    # `hermes dashboard`: the browser admin panel AND everything `serve` gives
    # (the /api/ws and /api/pty sockets Hermes Desktop connects to). One
    # process; you cannot run serve and dashboard together, and dashboard is a
    # superset.
    backend = {
      mode = "dashboard";

      # 0.0.0.0 rather than the loopback default, and deliberate rather than
      # lazy. Two hostnames proxy here (hermes. and hermes-dashboard.), and
      # the dashboard's DNS-rebinding defence accepts only the bound address
      # or ONE declared public_url -- so an address bind would serve exactly
      # one of the two names. Binding all interfaces inside the container is
      # the documented opt-out: the container has only eth0 on incusbr0, there
      # is no LAN forward, and the auth gate still engages because the bind is
      # non-loopback (web_server_boundary.should_require_auth). The VPN gate on
      # the Caddy vhosts is the perimeter, same as jellyfin and paperless.
      host = "0.0.0.0";
      port = 9119;
    };

    settings = {
      # The OpenAI-compatible API server, on :8642 inside the instance, which
      # is what the vhosts route /v1 and /health to (Hermes Desktop and any
      # OpenAI-client use this; the k3s deployment exposed the same surface).
      # Caller auth is the global API server key, read from API_SERVER_KEY in
      # the rendered hermes-env.
      platforms.api_server = {
        enabled = true;
        # Same reasoning as backend.host: bind everything inside the container
        # and let Caddy on the bridge be the only path in.
        extra.host = "0.0.0.0";
      };

      # `model` is deliberately absent. The store starts empty -- you add the
      # first GGUF through the dashboard's Local Models page after boot, which
      # also triggers the llama.cpp engine download, and then set
      # model.default to it.
    };
  };

  # -------------------------------------------------------------------------
  # Secrets
  # -------------------------------------------------------------------------
  #
  # systemd reads EnvironmentFile at every unit start; the activation-time .env
  # merge above cannot, because apply.sh writes the file after the instance is
  # first created. Without these lines both units fail on a first deploy and
  # stay failed until the next nixos-rebuild, and the values in .env lag every
  # secret change until one. With them, apply.sh's secretConsumers restart is
  # sufficient on its own.
  #
  # The gateway and the backend are two processes sharing one HERMES_HOME, so
  # both read the file.
  systemd.services.hermes-agent.serviceConfig.EnvironmentFile = [ "/var/lib/incus-secrets/hermes-env" ];
  systemd.services.hermes-backend.serviceConfig.EnvironmentFile = [ "/var/lib/incus-secrets/hermes-env" ];

  # -------------------------------------------------------------------------
  # Vulkan, for the managed llama-server
  # -------------------------------------------------------------------------
  #
  # The engine Hermes downloads is an upstream UBUNTU build (asset
  # ubuntu-vulkan-x64), so it expects its shared libraries on a conventional
  # loader path. On NixOS that means telling ld.so where they are:
  #
  #   /run/opengl-driver/lib   libvulkan.so.1 plus mesa's RADV stack, staged
  #                            by hardware.graphics.enable above
  #   <stdenv.cc.cc.lib>/lib   libstdc++.so.6 and libgcc_s.so.1, which an
  #                            Ubuntu binary links against and which NixOS
  #                            keeps out of the default search path entirely
  #
  # and telling the vulkan loader which ICD to load, because on NixOS the RADV
  # manifest is not on the loader's default /usr/share/vulkan/icd.d path.
  #
  # Both go on BOTH units: the supervisor that spawns llama-server is reached
  # from either process (a dashboard session and a gateway session both boot
  # the managed server), and the child inherits the unit environment verbatim
  # -- local_runtime/processes.py server_child_env() strips only
  # credential-shaped variables, so LD_LIBRARY_PATH and VK_DRIVER_FILES pass
  # through untouched.
  systemd.services.hermes-agent.environment = {
    LD_LIBRARY_PATH = "/run/opengl-driver/lib:${pkgs.stdenv.cc.cc.lib}/lib";
    VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json";
  };
  systemd.services.hermes-backend.environment = {
    LD_LIBRARY_PATH = "/run/opengl-driver/lib:${pkgs.stdenv.cc.cc.lib}/lib";
    VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json";
  };

  # NOTE: if the vulkan engine fails to start (missing library, ICD not found,
  # a seccomp refusal inside the unprivileged container), the Local Models
  # page's backend selector can force `cpu`. CPU inference on this host is
  # measured working; the engine falls back to the cpu build in that case.
}
