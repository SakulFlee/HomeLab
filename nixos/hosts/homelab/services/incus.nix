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
  #
  # storage-pools specifically: Incus only accepts pool sources under its state
  # directory if they live in this subdirectory, and rejects anything else with
  # 'Only allowed source path under "/var/lib/incus" is
  # "/var/lib/incus/storage-pools/<name>"'. Mountpoint declared in hardware.nix.
  poolsPath = "/var/lib/incus/storage-pools";
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

    # Web UI, served by incusd itself on the REST API port. Currently for
    # direct LAN/VPN access at https://192.168.178.200:8443 -- self-signed cert,
    # so expect a browser warning. Caddy fronts this properly in a later phase,
    # where it gets a real certificate and VPN-only gating.
    ui.enable = true;

    preseed = {
      # Listen on the LAN address rather than 0.0.0.0 so the API (which is
      # root-equivalent access to this host once authenticated) is not reachable
      # from any other interface. VPN clients can reach the same address because
      # 192.168.178.0/24 is inside the tunnel's allowedIPs.
      #
      # Enabling this is what makes the web UI reachable over TCP at all -- by
      # default incusd only serves its unix socket.
      config."core.https_address" = "192.168.178.200:8443";

      # Which browser origins may open a websocket against the API.
      #
      # Empty by default, and Incus then accepts *same-origin* requests only --
      # shared/ws/upgrader.go compares the Origin header's host against the
      # request Host, falling back to this list. The Incus CLI sends no Origin at
      # all, so `incus webui`, `incus exec` and `incus console` against the
      # direct address all work with this unset. That is exactly why the UI was
      # fine locally and broken only through Caddy.
      #
      # Set together with `header_up Host {host}` in the Caddy vhost, and the two
      # are belt and braces: that directive makes the Host comparison succeed,
      # and this makes the endpoint work whatever Host arrives as. With either
      # one missing, Terminal and Console fail with "WebSocket is closed before
      # the connection is established" while every plain API call still succeeds.
      #
      # Narrow on purpose. A websocket that can drive an operation is
      # effectively root on this host, so this names the single hostname the UI
      # is served from and nothing more.
      config."core.https_allowed_websocket_origin" = "https://incus.sakul-flee.de";

      # One pool. There used to be two, `backup` and `persistent`, and the
      # split between them was a COMMENT, not a mechanism.
      #
      # Verified on the running host before the merge: both were
      # `driver: btrfs` with `source: /var/lib/incus/storage-pools/<name>`,
      # on the same filesystem, with no quota and no size limit. Nothing
      # enforced a difference. What separated them was a paragraph.
      #
      # The earlier version of the pool comment claimed `backup` was restic'd
      # and `persistent` was not. Both halves were wrong, and by the time the
      # pools were merged the second half was wrong twice over: Phase 0 had put
      # a restic binary, service and timer on this host backing up BOTH pool
      # paths (nixos/hosts/homelab/services/backup.nix). The DaemonSet claim in
      # the old text -- that homelab-restic was the only restic anywhere -- was
      # already stale when it was written.
      #
      # So the split bought nothing and cost a decision for every new volume.
      # The three volumes in `backup` (caddy-data, forgejo-data, and the empty
      # orphan forgejo-repositories) were moved into `persistent` with
      # `incus storage volume move`, which on btrfs within one filesystem is a
      # subvolume snapshot: near-instant, no extra space, description and
      # config carried over. Then `incus storage pool delete backup`.
      #
      # Removing a pool from this list does NOT delete it: NixOS's own
      # `virtualisation.incus.preseed` documentation states preseed never
      # removes entities. The pool has to be deleted by hand *after* a rebuild
      # with this list already updated -- otherwise the next switch re-creates
      # it empty. The reverse order (delete, then rebuild) is the trap.
      #
      # `persistent` therefore no longer claims anything about backups. Naming
      # a volume after its intended retention is still useful documentation
      # even when nothing enforces it. What must not be repeated is the
      # converse mistake: a PGDATA copy is not a backup, and a pg_dump is.
      # Those are separate claims, and the old text used the first to argue
      # for the second.
      #
      # No VM pool yet. Incus docs warn against VMs on btrfs and the mitigation
      # is a dir pool, added in the phase that actually provisions VMs.
      storage_pools = [
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
      # 'persistent', which is now the only pool.
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
