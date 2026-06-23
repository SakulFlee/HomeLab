resource "proxmox_virtual_environment_container" "caddy" {
  node_name    = "proxmox"
  vm_id        = 200
  description  = "Caddy reverse proxy (NixOS)"
  start_on_boot = true
  started      = true
  unprivileged  = true
  template     = false
  tags         = ["nixos", "caddy"]

  initialization {
    hostname = "caddy"

    ip_config {
      ipv4 {
        address = "10.0.0.200/24"
        gateway = "10.0.0.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 0
  }

  network_interface {
    name    = "veth"
    bridge  = "vmbr0"
    enabled = true
  }

  operating_system {
    template_file_id = var.lxc_template
  }

  startup {
    order = 1
  }

  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
    ]
  }
}

resource "null_resource" "nixos_install" {
  depends_on = [proxmox_virtual_environment_container.caddy]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "root"
      host        = "10.0.0.200"
      private_key = file(var.ssh_private_key_path)
    }
    inline = ["echo SSH ready"]
  }

  provisioner "local-exec" {
    command = "nix run github:nix-community/nixos-anywhere -- --flake ${path.module}/../nixos#caddy root@10.0.0.200 -s ${var.ssh_private_key_path}"
  }
}
