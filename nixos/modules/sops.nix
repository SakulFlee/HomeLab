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

  # The login password and session cookie key for the wireguard VM's web UI.
  #
  # Declared on the host for the same reason as everything above: the VM gets
  # the rendered bytes and no decryption capability. That matters more here than
  # for Caddy, because this credential can add a VPN client -- and a VPN client
  # reaches the entire homelab, including this Incus host.
  #
  # Neither may be left unset. wireguard-ui's compiled-in defaults are
  # admin/admin and a fixed session secret that is published in its own source,
  # so an unset value here means an admin UI anyone can log into, whose session
  # cookies anyone can forge.
  sops.secrets.wireguard_ui_password = {};

  # Not a password -- just a long random string used to encrypt session cookies.
  # Generated with `openssl rand -base64 48` when these were created; there is
  # nothing to remember and nothing to rotate unless a cookie is suspected.
  sops.secrets.wireguard_ui_session_secret = {};

  environment.systemPackages = with pkgs; [
    sops
    age
    ssh-to-age
  ];
}
