# NixOS system for the Incus instance "jupyterhub".
#
# JupyterHub: a multi-user notebook platform. Users authenticate against the
# homelab's own Forgejo (OAuth2), and each gets their own notebook server,
# spawned by systemdspawner as a transient systemd unit so one user's kernel is
# an ordinary service that can be inspected and limited independently.
#
# Not the nixpkgs `services.jupyterhub` module, deliberately. That module
# hardcodes `StateDirectory=`, which this repository already found does not
# coexist with an Incus-managed mount (see hosts/omniroute/incus.nix), and it
# offers no clean way to feed a secret from the environment into the generated
# `jupyterhub_config.py`. Both are load-bearing here -- the hub state lives on a
# volume, and the Forgejo client secret must not reach the Nix store -- so the
# unit and the config file are written by hand below, the same shape
# hosts/hermes and hosts/omniroute use.
#
# See incus.nix for the container-level definition (limits, volumes, the GPU).
{ pkgs, ... }:
let
  # The single Forgejo login allowed in, and the Unix account it maps to.
  #
  # JupyterHub's OAuth username is the Forgejo `login` (see username_claim
  # below), and systemdspawner runs each user's server as that Unix account --
  # so the two names must be identical, and the account must be declared here
  # rather than created at runtime: the root filesystem is disposable and an
  # account added with `useradd` would vanish on the next image rebuild. Adding
  # a person therefore means two edits, this binding and the one below.
  forgejoLogin = "sakulflee";

  # Where incus/apply.sh renders the OAuth client secret. Written by the host
  # into the jupyterhub-secrets volume -- see incus.nix.
  secretsDir = "/var/lib/incus-secrets";

  # The OAuth2 application's client id.
  #
  # Not a secret: it is visible in the browser's redirect URL on every login,
  # so it lives openly here rather than in sops. The matching client SECRET is
  # a secret and is rendered into the instance from the host's own sops store --
  # the caddy/renovate/hermes pattern, so this instance holds bytes and has no
  # decryption capability at all.
  #
  # REPLACE THIS after registering the application in Forgejo; the redirect URI
  # to register is https://jupyter.sakul-flee.de/hub/oauth_callback. See
  # NOTES.md.
  forgejoClientId = "REPLACE_WITH_FORGEJO_OAUTH_CLIENT_ID";

  python = pkgs.python3;

  # The hub and its proxy. oauthenticator is the Forgejo integration;
  # jupyterhub-systemdspawner is the spawner class named in the config below.
  # Deliberately NOT the science packages: this environment only ever runs the
  # hub, and a hub crash is a platform outage rather than a lost kernel.
  jupyterhubEnv = python.withPackages (ps: with ps; [
    jupyterhub
    jupyterhub-systemdspawner
    oauthenticator
  ]);

  # The single-user server. Every notebook user runs `jupyterhub-singleuser`
  # from here; the actual kernels are separate (see `kernels`), so this stays
  # the runtime and nothing heavier.
  jupyterlabEnv = python.withPackages (ps: with ps; [
    jupyterhub
    jupyterlab
  ]);

  # The default kernel. A data-science baseline rather than a bare ipykernel:
  # a notebook platform whose first cell needs a `pip install` is a platform
  # nobody uses. GPU compute libraries (torch/ROCm) are deliberately absent --
  # they are large and unfree, and the iGPU is passed through so a kernel that
  # wants them can be added later without touching the container. See NOTES.md.
  scienceEnv = python.withPackages (ps: with ps; [
    ipykernel
    numpy
    pandas
    scipy
    matplotlib
    scikit-learn
  ]);

  kernels = pkgs.jupyter-kernel.create {
    definitions = {
      python3-science = {
        displayName = "Python 3 (data science)";
        argv = [
          "${scienceEnv.interpreter}"
          "-m"
          "ipykernel_launcher"
          "-f"
          "{connection_file}"
        ];
        language = "python";
        logo32 = "${scienceEnv}/${scienceEnv.sitePackages}/ipykernel/resources/logo-32x32.png";
        logo64 = "${scienceEnv}/${scienceEnv.sitePackages}/ipykernel/resources/logo-64x64.png";
      };
    };
  };

  # The whole hub configuration, as a Python file because that is what
  # JupyterHub reads. Four things in here are not guessable and are commented
  # at their line: the Forgejo userdata shape, the oauthenticator 17 rename,
  # where the secret comes from, and user_workingdir.
  jupyterhubConfig = pkgs.writeText "jupyterhub_config.py" ''
    import os

    # TLS terminates at Caddy on the host; the hub speaks plain HTTP on the
    # bridge. 0.0.0.0 rather than a fixed address because Caddy dials the
    # instance's bridge address from outside this container -- see the
    # jupyter.sakul-flee.de block in hosts/caddy/default.nix.
    c.JupyterHub.bind_url = "http://0.0.0.0:8000"

    # Forgejo is the identity provider. systemdspawner runs each user's
    # notebook server as a transient systemd unit, so a runaway kernel is an
    # ordinary service rather than an untracked child process.
    c.JupyterHub.authenticator_class = "oauthenticator.generic.GenericOAuthenticator"
    c.JupyterHub.spawner_class = "systemdspawner.SystemdSpawner"

    c.GenericOAuthenticator.login_service = "Forgejo"
    c.GenericOAuthenticator.client_id = "${forgejoClientId}"

    # From the environment so the secret never reaches the Nix store. apply.sh
    # renders it to /var/lib/incus-secrets/jupyterhub-forgejo-oauth-env, which
    # systemd opens as root before this process starts (EnvironmentFile= in the
    # unit below).
    c.GenericOAuthenticator.client_secret = os.environ["JUPYTERHUB_FORGEJO_CLIENT_SECRET"]

    c.GenericOAuthenticator.oauth_callback_url = "https://jupyter.sakul-flee.de/hub/oauth_callback"

    # The browser-facing endpoint and the two server-side ones. The server-side
    # calls leave the container, resolve forgejo.sakul-flee.de at Cloudflare and
    # arrive back through the host's 443 forward; if the router does not hairpin
    # those, point token_url and userdata_url at the bridge instead --
    # http://10.0.0.101:3000/... -- and leave authorize_url public.
    c.GenericOAuthenticator.authorize_url = "https://forgejo.sakul-flee.de/login/oauth/authorize"
    c.GenericOAuthenticator.token_url = "https://forgejo.sakul-flee.de/login/oauth/access_token"
    c.GenericOAuthenticator.userdata_url = "https://forgejo.sakul-flee.de/api/v1/user"

    # Forgejo's /api/v1/user returns the account name under `login`, not
    # `username`. And oauthenticator 17 renamed `username_key` to
    # `username_claim`; the old spelling is deprecated and warns.
    c.GenericOAuthenticator.username_claim = "login"
    c.GenericOAuthenticator.scope = ["read:user"]

    # An explicit allow-list rather than allow_all: a JupyterHub session is a
    # shell. Anyone with a Forgejo account on the instance can complete the
    # OAuth dance, so the gate that decides who gets a notebook is here, and it
    # is a list rather than a boolean, matching hosts/caddy/hostnames.nix.
    c.Authenticator.allowed_users = {"${forgejoLogin}"}
    c.Authenticator.admin_users = {"${forgejoLogin}"}

    # Open JupyterLab rather than the classic tree view, and serve it from the
    # jupyterlab env above. JUPYTER_PATH is how the spawned server finds the
    # kernels built on the hub side -- without it a user gets a bare Python
    # kernel and the data-science one is invisible.
    c.Spawner.default_url = "/lab"
    c.SystemdSpawner.cmd = "${jupyterlabEnv}/bin/jupyterhub-singleuser"
    c.SystemdSpawner.user_workingdir = "/home/{username}"
    c.SystemdSpawner.environment = {
      "JUPYTER_PATH": "${kernels}",
    }
  '';
