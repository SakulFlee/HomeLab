{ pkgs, ... }: {
  # NixOS system container for the Incus instance "forgejo".
  #
  # First real workload moved off k3s. Deliberately minimal for now: this file
  # exists so the image builds and the deploy path is proven end to end. The
  # actual Forgejo service (version pin, Postgres, restore of the dumped repo
  # volume) comes next, once the instance is running.

  networking.hostName = "forgejo";

  # Same reasoning as caddy: the host firewall gates this instance.
  networking.firewall.enable = false;
  networking.nameservers = [ "192.168.178.1" ];

  services.openssh.enable = false;

  environment.systemPackages = with pkgs; [
    curl
    git
    jq
  ];

  # Postgres will live here once the CNPG cluster is replaced. Left disabled so
  # the first boot has nothing to restore into.
  services.postgresql.enable = false;
}