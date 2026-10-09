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
[ "paperless-media" ]