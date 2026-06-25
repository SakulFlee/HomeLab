variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint (e.g. https://192.168.178.200:8006/api2/json)"
  type        = string
  default     = "https://192.168.178.200:8006/api2/json"
}

variable "proxmox_token_id" {
  description = "Proxmox API token ID (e.g. root@pam!tofu)"
  type        = string
  sensitive   = true
}

variable "proxmox_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key for bastion host and container access"
  type        = string
}

variable "template_ct_id" {
  description = "Proxmox template CT ID to clone from (pre-configured NixOS base)"
  type        = number
  default     = 9999
}

variable "bastion_host" {
  description = "SSH jump host (Proxmox node) for reaching LXC containers"
  type        = string
}

variable "bastion_port" {
  description = "SSH port on the jump host"
  type        = number
  default     = 2222
}

variable "bastion_user" {
  description = "SSH user on the jump host"
  type        = string
  default     = "root"
}
