resource "proxmox_virtual_environment_container" "caddy" {
  node_name    = "aetherium"
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
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
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
      type                = "ssh"
      user                = "root"
      host                = "10.0.0.200"
      private_key         = file(var.ssh_private_key_path)
      bastion_host        = var.bastion_host
      bastion_port        = var.bastion_port
      bastion_user        = var.bastion_user
      bastion_private_key = file(var.ssh_private_key_path)
    }
    inline = ["echo SSH ready"]
  }

  provisioner "local-exec" {
    command = <<-EOT
      nix run github:nix-community/nixos-anywhere -- \
        --flake ${path.module}/../nixos#caddy \
        -s ${var.ssh_private_key_path} \
        -o "ProxyCommand=ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
            ${var.bastion_user}@${var.bastion_host} -W %h:%p" \
        root@10.0.0.200
    EOT
  }
}
