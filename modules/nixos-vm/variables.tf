variable "name" {
  description = "VM name, NixOS hostname and nixos/hosts/<name> directory."
  type        = string
}

variable "node" {
  description = "Proxmox node to create the VM on."
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID (null = next free)."
  type        = number
  default     = null
}

variable "cores" {
  type = number
}

variable "memory_mb" {
  description = "RAM in MiB. The nixos-anywhere kexec step needs at least 1.5 GiB."
  type        = number
}

variable "disk_gb" {
  type = number
}

variable "datastore" {
  description = "Datastore for the VM disk and cloud-init drive."
  type        = string
}

variable "bridge" {
  type = string
}

variable "vlan_id" {
  type    = number
  default = null
}

variable "bootstrap_image_id" {
  description = "Proxmox file ID of the Debian cloud image used to bootstrap the install."
  type        = string
}

variable "ipv4_cidr" {
  description = "Static address with prefix, e.g. 192.0.2.50/24."
  type        = string
}

variable "ipv4_gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "ssh_public_keys" {
  description = "Public keys for the bootstrap user and NixOS root."
  type        = list(string)
}

variable "timezone" {
  type = string
}

variable "guest_agent" {
  description = "Enable the QEMU guest agent device. Must be false for the first apply (the Debian bootstrap image has no agent)."
  type        = bool
  default     = false
}

variable "flake_dir" {
  description = "Absolute path of the NixOS flake (the nixos/ directory)."
  type        = string
}

variable "settings" {
  description = "Extra host settings merged into hosts/<name>/settings.json (read by the NixOS config)."
  type        = any
  default     = {}
}

variable "secrets" {
  description = "Files copied to the VM at install time, as { \"/path/on/vm\" = \"~/local/file\" }."
  type        = map(string)
  default     = {}
}
