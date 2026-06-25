resource "proxmox_virtual_environment_container" "caddy" {
  node_name    = "aetherium"
  vm_id        = 200
  description  = "Caddy reverse proxy (NixOS)"
  start_on_boot = true
  started      = true
  unprivileged  = true
  template     = false
  tags         = ["nixos", "caddy"]

  clone {
    vm_id        = var.template_ct_id
    datastore_id = "local-lvm"
  }

  initialization {
    hostname = "caddy"

    ip_config {
      ipv4 {
        address = "10.0.0.200/24"
        gateway = "10.0.0.1"
      }
    }

    ip_config {
      ipv6 {
        address = "fdbe::200/64"
        gateway = "fdbe::1"
      }
    }
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 512
  }

  network_interface {
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
  }

  startup {
    order = 1
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      clone,
      unprivileged,
    ]
  }
}

resource "null_resource" "deploy_flake" {
  depends_on = [proxmox_virtual_environment_container.caddy]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for container to become reachable via SSH..."
      PROXY="ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
             ${var.bastion_user}@${var.bastion_host} -W %h:%p"
      i=0
      while [ $i -lt 30 ]; do
        i=$((i + 1))
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
              -i ${var.ssh_private_key_path} \
              root@10.0.0.200 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Deploying NixOS flake..."
      tar czf - -C ${path.module}/../nixos . | \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
          -i ${var.ssh_private_key_path} \
          root@10.0.0.200 \
          "tar xzf - -C /etc/nixos && chown -R 0:0 /etc/nixos && cd /etc/nixos && git add -A . && nixos-rebuild switch --flake /etc/nixos#caddy --show-trace"
    EOT
  }
}
