{ config, lib, pkgs, utils, ... }:
let
  # Storage pools live on the SATA SSD (btrfs), NOT on the NVMe that holds /,
  # /home, /nix and the restic repo. See hardware.nix for the mount.
  #
  # This mirrors the existing separation deliberately: source data on the SSD,
  # backup on the NVMe. Incus does bursty disposable I/O (image imports,
  # instance creation, rootfs reads at every service start) and should not
  # compete with /nix or a 'restic forget --prune' sweep.
  #
  # /var/lib/incus itself -- the dqlite database, sockets and logs -- stays on
  # the NVMe, because it is small and latency-sensitive.
  poolsPath = "/var/lib/incus/pools";
  poolsMount = "${utils.escapeSystemdPath poolsPath}.mount";
in
{
  # Incus replaces k3s as the workload substrate. This phase deliberately keeps
  # k3s running; pools are a sibling subvolume on the same device.
  virtualisation.incus = {
    enable = true;

    # incus-lts (7.0.x) is the module default and is what nixpkgs carries CVE
    # backports for. Set package = pkgs.incus for the rolling build.
    # package = pkgs.incus;

    preseed = {
      # Two pools, split by backup policy rather than by convenience:
      #
      #   backup      restic'd. Anything whose loss you would actually notice.
      #   persistent  NOT restic'd. Deliberately excluded.
      #
      # 'persistent' exists so that "never file-back-up a live Postgres data
      # directory" is structural rather than conventional -- a torn PGDATA copy
      # is worse than no copy. Postgres data dirs go here; the authoritative
      # artifact is always a pg_dump landing in 'backup' (see the dump CronJobs
      # in apps/forgejo, apps/paperless, apps/fluxer). Instance root disks also
      # go here, being reproducible from the flake.
      #
      # No VM pool yet. Incus docs warn against VMs on btrfs and the mitigation
      # is a dir pool, added in the phase that actually provisions VMs.
      storage_pools = [
        {
          name = "backup";
          driver = "btrfs";
          config.source = "${poolsPath}/backup";
        }
        {
          name = "persistent";
          driver = "btrfs";
          config.source = "${poolsPath}/persistent";
        }
      ];

      # Kept distinct from the LAN (192.168.178.0/24) so Caddy can gate on
      # client_ip ranges without ambiguity, and distinct from the VPN range
      # (100.64.0.0/10). NAT on so instances get egress.
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "10.0.0.1/24";
            "ipv4.nat" = "true";
            "ipv6.address" = "none";
          };
        }
      ];

      # Preseed does not populate the default profile's devices by itself, and
      # without a root disk every `incus launch` fails. Root disks live on
      # 'persistent' (reproducible), custom data volumes on 'backup'.
      profiles = [
        {
          name = "default";
          devices = {
            root = {
              path = "/";
              pool = "persistent";
              type = "disk";
            };
            eth0 = {
              name = "eth0";
              network = "incusbr0";
              type = "nic";
            };
          };
        }
      ];
    };
  };

  # Storage pools MUST be mounted before incusd starts. If the mount is missing
  # or failed, incusd must refuse to start rather than silently create the pool
  # directories on the NVMe root filesystem and shadow them once the mount
  # appears. 'requires' + 'after' on the .mount unit gives exactly that.
  #
  # (escapeSystemdPath is used because the mount unit name for a path containing
  # a dash is not guessable by hand -- systemd escapes it as \x2d.)
  systemd.services.incus = {
    after = [ poolsMount ];
    requires = [ poolsMount ];
  };

  # ---------------------------------------------------------------------
  # nftables: MANDATORY for Incus
  #
  # Incus requires the nftables backend; the NixOS module asserts against
  # iptables. Verified safe against the running k3s:
  #
  #  1. No 'flush ruleset' is emitted.
  #     nixos/modules/services/networking/nftables.nix defaults flushRuleset to
  #     (stateVersion < 23.11) || (rulesetFile != null || ruleset != "").
  #     We are 25.11 and leave the ruleset empty (firewall is off), so it stays
  #     false and the generated script contains neither 'flush ruleset' nor
  #     'delete table'. k3s's rules are untouched.
  #
  #  2. 'boot.blacklistedKernelModules = [ "ip_tables" ]' in that same file is
  #     harmless: nixpkgs' iptables symlinks to xtables-nft-multi, so
  #     kube-proxy already uses nf_tables and never loads the legacy module.
  #
  #  3. Incus manages its own 'table incus'; flannel and kube-proxy manage
  #     ip nat / ip filter. No overlap.
  #
  # Reverting, if ever needed, is a single nixos-rebuild switch.
  networking.nftables.enable = true;

  # networking.firewall stays disabled (see configuration.nix) for now: there
  # is no host input filtering, so incusbr0 NATs and forwards freely. That is
  # what we want for the trial, and it keeps k3s's own nftables rules
  # authoritative. Revisit in the final phase, after k3s is gone, with
  # networking.firewall.enable = true and
  # trustedInterfaces = [ "incusbr0" ]. Enabling it earlier would put the NixOS
  # firewall in charge of tables k3s also writes to.
}
