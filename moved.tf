# State moves from the single-VM layout to modules. They are harmless once
# applied and can be deleted after every state has been migrated.

moved {
  from = proxmox_download_file.debian
  to   = proxmox_download_file.debian[0]
}

moved {
  from = proxmox_virtual_environment_vm.authentik
  to   = module.nixos_vm["authentik"].proxmox_virtual_environment_vm.this
}

moved {
  from = terraform_data.nixos_install
  to   = module.nixos_vm["authentik"].terraform_data.install
}

moved {
  from = local_file.nixos_settings
  to   = module.nixos_vm["authentik"].local_file.settings
}
