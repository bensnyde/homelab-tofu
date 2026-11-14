locals {
  # Skip loopback and HAOS's internal Docker networks.
  lan_ips = [
    for ip in flatten(proxmox_virtual_environment_vm.this.ipv4_addresses) : ip
    if !startswith(ip, "127.") && !startswith(ip, "172.30.") && !startswith(ip, "172.17.")
  ]
}

output "vm_id" {
  value = proxmox_virtual_environment_vm.this.vm_id
}

locals {
  ip = var.ipv4_cidr != null ? split("/", var.ipv4_cidr)[0] : try(local.lan_ips[0], null)
}

output "ip_address" {
  description = "Static address, or the DHCP address reported by the guest agent."
  value       = local.ip
}

output "url" {
  value = local.ip != null ? "http://${local.ip}:8123" : null
}
