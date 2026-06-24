resource "null_resource" "download_template" {
  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = var.bastion_user
      host        = var.bastion_host
      port        = var.bastion_port
      private_key = file(var.ssh_private_key_path)
    }
    inline = [
      <<-EOCMD
        FILE="/var/lib/vz/template/cache/nixos-image-lxc-proxmox-26.05pre-git-x86_64-linux.tar.xz"
        if [ ! -f "$FILE" ]; then
          echo "Downloading NixOS LXC template..."
          curl -fsSL 'https://hydra.nixos.org/build/332076931/download/1/nixos-image-lxc-proxmox-26.05pre-git-x86_64-linux.tar.xz' -o "$FILE"
        else
          echo "Template already exists, skipping download"
        fi
      EOCMD
    ]
  }
}

resource "proxmox_virtual_environment_container" "caddy" {
  node_name    = "aetherium"
  vm_id        = 200
  description  = "Caddy reverse proxy (NixOS)"
  start_on_boot = true
  started      = true
  unprivileged  = false
  template     = false
  tags         = ["nixos", "caddy"]

  features {
    nesting = true
  }

  depends_on = [null_resource.download_template]

  initialization {
    hostname = "caddy"

    ip_config {
      ipv4 {
        address = "10.0.0.200/24"
        gateway = "10.0.0.1"
      }
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

resource "null_resource" "nixos_bootstrap" {
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
      # Ensure LXC knows this is NixOS
      "pct set 200 --ostype nixos",

      # Inject SSH key
      "pct exec 200 -- mkdir -p /root/.ssh",
      "pct exec 200 -- sh -c 'echo \"${var.ssh_public_key}\" >> /root/.ssh/authorized_keys'",
      "pct exec 200 -- chmod 600 /root/.ssh/authorized_keys",

      # Ensure SSH daemon is running
      "pct exec 200 -- systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true",
    ]
  }
}

resource "null_resource" "deploy_flake" {
  depends_on = [null_resource.nixos_bootstrap]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for container to become reachable via SSH..."
      PROXY="ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
             ${var.bastion_user}@${var.bastion_host} -W %h:%p"
      i=0
      while [ $i -lt 30 ]; do
        i=$((i + 1))
        if ssh -o StrictHostKeyChecking=no -o ProxyCommand="$PROXY" \
              -i ${var.ssh_private_key_path} \
              root@10.0.0.200 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Deploying NixOS flake..."
      tar czf - -C ${path.module}/../nixos . | \
        ssh -o StrictHostKeyChecking=no -o ProxyCommand="$PROXY" \
          -i ${var.ssh_private_key_path} \
          root@10.0.0.200 \
          "tar xzf - -C /etc/nixos && nixos-rebuild switch --flake /etc/nixos#caddy --show-trace"
    EOT
  }
}
