{ config, ... }:

{
  boot.isContainer = true;
  systemd.mounts = [
    {
      where = "/sys/kernel/debug";
      enable = false;
    }
  ];
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];
}
