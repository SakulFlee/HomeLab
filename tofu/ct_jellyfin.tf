resource "proxmox_virtual_environment_container" "jellyfin" {
  node_name     = "aetherium"
  vm_id         = 107
  description   = "Jellyfin media server (NixOS)"
  start_on_boot = true
  started       = true
  unprivileged  = true
  template      = false
  tags          = ["nixos", "jellyfin"]

  clone {
    vm_id        = var.template_ct_id
    datastore_id = "local"
  }

  disk {
    datastore_id = "local"
    size         = 32
  }

  initialization {
    hostname = "jellyfin"

    ip_config {
      ipv4 {
        address = "10.0.0.107/24"
        gateway = "10.0.0.1"
      }
      ipv6 {
        address = "fdbe::107/64"
        gateway = "fdbe::1"
      }
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
    swap      = 1024
  }

  network_interface {
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
  }

  mount_point {
    slot   = 0
    path   = "/mnt/nas/music"
    volume = "/mnt/nas/music"
  }

  mount_point {
    slot   = 1
    path   = "/mnt/nas/shows"
    volume = "/mnt/nas/shows"
  }

  mount_point {
    slot   = 2
    path   = "/mnt/nas/movies"
    volume = "/mnt/nas/movies"
  }

  mount_point {
    slot   = 3
    path   = "/mnt/nas/nsfw"
    volume = "/mnt/nas/nsfw"
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

resource "null_resource" "deploy_flake_jellyfin" {
  triggers = {
    container_id = proxmox_virtual_environment_container.jellyfin.id
  }
  depends_on = [proxmox_virtual_environment_container.jellyfin]

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
              root@10.0.0.107 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Copying repository via tar/ssh..."
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
        -i ${var.ssh_private_key_path} \
        root@10.0.0.107 \
        "rm -rf /etc/nixos && mkdir -p /etc/nixos" && \
      tar cz --owner=0 --group=0 -C ${path.root}/.. . | \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
          -i ${var.ssh_private_key_path} \
          root@10.0.0.107 \
          "tar xz -C /etc/nixos && nix --extra-experimental-features 'nix-command flakes' profile install nixpkgs#git && nixos-rebuild switch --flake /etc/nixos/nixos#jellyfin --show-trace && nix-collect-garbage --delete-old"
    EOT
  }
}
