resource "proxmox_virtual_environment_container" "forgejo" {
  node_name     = "aetherium"
  vm_id         = 102
  description   = "Forgejo (NixOS)"
  start_on_boot = true
  started       = true
  unprivileged  = true
  template      = false
  tags          = ["nixos", "forgejo"]

  clone {
    vm_id        = var.template_ct_id
    datastore_id = "local"
  }

  disk {
    datastore_id = "local"
    size         = 48
  }

  initialization {
    hostname = "forgejo"

    ip_config {
      ipv4 {
        address = "10.0.0.102/24"
        gateway = "10.0.0.1"
      }
      ipv6 {
        address = "fdbe::102/64"
        gateway = "fdbe::1"
      }
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 1024
  }

  network_interface {
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
  }

  startup {
    order = 3
  }

  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      clone,
      tags,
      unprivileged,
    ]
  }
}

resource "null_resource" "deploy_flake_forgejo" {
  triggers = {
    container_id = proxmox_virtual_environment_container.forgejo.id
  }
  depends_on = [proxmox_virtual_environment_container.forgejo]

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
              root@10.0.0.102 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Copying repository via tar/ssh..."
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
        -i ${var.ssh_private_key_path} \
        root@10.0.0.102 \
        "rm -rf /etc/nixos && mkdir -p /etc/nixos" && \
      tar cz --owner=0 --group=0 -C ${path.root}/.. . | \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
          -i ${var.ssh_private_key_path} \
          root@10.0.0.102 \
          "tar xz -C /etc/nixos && nix --extra-experimental-features 'nix-command flakes' profile install nixpkgs#git && nixos-rebuild switch --flake /etc/nixos/nixos#forgejo --show-trace && nix-collect-garbage --delete-old"
    EOT
  }
}
