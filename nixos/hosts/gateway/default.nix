# Tailscale gateway: lets your devices (phone, laptop) reach selected homelab
# VMs from anywhere, through your tailnet on Tailscale's hosted service.
#
#   phone (Tailscale app) --WireGuard--> this VM --> k3s apps, Kasm
#
# Nothing is exposed to the internet and no router ports are forwarded: this
# VM and your devices connect out to Tailscale and set up direct encrypted
# tunnels (or, failing that, Tailscale's relays).
#
# This VM advertises a route to each VM in `routeTo` (one /32 each), so devices
# reach those apps but not the rest of the LAN. Public DNS already resolves
# the apps' names (<app>.<k3s domain>, Kasm's domain) to those addresses, so
# the usual URLs work on a phone with Tailscale on.
#
# Login: a one-time auth key (TAILSCALE_AUTHKEY in .env, written to
# /var/lib/secrets/tailscale-authkey). Then approve the routes once in the
# Tailscale admin console. See the README.
{ lib, settings, ... }:
let
  # VMs (names in nixos_vms) that tailnet devices may reach.
  routeTo = [ "k3s" "kasm" ];

  lanHosts = settings.lan_hosts or { };
  routes = map (name:
    assert lib.assertMsg (lanHosts ? ${name}) "gateway: '${name}' is not in nixos_vms";
    "${lanHosts.${name}.ip}/32") routeTo;
in
{
  # Set once at install time; don't change it on an existing host.
  system.stateVersion = "26.05";

  services.tailscale = {
    enable = true;
    openFirewall = true; # UDP 41641, for direct connections
    # IP forwarding + SNAT for the advertised routes: the routed VMs see this
    # VM's LAN address as the source, so they need no changes.
    useRoutingFeatures = "server";
    authKeyFile = "/var/lib/secrets/tailscale-authkey";
    # Applied at login and again on every rebuild (tailscale set).
    extraUpFlags = [ "--hostname=${settings.hostname}" ];
    extraSetFlags = [
      "--advertise-routes=${lib.concatStringsSep "," routes}"
      "--accept-dns=false" # this VM keeps its own DNS servers
    ];
  };
}
