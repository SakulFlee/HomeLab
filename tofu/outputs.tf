output "container_ip" {
  description = "IP address of the Caddy container"
  value       = "10.0.0.200"
}

output "container_id" {
  description = "Proxmox CT ID"
  value       = proxmox_virtual_environment_container.caddy.vm_id
}

output "container_hostname" {
  description = "Container hostname"
  value       = proxmox_virtual_environment_container.caddy.initialization[0].hostname
}
