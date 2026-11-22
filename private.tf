# Private values stay in .env, so terraform.tfvars can be committed to this
# (public) repo. In terraform.tfvars, write {domain} and {lan} where your DNS
# zone and LAN prefix go, e.g.
#
#   proxmox_endpoint = "https://{lan}.168:8006/"
#   nixos_vms = { authentik = { ipv4_cidr = "{lan}.50/24", domain = "auth.{domain}" } }
#
# and set TF_VAR_base_domain / TF_VAR_lan_prefix in .env. Values that are
# private as a whole (acme_email, backup_bucket, state_bucket) are plain
# TF_VAR_* entries in .env. Everything else reads the expanded local.* values.

variable "base_domain" {
  description = "DNS zone substituted for {domain} (TF_VAR_base_domain in .env), e.g. example.com."
  type        = string
  default     = ""
}

variable "lan_prefix" {
  description = "First three octets of the LAN, substituted for {lan} (TF_VAR_lan_prefix in .env), e.g. 192.168.1."
  type        = string
  default     = ""

  validation {
    condition     = var.lan_prefix == "" || can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.lan_prefix))
    error_message = "lan_prefix must be three octets without a trailing dot, e.g. 192.168.1."
  }
}

locals {
  # {lan} and {domain} -> values from .env. Unset placeholders are caught by
  # the preconditions in modules/nixos-vm (invalid address) and below.
  _sub = { lan = var.lan_prefix, domain = var.base_domain }

  proxmox_endpoint = replace(replace(var.proxmox_endpoint, "{lan}", local._sub.lan), "{domain}", local._sub.domain)
  ipv4_gateway     = replace(var.ipv4_gateway, "{lan}", local._sub.lan)
  dns_servers      = [for s in var.dns_servers : replace(s, "{lan}", local._sub.lan)]
  pve_domain       = replace(var.pve_domain, "{domain}", local._sub.domain)

  nixos_vms = {
    for name, vm in var.nixos_vms : name => merge(vm, {
      ipv4_cidr   = replace(vm.ipv4_cidr, "{lan}", local._sub.lan)
      domain      = replace(vm.domain, "{domain}", local._sub.domain)
      dns_servers = vm.dns_servers == null ? null : [for s in vm.dns_servers : replace(s, "{lan}", local._sub.lan)]
    })
  }

  haos_vms = {
    for name, vm in var.haos_vms : name => merge(vm, {
      ipv4_cidr   = vm.ipv4_cidr == null ? null : replace(vm.ipv4_cidr, "{lan}", local._sub.lan)
      dns_servers = vm.dns_servers == null ? null : [for s in vm.dns_servers : replace(s, "{lan}", local._sub.lan)]
    })
  }

  lan_hosts = {
    for name, vm in local.nixos_vms : name => {
      ip     = split("/", vm.ipv4_cidr)[0]
      domain = vm.domain
    }
  }

  # Anything still containing a placeholder after substitution.
  unresolved = [for v in flatten([
    local.proxmox_endpoint, local.ipv4_gateway, local.dns_servers, local.pve_domain,
    [for vm in values(local.nixos_vms) : [vm.ipv4_cidr, vm.domain]],
    [for vm in values(local.haos_vms) : [coalesce(vm.ipv4_cidr, "")]],
  ]) : v if strcontains(v, "{")]
}

# Fail early (at plan) if .env wasn't loaded or lacks a value.
check "placeholders" {
  assert {
    condition     = length(local.unresolved) == 0
    error_message = "Unresolved {lan}/{domain} placeholders - set TF_VAR_lan_prefix / TF_VAR_base_domain in .env and `set -a; source .env; set +a`: ${join(", ", local.unresolved)}"
  }
}
