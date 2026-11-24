variable "name" {
  description = "VM name."
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
  type = number
}

variable "disk_gb" {
  description = "HAOS recommends at least 32 GB."
  type        = number
}

variable "datastore" {
  description = "Datastore for the VM disk and EFI vars."
  type        = string
}

variable "bridge" {
  type = string
}

variable "vlan_id" {
  type    = number
  default = null
}

variable "mac_address" {
  description = "Fixed MAC address (useful for a DHCP reservation). null = generated."
  type        = string
  default     = null
}

variable "image_id" {
  description = "Proxmox volume ID of the unpacked HAOS image (see images.tf)."
  type        = string
}

variable "usb_devices" {
  description = "Host USB devices to pass through, as { label = \"vendor:product\" }."
  type        = map(string)
  default     = {}
}

variable "ipv4_cidr" {
  description = "Static address with prefix, set inside HAOS via the guest agent. null = DHCP."
  type        = string
  default     = null

  validation {
    condition     = var.ipv4_cidr == null || can(cidrhost(var.ipv4_cidr, 0))
    error_message = "ipv4_cidr is not a valid address - an unresolved {lan}/{iot} placeholder? Check .env."
  }
}

variable "ipv4_gateway" {
  type    = string
  default = null

  validation {
    condition     = var.ipv4_gateway == null || can(cidrhost("${var.ipv4_gateway}/32", 0))
    error_message = "ipv4_gateway is not a valid address - an unresolved {lan}/{iot} placeholder? Check .env."
  }
}

variable "dns_servers" {
  type    = list(string)
  default = []

  validation {
    condition     = alltrue([for s in var.dns_servers : can(cidrhost("${s}/32", 0))])
    error_message = "dns_servers has an invalid address - an unresolved {lan}/{iot} placeholder? Check .env."
  }
}

variable "pve_endpoint" {
  description = "Proxmox API endpoint (for the guest-agent call that sets the static IP)."
  type        = string
}