in
{
  networking.hostName = "jupyterhub";

  # Unlike every other instance in this repository, the guest firewall is ON.
  # The others disable it because they listen for nothing and the host is the
  # boundary; this one serves a code-execution surface, so the same
  # defence-in-depth reasoning as hosts/omniroute applies -- with the
  # difference that 8000 is the ONLY port to open. Single-user servers bind
  # loopback (the hub's proxy dials them there), so the port the hub itself
  # serves is the entire exposure. Loopback is always allowed by the NixOS
  # firewall module, so the proxy keeps working.
  networking.firewall = {
    enable = true;
    interfaces.eth0.allowedTCPPorts = [ 8000 ];
  };

  # Router DNS, not the host's 192.168.178.200: the OAuth flows and any package
  # download a notebook makes need real outbound resolution.
  networking.nameservers = [ "192.168.178.1" ];

  # Nothing here needs a login over the network; `incus exec` goes through the
  # API.
  services.openssh.enable = false;

  # Mesa's RADV vulkan stack and the loader, staged at /run/opengl-driver. The
  # iGPU is passed through in incus.nix for exactly this; without it a kernel
  # that wants vulkan has a device it cannot open a driver for. Same reasoning
  # and same option as hosts/hermes.
  hardware.graphics.enable = true;

  environment.systemPackages = [
    pkgs.git
    pkgs.curl
    pkgs.jq
  ];

  # ---------------------------------------------------------------------------
  # Accounts
  # ---------------------------------------------------------------------------
  #
  # One Unix account per allowed Forgejo login. Declared here, not created at
  # runtime: see the note on forgejoLogin above. The homes live on the
  # jupyterhub-home volume mounted at /home (incus.nix), which is why
  # createHome lands on persistent storage.
  users.groups.${forgejoLogin} = { };

  users.users.${forgejoLogin} = {
    isNormalUser = true;
    group = forgejoLogin;
    home = "/home/${forgejoLogin}";
    description = "JupyterHub notebook user";
  };

  # The hub's state directory is a volume mounted at /var/lib/jupyterhub
  # (incus.nix) -- the sqlite database and the cookie secret. The hub writes as
  # root, so the mountpoint is root-owned; this rule only guarantees it exists
  # and is not the root filesystem's copy before the volume is there.
  systemd.tmpfiles.rules = [
    "d /var/lib/jupyterhub 0755 root root"
  ];

  # ---------------------------------------------------------------------------
  # The unit
  # ---------------------------------------------------------------------------
  systemd.services.jupyterhub = {
    description = "JupyterHub";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      ExecStart = "${jupyterhubEnv}/bin/jupyterhub --config ${jupyterhubConfig}";

      # Root on purpose, not laziness: systemdspawner creates a transient
      # systemd unit for each user and drops privileges inside it, which needs
      # the hub to talk to the system bus. The instance is already the security
      # boundary (the VPN gate is outside it), so the hub being root here is
      # the same trust level as `incus exec`.
      User = "root";
      WorkingDirectory = "/var/lib/jupyterhub";

      # The Forgejo client secret, as a KEY=value file written by apply.sh.
      # systemd opens it as root before ExecStart. Not optional: on a first
      # deploy jupyterhub.service cannot start until apply.sh has rendered the
      # file and restarted it (secretConsumers in incus.nix), because the
      # config references the variable unconditionally and fails on a KeyError.
      EnvironmentFile = [ "${secretsDir}/jupyterhub-forgejo-oauth-env" ];

      # A crash net rather than a feature. RestartSec is modest: a bad config
      # fails identically on every attempt, and systemd's own start limit is
      # what stops it becoming a hot loop.
      Restart = "always";
      RestartSec = 5;
    };
  };
}
