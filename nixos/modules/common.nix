# Base system for every host: boot, static network from settings.json, SSH, nix.
{ pkgs, modulesPath, settings, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # ------------------------------------------------------------- boot ---
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    # grub.devices is filled in by disko from the EF02 partition.
  };
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];

  # ---------------------------------------------------------- network ---
  networking = {
    hostName = settings.hostname;
    useDHCP = false;
    useNetworkd = true;
    # LAN only; hosts open their own service ports.
    firewall.allowedTCPPorts = [ 22 ];
  };

  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "en*";
      address = [ "${settings.ipv4_address}/${toString settings.ipv4_prefix}" ];
      gateway = [ settings.ipv4_gateway ];
      dns = settings.dns_servers;
      linkConfig.RequiredForOnline = "routable";
    };
  };

  time.timeZone = settings.timezone;

  # ----------------------------------------------------------- access ---
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = settings.ssh_public_keys;

  services.qemuGuest.enable = true;

  # -------------------------------------------------------------- nix ---
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [ "https://nix-community.cachix.org" ];
    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  environment.systemPackages = with pkgs; [ vim curl htop ];
}
