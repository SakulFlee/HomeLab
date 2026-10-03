# Per-instance Incus project, keyed by instance name.
#
# Separate from incus-instances.nix on purpose, and the reason is the reconcile
# timer. apply.sh takes ONE --project for a whole invocation, so a set of
# instances spanning two projects cannot be reconciled in a single run -- and
# incus-reconcile.timer runs `--all` every fifteen minutes precisely so nothing
# is left waiting on a human. With one global project, every instance would be
# reconciled in the last one's project, which reports the others missing and
# recreates them as duplicates on every sweep.
#
# An instance absent from this map is in Incus's `default` project, which is the
# case for everything that existed before projects were introduced.
#
# Why this is needed at all: Incus resolves a bare instance name against the
# *current* project, so an instance in the forgejo project addressed as plain
# `forgejo` is not found, and `storage volume show` reports its volumes missing
# because volumes are project-scoped. Measured, not assumed:
#
#   incus storage volume list backup --project forgejo  -> (empty)
#   incus storage volume list backup                    -> caddy-data,
#                                                          forgejo-repositories
#
# So moving an instance between projects is a data move, not a rename: the
# volumes must exist in the target project before anything is restored into
# them, or the restore lands where nothing is reading from.
#
# Networks are NOT project-scoped in Incus 7 -- `incus network list --project
# forgejo` lists incusbr0 alongside the rest -- so no features.networks opt-in is
# needed for the bridge to stay usable from another project. Attempting to set it
# fails with "Invalid value for a boolean": it is a bool, not the list of network
# names the Incus 4 documentation suggests.
{
  forgejo = "forgejo";
}
