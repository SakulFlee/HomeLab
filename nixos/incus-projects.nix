# Incus projects this host owns, keyed by PROJECT name (not by instance).
#
# Separate from incus-instance-projects.nix, which is keyed by instance name and
# answers "which project is this instance in". This file answers "what should
# this project look like", and the two have different keys on purpose: two
# instances can share a project, and a project can exist before anything is
# placed in it.
#
# Presence in this map is what makes apply.sh create the project. A project
# listed only in incus-instance-projects.nix is one this host expects to exist
# but does not manage the shape of.
#
# Why it has to exist at all: the nixpkgs `incus` module has no `projects`
# option. `virtualisation.incus.storage_pools` applies to the `default` project
# only and there is nothing else to hang project config off, so without this a
# project is something a human types once into a live Incus and it is not
# recorded anywhere in the repository.
#
# Storage pools deliberately do NOT appear here. They are global records, not
# per-project: one `incus storage list` row per pool, no project dimension, and
#
#   incus storage create --project forgejo persistent btrfs …
#     Error: The storage pool already exists: The record already exists
#
# so a second project cannot have a second pool under the same name. Volumes
# *inside* a shared pool are project-scoped regardless, which is all the
# isolation this needs: `forgejo-postgres` in one project cannot collide with
# `forgejo-postgres` in another, and neither is visible to the other.
{
  forgejo = {
    description = "HomeLab Forgejo (git forge, its own Postgres, its own LFS)";

    # Images are project-scoped in Incus, so a project cannot use an image that
    # was imported into another one:
    #
    #   incus image list                   -> 22 images
    #   incus image list --project forgejo -> none
    #
    # This has to be true or apply.sh cannot import at all -- `incus project
    # create` defaults it to false, and the first attempt at this project failed
    # with
    #
    #   Error: Failed creating instance record: Failed initializing instance:
    #          Failed getting root disk: No root device could be found
    #
    # which reads like a storage problem and is not one. The pools were visible
    # to the project the whole time; what the project could not see was the
    # image that supplies the root disk.
    #
    # Measured while this was false: a project-scoped image lookup fell through
    # and returned the *default* project's image, so apply.sh's "is this build
    # already imported?" fast path matched, the import was skipped, and the run
    # went on to `incus --project forgejo create <default fingerprint>`:
    #
    #   Error: Image "082a1138..." not found
    #
    # So this key is not cosmetic -- it changes what the reconciler *sees*, not
    # just what it may do.
    features.images = true;

    # Profiles are shared with the default project, not copied. This is load
    # bearing and was the actual cause of the first failure, which is worth
    # spelling out because the error names neither profiles nor projects:
    #
    #   Error: Failed creating instance record: Failed initializing instance:
    #          Failed getting root disk: No root device could be found
    #
    # A new Incus project gets its own auto-created `default` profile, and that
    # profile has no devices in it at all:
    #
    #   incus profile show default                      -> devices: { eth0, root }
    #   incus profile show default --project forgejo    -> devices: {}
    #
    # `root` is the instance's root disk on pool `persistent` and `eth0` is the
    # NIC on incusbr0. `incus create … -p default` in a project whose profile has
    # neither finds no root disk to put the image in -- which is the error above,
    # and it reads exactly like a storage-pool problem. The pools were fine.
    #
    # features.profiles = false means "this project may use profiles from the
    # default project", and `-p default` then resolves to the one that has the
    # devices. Verified on a throwaway project:
    #
    #   incus project create probe-scratch
    #   incus profile show default --project probe-scratch   -> devices: {}
    #   incus project set probe-scratch features.profiles=false
    #   incus profile show default --project probe-scratch   -> eth0 + root
    #
    # Sharing is also the right shape rather than a workaround. The default
    # profile is host infrastructure -- the root disk and the bridge NIC -- and
    # what the project is meant to isolate is the instance and its volumes, not
    # the NIC the instance is plugged into.
    #
    # ORDERING IS LOAD BEARING. Incus refuses the transition once the project
    # holds anything:
    #
    #   Error: Project feature "features.profiles" cannot be disabled on
    #          non-empty projects
    #
    # so this has to be set while the project is still empty -- before the image
    # import, before the volumes, before the instance. incus/apply.sh calls
    # ensure_project as the first thing apply_instance does, precisely so the
    # window is guaranteed rather than incidental. An auto-created default
    # profile does NOT count as non-empty: verified on a throwaway project that
    # `incus project create` followed immediately by this key succeeds, and only
    # fails once an image has been imported.
    #
    # If this ever needs changing on the live project, delete the instances and
    # images from it first. There is no in-place conversion.
    features.profiles = false;

    # features.networks is deliberately absent. Networks are not project-scoped
    # in Incus 7 -- `incus network forward list incusbr0 --project forgejo`
    # returns the same forwards as without it, verified on the live host -- and
    # setting the key is not a no-op: it asks the project to own its own
    # networks, which would mean incusbr0 and its forwards had to be recreated
    # inside the project. It is also a boolean in Incus 7 despite the Incus 4
    # documentation implying a list of network names, and passing a list gives
    # "Invalid value for a boolean".
    #
    # features.storage.volumes and features.storage.buckets are left at their
    # defaults (true). Volumes have to be permitted -- they are project-scoped,
    # which is the isolation the project exists for.
  };
}