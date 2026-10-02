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
