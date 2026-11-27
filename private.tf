# Private values stay in .env, so terraform.tfvars can be committed to this
# (public) repo. In terraform.tfvars, write {domain} and {lan} where your DNS
# zone and LAN prefix go ({iot}: the IoT network's prefix, for Home Assistant), e.g.
#
#   proxmox_endpoint = "https://{lan}.168:8006/"
#   nixos_vms = { authentik = { ipv4_cidr = "{lan}.50/24", domain = "auth.{domain}" } }
#
# and set TF_VAR_base_domain / TF_VAR_lan_prefix in .env. Values that are
# private as a whole are TF_VAR_* entries in .env (acme_email; backup_bucket and
# state_bucket via B2_BACKUP_BUCKET / B2_TFSTATE_BUCKET). Everything else reads
# the expanded local.* values.

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

variable "iot_prefix" {
  description = "First three octets of the IoT network, substituted for {iot} (TF_VAR_iot_prefix in .env), e.g. 192.168.3. Used by Home Assistant, which stays on the IoT VLAN with its devices."
  type        = string
  default     = ""

  validation {
    condition     = var.iot_prefix == "" || can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.iot_prefix))
    error_message = "iot_prefix must be three octets without a trailing dot, e.g. 192.168.3."
  }
}

locals {
  # {lan} and {domain} -> values from .env. Unset placeholders are caught by
  # the preconditions in modules/nixos-vm (invalid address) and below.
  # An unset {iot} stays in place, so the check below catches it.
  _sub = { lan = var.lan_prefix, domain = var.base_domain, iot = var.iot_prefix != "" ? var.iot_prefix : "{iot}" }

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
      ipv4_cidr    = vm.ipv4_cidr == null ? null : replace(replace(vm.ipv4_cidr, "{lan}", local._sub.lan), "{iot}", local._sub.iot)
      ipv4_gateway = vm.ipv4_gateway == null ? null : replace(replace(vm.ipv4_gateway, "{lan}", local._sub.lan), "{iot}", local._sub.iot)
      dns_servers  = vm.dns_servers == null ? null : [for s in vm.dns_servers : replace(replace(s, "{lan}", local._sub.lan), "{iot}", local._sub.iot)]
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
    [for vm in values(local.haos_vms) : [coalesce(vm.ipv4_cidr, ""), coalesce(vm.ipv4_gateway, ""), vm.dns_servers == null ? [] : vm.dns_servers]],
  ]) : v if strcontains(v, "{")]
}

# Fail early (at plan) if .env wasn't loaded or lacks a value.
check "placeholders" {
  assert {
    condition     = length(local.unresolved) == 0
    error_message = "Unresolved {lan}/{iot}/{domain} placeholders - set TF_VAR_lan_prefix / TF_VAR_iot_prefix / TF_VAR_base_domain in .env and `set -a; source .env; set +a`: ${join(", ", local.unresolved)}"
  }
}
