#!/usr/bin/env bash
# Apply the NixOS config of an existing VM: ./scripts/rebuild.sh <host> [switch|boot|test|dry-activate]
#
# Builds nixos/hosts/<host> locally and activates it over SSH. The target
# address comes from the host's generated settings.json (run `tofu apply` first).
set -euo pipefail

host=${1:?usage: $0 <host> [switch|boot|test|dry-activate]}
action=${2:-switch}
root=$(cd "$(dirname "$0")/.." && pwd)
settings="$root/nixos/hosts/$host/settings.json"

[[ -f "$settings" ]] || { echo "no $settings - is '$host' in nixos_vms and applied?" >&2; exit 1; }
ip=$(jq -r .ipv4_address "$settings")

export NIX_SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
exec nix --extra-experimental-features "nix-command flakes" run nixpkgs#nixos-rebuild -- \
  "$action" --flake "path:$root/nixos#$host" --target-host "root@$ip" \
  --option extra-substituters "https://nix-community.cachix.org" \
  --option extra-trusted-public-keys "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
