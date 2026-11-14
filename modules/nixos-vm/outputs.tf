output "vm_id" {
  value = proxmox_virtual_environment_vm.this.vm_id
}

output "ip_address" {
  value = local.ip_address
}

output "ssh" {
  value = "ssh root@${local.ip_address}"
}

output "rebuild" {
  description = "Apply later changes to the NixOS config."
  value       = "./scripts/rebuild.sh ${var.name}"
}
