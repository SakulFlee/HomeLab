{ config, lib, pkgs, utils, ... }:

# Creates the local media tree on /mnt/media with the same ownership contract
# the NAS presents, so a share behaves identically on either tree.
#
# The contract it is matching is the one in mount-nas.nix, expressed as CIFS
# options there: uid=1000 gid=972 file_mode=0664 dir_mode=0775. The NAS forces
# those on every file; a local btrfs subvolume forces nothing, so this has to
# create the directories to match. If the two ever diverge, a share works on
# one tree and fails on the other, which is precisely the failure mode that
# made the two paths share a single source in modules/media-shares.nix.
#
# A oneshot with requires/after on the .mount unit, rather than
# systemd.tmpfiles.rules, for one concrete reason: tmpfiles rules are applied
# unconditionally, so if the subvolume is missing and the mount has failed,
# they would create /mnt/media/Movies and friends as ordinary directories on
# the NVMe root filesystem. Instances bind-mounting them would then appear to
# work while writing to the wrong disk. Requiring the mount unit makes the
# failure loud instead. This mirrors what incus.service does with
# requires/after on its own .mount unit, for the same reason.
let
  media = import ./media-shares.nix;

  mountUnit = "${utils.escapeSystemdPath media.localMount}.mount";
in
{
  systemd.services.media-tree = {
    description = "Create the local media tree with the NAS's ownership contract";

    after = [ mountUnit ];
    requires = [ mountUnit ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [ pkgs.coreutils ];

    script = ''
      set -eu

      # -m 2775: rwxrwxr-x with setgid. The setgid bit is what makes the group
      # survive a directory created from inside an instance, and it is why a
      # process whose primary group is not media still lands its files in gid
      # 972. Matches dir_mode=0775 on the NAS plus the group inheritance CIFS
      # gets for free from forcegid.
      #
      # -o/-g with the numeric ids rather than the names: the user and group
      # are guaranteed to exist (mount-nas.nix declares the group, and uid 1000
      # is the host login), and numeric keeps this module independent of their
      # definitions.
      ${lib.concatMapStrings (share: ''
        install -d -m 2775 \
          -o ${toString media.mediaUid} -g ${toString media.mediaGid} \
          "${media.localMount}/${share}"
      '') media.shares}

      # Nothing has been stored here and nothing should be yet -- see the
      # measurements in hosts/homelab/hardware.nix and the roots map in
      # media-shares.nix. When the first share is moved onto this tree, the
      # first thing worth adding is a btrfs qgroup limit so a runaway download
      # cannot fill the SSD and take the Incus storage pool down with it,
      # sized against what the pool actually needs rather than guessed here.
    '';
  };
}
