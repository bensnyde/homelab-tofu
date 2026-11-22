terraform {
  required_version = ">= 1.10.0" # state encryption + variables in backend/encryption

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.100.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
  }
}

provider "proxmox" {
  endpoint = local.proxmox_endpoint
  # If null, the provider falls back to the PROXMOX_VE_API_TOKEN env var.
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # Importing a cloud image as a VM disk runs over SSH on the PVE node.
  ssh {
    agent    = true
    username = var.proxmox_ssh_user

    # Don't rely on the node name resolving; use the endpoint's host.
    node {
      name    = var.proxmox_node
      address = regex("^https?://([^:/]+)", local.proxmox_endpoint)[0]
    }
  }
}
