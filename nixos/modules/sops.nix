{ config, pkgs, inputs, ... }: {
  # Enable sops-nix module
  imports = [
    inputs.sops-nix.nixosModules.sops
  ];

  # Tell SOPS where your encrypted file lives in your repo
  sops.defaultSopsFile = ../secrets.yaml;
  sops.defaultSopsFormat = "yaml";

  # Tell SOPS which keys to use for decryption on the hardware
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Define the secrets
  sops.secrets.smb_credentials = {};

  # Decrypted to /run/secrets/cloudflare_api_token, root-only, on tmpfs.
  #
  # Declared here rather than in the caddy instance so that the instance needs
  # no decryption capability whatsoever. incus/apply.sh reads this file and
  # renders an EnvironmentFile inside the caddy container; caddy therefore holds
  # one token and cannot read anything else in this file -- not the restic
  # password, not the Forgejo JWT secret, not the PIA VPN credentials.
  #
  # The alternative -- mounting the host's SSH identity key into the instance so
  # sops-nix could decrypt there -- was tried and backed out. It works, and it is
  # the wrong shape: it grants a root process in the container the ability to
  # decrypt every value in this file, and the only thing limiting that is
  # remembering not to do it.
  sops.secrets.cloudflare_api_token = {};

  # The client certificate and key the `caddy` instance authenticates to the
  # Incus API with, for the incus.sakul-flee.de vhost.
  #
  # Declared on the host for the same reason as the token above: the instance
  # gets the rendered bytes and no decryption capability. Incus authorises a
  # client by the fingerprint of the certificate it presents, so Caddy holding
  # this key means anything that passes the vhost's VPN gate is a full Incus
  # administrator. That is why the gate is `remote_ip 100.64.0.0/10` and nothing
  # wider -- Incus has no RBAC, so there is no second factor behind it.
  sops.secrets.incus_client_cert = {};

  sops.secrets.incus_client_key = {};

  # The five values services.forgejo.secrets needs, all of them the k3s
  # deployment's rather than fresh ones. Declared here for the same reason as the
  # caddy token above: the instance gets rendered bytes and no decryption
  # capability, so a root process in the forgejo container cannot read the restic
  # password, the Cloudflare token or the VPN credentials out of this file.
  #
  # Declared as a group because they are declared as a group in app.ini, and the
  # reuse is the point rather than an accident:
  #
  #   forgejo_secret_key      Forgejo's own words: "if you lose it, data encrypted
  #                           by it (like 2FA secrets) can no longer be decrypted."
  #                           Regenerating it would lock the account out of the
  #                           database being restored, silently.
  #   forgejo_internal_token  signs the instance's own API credentials
  #   forgejo_jwt_secret      signs the API and Actions tokens clients hold
  #   forgejo_lfs_secret      signs the short-lived LFS bearer tokens
  #   forgejo_smtp_password   the mailer credential
  #
  # The values themselves live in secrets.yaml, and incus/apply.sh reads them
  # from /run/secrets/<name> and renders them into the instance -- see the
  # renderedSecrets stanza in hosts/forgejo/incus.nix for where they land and why
  # that location is not arbitrary.
  sops.secrets.forgejo_secret_key = {};
  sops.secrets.forgejo_internal_token = {};
  sops.secrets.forgejo_jwt_secret = {};
  sops.secrets.forgejo_lfs_secret = {};
  sops.secrets.forgejo_smtp_password = {};

  # The Forgejo runner's identity: the uuid and token Forgejo
  # issued when the runner was registered. These are the
  # runner's *persistent* credentials, not a registration
  # token -- presenting them is what the daemon does on every
  # poll, nothing is consumed, and nothing re-registers.
  #
    # A runner created fresh for the Incus VM, NOT the k3s
    # deployment's runner. Reusing that identity was the first design
    # here and it was wrong: the name it carries (`forgejo-runner-k8s`)
    # describes a platform this runner no longer uses, so every job log
    # line read as though Kubernetes were still involved, and one runner
    # entity accumulated a history spanning two execution models -- the
    # k3s plugin's pods and, now, Docker containers. Those are different
    # things, and a single runner's history is exactly the record you
    # would want to be able to distinguish when debugging.
    #
    # Nothing about the credentials changed shape, though: still the
    # persistent uuid and token, not a registration token, so nothing is
    # consumed on use and nothing has to re-register. Only which runner
    # they belong to.
    #
    # The k3s runner is still registered in Forgejo and still carries
    # these labels, but its credentials are no longer in this repository.
    # Reinstating it means recovering the old pair from history
    # (`git show <commit>:nixos/secrets.yaml`), so if the ability to fall
    # back to it matters, keep a second pair of keys rather than replacing
    # these in place.
  #
  # Declared on the host for the same reason as the caddy
  # token above: the instance gets rendered bytes and no
  # decryption capability, so a root process in the runner VM
  # cannot read the restic password, the Forgejo secrets or
  # the Cloudflare token out of this file.
  sops.secrets.forgejo_runner_uuid = {};
  sops.secrets.forgejo_runner_token = {};

  # Fluxer secrets (from upstream .env + k8s secret mapping)
  sops.secrets.fluxer_postgres_password = {};
  sops.secrets.fluxer_search_api_key = {};
  sops.secrets.fluxer_s3_secret_access_key = {};
  sops.secrets.aws_secret_access_key = {};
  sops.secrets.fluxer_sudo_mode_secret = {};
  sops.secrets.fluxer_connection_initiation_secret = {};
  sops.secrets.fluxer_profile_pseudonym_secret = {};
  sops.secrets.fluxer_gateway_rpc_auth_token = {};
  sops.secrets.fluxer_media_proxy_secret_key = {};
  sops.secrets.fluxer_media_proxy_upload_relay_secret_base64 = {};
  sops.secrets.fluxer_admin_secret_key_base = {};
  sops.secrets.fluxer_admin_oauth_client_secret = {};
  sops.secrets.fluxer_vapid_public_key = {};
  sops.secrets.fluxer_vapid_private_key = {};
  sops.secrets.livekit_api_secret = {};
  sops.secrets.fluxer_erlang_cookie = {};

  # No sops.secrets for the wireguard VM's web UI, and that is a decision rather
  # than an omission.
  #
  # Two were declared here and both are gone:
  #
  #   wireguard_ui_password        WGUI_PASSWORD_FILE is documented upstream as
  #                                "used for db initialization only". The admin
  #                                hash is written once, when the users table is
  #                                empty, and is authoritative from then on. A
  #                                password changed in the UI never comes back to
  #                                sops, so this could not have kept the account
  #                                in sync -- it would have been a secret that
  #                                looked governed and was not. Upstream's own
  #                                guidance is to start as admin/admin and change
  #                                it in the UI, which is what happens.
  #
  #   wireguard_ui_session_secret  would have worked, but only at the cost of an
  #                                ordering constraint that cannot be honoured:
  #                                the UI is reachable only over the VPN, the VPN
  #                                needs this file, and the file is rendered by an
  #                                apply.sh run that has to happen after the guest
  #                                is already up. Rendering it needs root before
  #                                the first boot completes.
  #
  # The accepted consequence of dropping it: the admin UI signs session cookies
  # with the compiled-in default, a constant published in the upstream source, so
  # cookies are forgeable by anyone who has read it. That is tolerable only
  # because the UI is VPN-gated. If this vhost is ever reachable without the
  # tunnel, put the secret back here and re-add the -session-secret flag to the
  # wrapper in hosts/wireguard/wireguard-ui.nix.

  environment.systemPackages = with pkgs; [
    sops
    age
    ssh-to-age
  ];
}
