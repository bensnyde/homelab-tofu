# Shared by every host.
{ inputs, ... }:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disk-config.nix
    ./common.nix
    ./acme.nix
    ./backup.nix
    ./k3s.nix
  ];
}
