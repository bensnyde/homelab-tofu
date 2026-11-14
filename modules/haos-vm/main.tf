# A Home Assistant OS VM (the official appliance image).
#
# HAOS manages and updates itself (OS, Supervisor, Core, add-ons) from the HA
# web UI; tofu only creates the VM.

# USB passthrough goes through resource mappings, because Proxmox only lets
# root@pam (not API tokens) attach raw host USB devices. Mapping names are
# cluster-wide, so they are prefixed with the VM name.
resource "proxmox_hardware_mapping_usb" "this" {
  for_each = var.usb_devices

  name    = "${var.name}-${each.key}"
  comment = "${var.name}: ${each.key}"
  map = [{
    id      = each.value
    node    = var.node
    comment = each.key
  }]
}

resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  node_name   = var.node
  vm_id       = var.vm_id
  description = "Home Assistant OS, managed by OpenTofu"
  tags        = ["haos", var.name, "opentofu"]

  on_boot         = true
  stop_on_destroy = true

  # HAOS requires UEFI and does not support Secure Boot.
  bios    = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id      = var.datastore
    type              = "4m"
    pre_enrolled_keys = false
  }

  # HAOS ships the QEMU guest agent; it also lets tofu report the DHCP address.
  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.datastore
    file_id      = var.image_id
    interface    = "scsi0"
    size         = var.disk_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge      = var.bridge
    model       = "virtio"
    vlan_id     = var.vlan_id
    mac_address = var.mac_address
  }

  dynamic "usb" {
    for_each = proxmox_hardware_mapping_usb.this
    content {
      mapping = usb.value.name
      usb3    = false
    }
  }

  lifecycle {
    # HAOS updates itself; a newer haos_version must not recreate the VM.
    ignore_changes = [disk[0].file_id]
  }
}

# HAOS has no cloud-init: set the static IP inside the VM via the guest agent.
resource "terraform_data" "network" {
  count            = var.ipv4_cidr != null ? 1 : 0
  triggers_replace = [proxmox_virtual_environment_vm.this.id, var.ipv4_cidr, var.ipv4_gateway, var.dns_servers]

  provisioner "local-exec" {
    command = "${path.module}/set-network.sh"
    environment = {
      PVE_API = "${trimsuffix(var.pve_endpoint, "/")}/api2/json"
      NODE    = var.node
      VMID    = proxmox_virtual_environment_vm.this.vm_id
      CIDR    = var.ipv4_cidr
      GATEWAY = var.ipv4_gateway
      DNS     = join(" ", var.dns_servers)
    }
  }
}
