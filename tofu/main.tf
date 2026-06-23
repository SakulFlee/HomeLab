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
      type        = "ssh"
      user        = var.bastion_user
      host        = var.bastion_host
      port        = var.bastion_port
      private_key = file(var.ssh_private_key_path)
    }
    inline = [
      "pct exec 200 -- ip link set eth0 up",
      "pct exec 200 -- ip addr add 10.0.0.200/24 dev eth0",
      "pct exec 200 -- ip route add default via 10.0.0.1",
      "pct exec 200 -- mkdir -p /root/.ssh",
      "pct exec 200 -- sh -c 'echo \"${var.ssh_public_key}\" >> /root/.ssh/authorized_keys'",
      "pct exec 200 -- chmod 600 /root/.ssh/authorized_keys",
      "pct exec 200 -- systemctl start ssh 2>/dev/null || true",
    ]
  }

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
      set -x
      PROXY="ProxyCommand=ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
        ${var.bastion_user}@${var.bastion_host} -W %h:%p -o StrictHostKeyChecking=no"
      nix run github:nix-community/nixos-anywhere -- \
        --flake ${path.module}/../nixos#caddy \
        --extra-ssh-options "-o $PROXY" \
        root@10.0.0.200
    EOT
  }
}
