{ config, pkgs, inputs, ... }: 
let
  # The share list, the NAS address and the ownership ids all come from
  # modules/media-shares.nix, which is also what each media instance's
  # incus.nix and hosts/homelab/services/backup.nix read. Before this, the list
  # lived here and nowhere else, so adding a share to the library meant
  # remembering to touch the mounts, the instances and the backup paths by
  # hand.
  media = import ./media-shares.nix;

  mediaGid = media.mediaGid;

  shares = media.shares;

  nasServer = media.nasServer;

  makeMount = shareName: {
    name = "${media.nasMount}/${shareName}";
    value = {
      device = "${nasServer}/${shareName}";
      fsType = "cifs";
      options = [
      # Crucial: Link to the decrypted runtime path provided by sops-nix
        "credentials=/run/secrets/smb_credentials"
        
        # These four ARE the ownership contract for a share on this tree, and
        # mount-media.nix creates the local tree to match them. uid/gid are
        # forced on every file regardless of who writes it, which is what lets
        # an unprivileged instance participate at all: its processes are host
        # uid 1000000+, so without the force they would land on the overflow id
        # and get only the "other" bits -- dir_mode=0775's other is r-x, hence
        # "Permission denied" on every write. Measured: an Alpine container
        # with a share bind-mounted sees 65534 65534 and cannot touch it.
        #
        # What makes it writable from a container is the group mapping declared
        # in modules/media-idmap.nix, which gives its processes host gid 972 so
        # the CIFS server grants them the group bits above. The uid side is
        # deliberately left unmapped.
        "uid=1000"        # Maps files to your local user ID
        "gid=${toString mediaGid}"  # Maps files to the 'media' group
        "file_mode=0664"  # Gives you read/write access
        "dir_mode=0775"   # Gives you read/write/execute on folders
      
        # Automount on-demand so booting doesn't hang if the NAS is asleep
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=60" # Unmounts after inactivity
      ];
    };
  };
in
{
  # Media group for NAS access (sonarr, radarr, jellyfin, sakulflee). Declared
  # here rather than in media-shares.nix because that file is plain data, not a
  # module, and importable from a plain attrset as well as from a module.
  users.groups.media = { gid = mediaGid; };

  # Install the SMB/CIFS client utilities
  environment.systemPackages = [ pkgs.cifs-utils ];

  fileSystems = builtins.listToAttrs (map makeMount shares);
}
