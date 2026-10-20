{ config, lib, pkgs, utils, ... }:
let
  # Storage pools live on the SATA SSD (btrfs), NOT on the NVMe that holds /,
  # /home and /nix. See hardware.nix for the mount.
  #
  # This separation is deliberate: source data on the SSD, system on the NVMe.
  # Incus does bursty disposable I/O (image imports,
  # instance creation, rootfs reads at every service start) and should not
  # compete with /nix.
  #
  # /var/lib/incus itself -- the dqlite database, sockets and logs -- stays on
  # the NVMe, because it is small and latency-sensitive.
  #
  # storage-pools specifically: Incus only accepts pool sources under its state
  # directory if they live in this subdirectory, and rejects anything else with
  # 'Only allowed source path under "/var/lib/incus" is
  # "/var/lib/incus/storage-pools/<name>"'. Mountpoint declared in hardware.nix.
  poolsPath = "/var/lib/incus/storage-pools";
  poolsMount = "${utils.escapeSystemdPath poolsPath}.mount";
in
{
  # OpenTofu owns instance/image/volume/network/profile lifecycle now. The CLI
  # is intentionally available on the host because incus/gen-tf.sh and the
  # import runbook are operated from here, not from a workstation.
  environment.systemPackages = [ pkgs.opentofu ];

  # Incus is the workload substrate. Pools are a sibling subvolume on the same
  # device as the retired k3s storage.
  virtualisation.incus = {
    enable = true;

    # incus-lts (7.0.x) is the module default and is what nixpkgs carries CVE
    # backports for. Set package = pkgs.incus for the rolling build.
    # package = pkgs.incus;

    # Web UI, served by incusd itself on the REST API port. Currently for
    # direct LAN/VPN access at https://192.168.178.200:8443 -- self-signed cert,
    # so expect a browser warning. Caddy fronts this properly in a later phase,
    # where it gets a real certificate and VPN-only gating.
    ui.enable = true;
  };

  # The pool, incusbr0, the default profile and the API listen address moved to
  # OpenTofu (incus/infra, generated from nixos/incus-tf.nix). Preseed is empty
  # on purpose: it would be a second owner of the same objects, and removing an
  # entity from preseed never deletes it anyway. The entities already exist in
  # Incus's database, so a boot before the first apply still finds them.

  # Storage pools MUST be mounted before incusd starts. If the mount is missing
  # or failed, incusd must refuse to start rather than silently create the pool
  # directories on the NVMe root filesystem and shadow them once the mount
  # appears. 'requires' + 'after' on the .mount unit gives exactly that.
  #
  # The unit name must be derived, not written by hand: the 'storage-pools'
  # component contains a dash, which the systemd.unit(5) algorithm escapes, so
  # the real unit is 'var-lib-incus-storage\x2dpools.mount' (verified with
  # systemd-escape on the host). escapeSystemdPath reproduces that exactly.
  systemd.services.incus = {
    after = [ poolsMount ];
    requires = [ poolsMount ];
  };

  # ---------------------------------------------------------------------
  # nftables: MANDATORY for Incus
  #
  # Incus requires the nftables backend; the NixOS module asserts against
  # iptables.
  #
  #  1. No 'flush ruleset' is emitted.
  #     nixos/modules/services/networking/nftables.nix defaults flushRuleset to
  #     (stateVersion < 23.11) || (rulesetFile != null || ruleset != "").
  #     We are 25.11 and leave the ruleset empty (firewall is off), so it stays
  #     false and the generated script contains neither 'flush ruleset' nor
  #     'delete table'.
  #
  #  2. 'boot.blacklistedKernelModules = [ "ip_tables" ]' in that same file is
  #     harmless: nixpkgs' iptables symlinks to xtables-nft-multi.
  #
  #  3. Incus manages its own 'table incus'.
  #
  # Reverting, if ever needed, is a single nixos-rebuild switch.
  networking.nftables.enable = true;

  # networking.firewall stays disabled (see configuration.nix) for now: there
  # is no host input filtering, so incusbr0 NATs and forwards freely.
}
