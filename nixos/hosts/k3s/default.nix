# Single-node Kubernetes (k3s). Apps live in ./apps: every *.nix file there is
# imported automatically and declares one app (namespace) via homelab.k3s.apps.
{ ... }:
let
  appFiles = builtins.filter (f: builtins.match ".*\\.nix" f != null)
    (builtins.attrNames (builtins.readDir ./apps));
in
{
  imports = map (f: ./apps + "/${f}") appFiles;

  # Set once at install time; don't change it on an existing host.
  system.stateVersion = "26.05";

  homelab.k3s.enable = true;

  # Bundled Traefik ingress controller (LoadBalancer on the node's 80/443).
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
