# The subordinate gid ranges this host permits LXC containers to map.
#
# Why it is needed at all, and it is worth the length because the reason is not
# obvious from the symptom:
#
#   touch /mnt/nas/Shows/probe
#   touch: Permission denied
#
# An unprivileged instance's uid/gid space is shifted: container uid 0 is host
# uid 1000000, and everything a container process is therefore host 1000000+.
# The NAS mounts force uid=1000 gid=972, so inside a container every share file
# lands on the overflow id -- 65534, "nobody" -- and the process gets the
# *other* permission bits. dir_mode=0775 gives other r-x, hence no writes.
#
# Measured, not assumed: an Alpine container with /mnt/nas/Shows bind-mounted
# reports drwxrwxr-x owned by 65534 65534, and `touch` and `mkdir` both fail
# while the same host can write the same directory. This is the wall the whole
# media stack would otherwise have hit on its first import.
#
# `raw.idmap` is the way through: it adds explicit host<->container mappings on
# top of the shifted default, so a container can be given the host gid it needs
# to be treated as a member of the right group by the CIFS server.
#
# WHAT IS GRANTED. Only gids, and only these three:
#
#   972  media   -- group-writes the media shares, which is the point.
#   26   video   -- /dev/dri nodes for Jellyfin's VAAPI.
#   303  render  -- same, the render node specifically.
#
# Each is a singleton range, so the mapping is one gid wide.
#
# WHAT IS NOT GRANTED, and this is the part that matters:
#
#   * No uid mapping. subUidRanges is deliberately untouched, so no process
#     inside any container can ever hold host uid 1000, and container root
#     stays host 1000000. Mapping uid 1000 would hand a compromised media app
#     the host privileges of `sakulflee`, which is a far larger surface than
#     anything this migration needs.
#
#   * Nothing else on this host is group 972, 26 or 303. Verified 2026-10-09:
#     each of the three contains exactly one member, `sakulflee`, and there are
#     no group-readable paths of consequence. /etc/nixos is root:root, so a
#     container cannot edit the repo that the apply path units watch.
#     /home/sakulflee is 0700, so it is unreachable by group anyway. The sops
#     age key is /etc/ssh/ssh_host_ed25519_key, root-only on the host.
#
#   * No sudo. wheel is password-gated here (verified: `sudo -n true` asks for a
#     password), and group membership does not confer it regardless.
#
# So the worst case of a compromised media instance is that it can modify the
# media library -- which is the access it is being granted on purpose.
#
# WHY GID-ONLY BEATS THE ALTERNATIVE. The other way to make a container able to
# write the NAS is to relax the CIFS options to file_mode=0666 dir_mode=0777.
# That needs no mapping at all, and it is worse: "other" then includes every
# unprivileged instance on this host, so a compromised Caddy could rewrite the
# media library. A group mapping is scoped to the instances that declare it.
#
# MERGING, WHICH IS LOAD-BEARING. This appends; it does not replace. NixOS
# types.listOf concatenates, and the nixpkgs incus module separately declares
#
#   users.users.root.subGidRanges = [ { startGid = 1000000; count = 1000000000; } ];
#
# so root ends up with that range plus the three singletons. If this were ever
# converted to a replacement instead, every container on the host would fail to
# start, since newgidmap would refuse the default 0->1000000 map. Cheap to check
# after a rebuild and worth checking -- the three singletons are appended to
# whatever root already had, in whatever order the two modules merge:
#
#   cat /etc/subgid
#   sakulflee:100000:65536
#   root:1000000:1000000000     <- still present, and it must be
#   root:303:1
#   root:26:1
#   root:972:1
let
  media = import ./media-shares.nix;
in
{
  users.users.root.subGidRanges = [
    {
      # The render node Jellyfin needs for hardware acceleration. Group-only:
      # the devices are also guarded by Incus's own gpu device, and the point
      # is to let the container's jellyfin user open /dev/dri/renderD128.
      startGid = 303;
      count = 1;
    }
    {
      # The video group, same reasoning. 26 is the traditional gid and is what
      # the device nodes on the host are owned by.
      startGid = 26;
      count = 1;
    }
    {
      # The media group, which is the reason this file exists. singleton range
      # so it is this gid and no others.
      startGid = media.mediaGid;
      count = 1;
    }
  ];

  # subUidRanges deliberately has no counterpart. See the header.
}
