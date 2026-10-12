# Volumes replicated by the Syncthing hub (nixos/hosts/syncthing).
#
# The single source of truth for what the hub mirrors read-only. Each entry
# names an Incus custom volume on the `persistent` pool in the `default`
# project that some instance produces. Two consumers read this list and can
# never drift from each other:
#
#   * hosts/syncthing/incus.nix mounts every volume read-only in the hub
#   * hosts/syncthing/default.nix declares a sendonly Syncthing folder over it
#
# See hosts/syncthing/NOTES.md ("Replication standard") for the contract a
# producer follows:
#
#   - The volume lives in the `default` Incus project, on the `persistent`
#     pool, attached to the producer's own instance. A volume in another
#     project is invisible to the hub no matter what.
#   - The producer writes `<volume>/.stfolder` itself. The hub mounts the
#     volume read-only and cannot create the marker Syncthing needs before it
#     will scan a folder; without it the folder sits "stopped" forever.
#   - The hub's folder for the volume is `sendonly`: it is a copy, never a
#     writer, so it also carries no versioning.
#
# minecraft-backups is the second entry, and it is deliberately NOT the instance's
# data volume. What gets replicated is the daily archive, not the live world: a
# world synced file-by-file re-ships megabytes of region files on every save and
# races the server's own writes, whereas an archive is small, immutable and
# append-only. The producer archives first and replicates the archive; see
# hosts/minecraft/default.nix and hosts/minecraft/README.md.
#
# hytale-backups is the third, and reaches the same place by a different route:
# the archive is not made by a unit at all, it is made by the game server, which
# flushes its own resources to disk before zipping them. That is why this one can
# be produced with zero downtime while minecraft-backups cannot -- see
# hosts/hytale/default.nix for the evidence and hosts/hytale/README.md.
[ "paperless-media" "minecraft-backups" "hytale-backups" ]