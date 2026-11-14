{
  description = "NixOS hosts managed by OpenTofu";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Not following our nixpkgs on purpose so the nix-community binary cache
    # has pre-built authentik packages.
    authentik-nix.url = "github:nix-community/authentik-nix";
  };

  outputs = inputs@{ nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # Every directory in ./hosts is a host. It becomes buildable once tofu has
      # generated its settings.json (gitignored, so always reference this flake
      # as `path:./nixos#<host>` - a git+file reference would not see it).
      hostDirs = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts);
      hosts = lib.filter (name: builtins.pathExists (./hosts + "/${name}/settings.json"))
        (lib.attrNames hostDirs);

      mkHost = name: lib.nixosSystem {
        specialArgs = {
          inherit inputs;
          settings = lib.importJSON (./hosts + "/${name}/settings.json");
        };
        modules = [
          ./modules
          (./hosts + "/${name}")
        ];
      };
    in
    {
      nixosConfigurations = lib.genAttrs hosts mkHost;
    };
}
