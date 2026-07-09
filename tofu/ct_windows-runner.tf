resource "proxmox_virtual_environment_vm" "windows_runner" {
  node_name   = "aetherium"
  vm_id       = 121
  description = "Windows 10 Woodpecker CI runner"
  name        = "woodpecker-agent-windows-01"
  tags        = ["windows", "woodpecker-agent"]
  started     = true
  on_boot     = false

  bios        = "ovmf"
  machine     = "q35"
  scsi_hardware = "virtio-scsi-single"

  cpu {
    cores   = 4
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = 8192
    floating  = 2048
  }

  disk {
    datastore_id = "local"
    interface    = "scsi0"
    size         = 64
    discard      = "on"
    iothread     = true
    ssd          = true
    file_id      = "local:121/vm-121-disk-0.qcow2"
  }

  efi_disk {
    datastore_id = "ssd"
    type         = "4m"
  }

  tpm_state {
    datastore_id = "ssd"
    version      = "v2.0"
  }

  network_device {
    bridge = "aether"
    model  = "virtio"
  }

  operating_system {
    type = "windows"
  }

  agent {
    enabled = true
  }

  lifecycle {
    ignore_changes = [
      cdrom,
      disk[0].file_id,
    ]
  }
}
