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

  environment.systemPackages = with pkgs; [
    sops
    age
    ssh-to-age
  ];
}
