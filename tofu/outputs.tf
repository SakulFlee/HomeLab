output "container_ips" {
  description = "IP addresses of all NixOS containers"
  value = {
    caddy   = proxmox_virtual_environment_container.caddy.initialization[0].ip_config[0].ipv4[0].address
    website = proxmox_virtual_environment_container.website.initialization[0].ip_config[0].ipv4[0].address
  }
}

output "container_ids" {
  description = "Proxmox CT IDs"
  value = {
    caddy   = proxmox_virtual_environment_container.caddy.vm_id
    website = proxmox_virtual_environment_container.website.vm_id
  }
}

output "container_hostnames" {
  description = "Container hostnames"
  value = {
    caddy   = proxmox_virtual_environment_container.caddy.initialization[0].hostname
    website = proxmox_virtual_environment_container.website.initialization[0].hostname
  }
}
