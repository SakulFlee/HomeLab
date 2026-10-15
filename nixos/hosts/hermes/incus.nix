# Incus-level definition of the "hermes" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix:
# this is the container, not the software inside it -- the volume list, the
# device map (including the GPU), the limits.
#
# One instance, no Ollama sibling. Hermes ships its own managed llama.cpp
# runtime ("llama-serve"): the gateway downloads a pinned llama.cpp build on
# first model add (hermes_cli/local_runtime/binaries.py; AMD and Intel select
# the vulkan backend) and supervises llama-server on 127.0.0.1:18434. That is
# why this instance, and not a separate ollama box, carries the GPU device.
let
  devices = {
    # Fixed address on incusbr0, same shape as every other instance. Caddy
    # reaches the dashboard (:9119) and the gateway's OpenAI-compatible API
    # (:8642) here. Verified free before assignment: .100-.116 are taken
    # (.110 is wireguard, do not reuse it) and .117 is the first free address.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.117";
    };

    # -------------------------------------------------------------------------
    # The iGPU, for llama.cpp's vulkan backend.
    # -------------------------------------------------------------------------
    #
    # A BARE gpu device, no uid/gid/mode and no idmap -- the same shape
    # jellyfin's incus.nix measured on this host (Incus 7.0.1): renderD128
    # arrives as 0666, so the process can open it as any user and no group
    # mapping is needed. RADV needs only the render node; /dev/kfd is a ROCm
    # surface and is deliberately NOT passed -- the vulkan backend never opens
    # it, and handing over a compute node this instance cannot need is exactly
    # the kind of spare access that has no upside.
    #
    # Coexistence with jellyfin is measured, not assumed: that instance's
    # VAAPI transcode path opens the same card, and the two do not conflict
    # (VAAPI is the state/decode engine, vulkan is compute here). The one real
    # contention is memory: both live on the same 8 GiB iGPU, and the limits
    # below are what turn "two consumers" into a bounded failure.
    gpu = {
      type = "gpu";
    };

    # -------------------------------------------------------------------------
    # Data-bearing volumes on `persistent`, same @hourly/7d snapshot policy as
    # every other instance.
    # -------------------------------------------------------------------------
    hermes-state = {
      type = "disk";
      pool = "persistent";
      source = "hermes-state";
      path = "/var/lib/hermes";
    };
  };
in
{
  description = "Hermes agent (NousResearch hermes-agent) with its managed llama.cpp runtime";

  autostart = true;

  # Sized against the measured peak rather than a guess: the k3s Ollama
  # deployment of the same class of model (Spark-X2.5-4B at 64k context)
  # peaked its pod at ~11.5 GiB, and the documented failure mode of an
  # unbounded KV cache is an OOM that takes the NODE with it. 16 GiB makes
  # that a contained kill of this instance instead. CPU is capped at half the
  # host's 16 threads: inference is bursty, and the host has other guests.
  limits = {
    memory = "16GiB";
    cpu = "8";
  };

  volumes = [
    {
      pool = "persistent";
      name = "hermes-state";
      description = "HERMES_HOME: config, sessions, downloaded llama.cpp engines, GGUF store";

      # The engine binaries and the GGUFs are re-downloadable, but the
      # sessions, the config and the managed llama-server's persisted API key
      # are not, and a bad `hermes update` is exactly what a snapshot is for.
      snapshots = {
        schedule = "@hourly";
        expiry = "7d";
      };
    }
    {
      # No `snapshots` block, and the omission is the point (same reasoning as
      # caddy-secrets): a copy of a live API token is a liability, and nothing
      # here is irreplaceable -- apply.sh rewrites it from the host's decrypted
      # secret on every run.
      pool = "persistent";
      name = "hermes-secrets";
      description = "Host-rendered EnvironmentFiles; the only secret this instance ever sees";
    }
  ];

  devices = devices;

  # Files the host renders into this instance, from secrets the host itself
  # decrypts -- the caddy/renovate pattern, for the same reason: the instance
  # gets rendered bytes and no decryption capability at all. It cannot reach
  # the restic password, the Forgejo JWT secret or the VPN credentials even if
  # it wants to.
  #
  # format=env: each is a single KEY=value line, which is exactly what that
  # format produces and what a systemd EnvironmentFile wants.
  #
  # 0440 root:hermes, not the 0400 root-only default, and load-bearing rather
  # than tidier: both hermes units run as User=hermes and systemd opens
  # EnvironmentFile as root before dropping privileges -- but the module ALSO
  # merges these into $HERMES_HOME/.env at activation, and that install runs
  # as the service owner. At 0400 root:root the units would start and the
  # activation merge would silently warn.
  renderedSecrets = [
    {
      format = "env";
      file = "api-server-key-env";
      env = "API_SERVER_KEY";
      source = "/run/secrets/hermes/api_server_key";
      mode = "0440";
      group = "hermes";
    }
    {
      format = "env";
      file = "dashboard-username-env";
      env = "HERMES_DASHBOARD_BASIC_AUTH_USERNAME";
      source = "/run/secrets/hermes/dashboard_username";
      mode = "0440";
      group = "hermes";
    }
    {
      format = "env";
      file = "dashboard-password-env";
      env = "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD";
      source = "/run/secrets/hermes/dashboard_password";
      mode = "0440";
      group = "hermes";
    }
    {
      format = "env";
      file = "dashboard-session-env";
      env = "HERMES_DASHBOARD_BASIC_AUTH_SECRET";
      source = "/run/secrets/hermes/dashboard_session_secret";
      mode = "0440";
      group = "hermes";
    }
  ];

  # Units inside this instance that read a rendered file, and that apply.sh
  # restarts when the file's contents change. Both units share HERMES_HOME and
  # both read the same .env, so both are consumers.
  #
  # Not optional, and the same situation caddy and renovate document: on a
  # first deploy both units fail outright (systemd refuses a missing
  # EnvironmentFile rather than starting without the variables), and only come
  # up once apply.sh has written the file and restarted them. apply.sh uses an
  # unconditional restart rather than try-restart, precisely because a unit
  # that never started has nothing to try-restart.
  secretConsumers = [
    "hermes-agent.service"
    "hermes-backend.service"
  ];

  # No networkForward. Hermes is reached only through Caddy's VPN-gated vhosts
  # (hermes.sakul-flee.de and hermes-dashboard.sakul-flee.de), which proxy on
  # the bridge. Nothing puts 9119 or 8642 on the LAN, and the managed
  # llama-server binds 127.0.0.1 inside the instance anyway.
}
