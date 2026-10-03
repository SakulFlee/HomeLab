{ lib, pkgs, ... }: {
  imports = [
    ./hardware.nix
    ./kernel.nix
    ./network.nix
    ./services/_.nix

    # Modules
    ../../modules/auto-update.nix
    ../../modules/boot-loader.nix
    ../../modules/dbus.nix
    ../../modules/experimental-features.nix
    ../../modules/fonts.nix
    ../../modules/gc.nix
    ../../modules/locale.nix
    ../../modules/mount-nas.nix
    ../../modules/nixpkgs-unfree.nix
    ../../modules/sops.nix
    ../../modules/ssh.nix
    ../../modules/srv.nix
    ../../modules/system-packages.nix
    ../../modules/system-state.nix
    ../../modules/zram.nix
    ../../modules/zsh.nix

    # Hardware
    ../../hardware/firmware.nix
    ../../hardware/microcode.nix
    ../../hardware/i2c.nix
    ../../hardware/gpu-amdgpu.nix

    # Users
    ../../users/sakulflee.nix
    ../../users/root.nix
  ];

  networking.hostName = "HomeLab";
  networking.firewall.enable = false;
  networking.nameservers = [ "192.168.178.1" ];
  # Hourly restic of the Incus storage pools into the repository the k3s
  # DaemonSet already writes. Until this existed, nothing on this host was
  # backed up at all; see services/backup.nix for the whole story.
  services.restic-backup.enable = true;

  environment.systemPackages = with pkgs; [
    kubectl
    neovim
  ];
}
