{ config, pkgs, inputs, ... }: 
let 
  shares = [
    "personal_folder"
    "Movies"
    "NSFW"
    "Shows"
  ];

  nasServer = "//192.168.178.250";

  makeMount = shareName: {
    name = "/mnt/nas/${shareName}";
    value = {
      device = "${nasServer}/${shareName}";
      fsType = "cifs";
      options = [
      # Crucial: Link to the decrypted runtime path provided by sops-nix
        "credentials=/run/secrets/smb_credentials"
        
        "uid=1000"        # Maps files to your local user ID
        "gid=${toString config.users.groups.media.gid}"  # Maps files to the 'media' group
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
  # Media group for NAS access (sonarr, radarr, jellyfin, sakulflee)
  users.groups.media = {};

  # Install the SMB/CIFS client utilities
  environment.systemPackages = [ pkgs.cifs-utils ];

  fileSystems = builtins.listToAttrs (map makeMount shares);
}
