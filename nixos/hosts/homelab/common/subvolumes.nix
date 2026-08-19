{ ... }: {
  # The k8s/backups btrfs subvolume approach was dropped: the subvolumes were
  # never actually created on this host, so /var/lib/rancher and /var/lib/backups
  # are plain directories on the root subvolume. k8s backups use restic against
  # the local-path storage tiers directly (see backup.nix), so no dedicated
  # subvolumes or mounts are needed here.
}
