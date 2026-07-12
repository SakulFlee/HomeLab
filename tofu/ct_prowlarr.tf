resource "proxmox_virtual_environment_container" "prowlarr" {
  node_name     = "aetherium"
  vm_id         = 108
  description   = "Prowlarr indexer manager (NixOS)"
  start_on_boot = true
  started       = true
  unprivileged  = true
  template      = false
  tags          = ["nixos", "prowlarr"]

  clone {
    vm_id        = var.template_ct_id
    datastore_id = "local"
  }

  disk {
    datastore_id = "local"
    size         = 8
  }

  initialization {
    hostname = "prowlarr"

    ip_config {
      ipv4 {
        address = "10.0.0.108/24"
        gateway = "10.0.0.1"
      }
      ipv6 {
        address = "fdbe::108/64"
        gateway = "fdbe::1"
      }
    }
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
    swap      = 512
  }

  network_interface {
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
  }

  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      clone,
      tags,
      unprivileged,
      mount_point,
    ]
  }
}

resource "null_resource" "deploy_flake_prowlarr" {
  triggers = {
    container_id = proxmox_virtual_environment_container.prowlarr.id
  }
  depends_on = [proxmox_virtual_environment_container.prowlarr]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Setting mount points on Proxmox host..."
      ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
        ${var.bastion_user}@${var.bastion_host} \
        "pct set 108 \
          --mp0 /mnt/nas/HomeLab-Backups/,mp=/mnt/nas/HomeLab-Backups"

      echo "Waiting for container to become reachable via SSH..."
      PROXY="ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
             ${var.bastion_user}@${var.bastion_host} -W %h:%p"
      i=0
      while [ $i -lt 30 ]; do
        i=$((i + 1))
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
              -i ${var.ssh_private_key_path} \
              root@10.0.0.108 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Copying repository via tar/ssh..."
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
        -i ${var.ssh_private_key_path} \
        root@10.0.0.108 \
        "rm -rf /etc/nixos && mkdir -p /etc/nixos" && \
      tar cz --owner=0 --group=0 -C ${path.root}/.. . | \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
          -i ${var.ssh_private_key_path} \
          root@10.0.0.108 \
          "tar xz -C /etc/nixos && nix --extra-experimental-features 'nix-command flakes' profile install nixpkgs#git && nixos-rebuild switch --flake /etc/nixos/nixos#prowlarr --show-trace && nix-collect-garbage --delete-old"
    EOT
  }
}
