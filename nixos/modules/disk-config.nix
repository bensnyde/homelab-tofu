# Partitioning applied by disko during the nixos-anywhere install.
# Hybrid layout: boots with SeaBIOS (EF02) or OVMF (ESP).
{ lib, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = lib.mkDefault "/dev/sda"; # Proxmox scsi0 on virtio-scsi
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02";
        };
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
