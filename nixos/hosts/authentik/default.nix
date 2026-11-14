# authentik identity provider (PostgreSQL is provisioned by the authentik-nix
# module). Served by nginx with a Let's Encrypt cert when a domain is set,
# otherwise directly on :9000 (HTTP) / :9443 (self-signed HTTPS).
{ inputs, lib, pkgs, settings, ... }:
let
  domain = settings.domain or "";
  useNginx = domain != "" && (settings.acme_email or "") != "";
  secretEnv = "/var/lib/authentik-secrets/authentik.env";
  authentikUnits = [
    "authentik.service"
    "authentik-worker.service"
    "authentik-migrate.service"
  ];
in
{
  imports = [ inputs.authentik-nix.nixosModules.default ];

  # Set once at install time; don't change it on an existing host.
  system.stateVersion = "26.05";

  networking.firewall.allowedTCPPorts =
    if useNginx then [ 80 443 ] else [ 9000 9443 ];

  # Generate AUTHENTIK_SECRET_KEY on the VM at first boot, so the secret
  # never touches the OpenTofu state or the Nix store.
  systemd.services.authentik-secret-init = {
    description = "Generate authentik secret key";
    wantedBy = [ "multi-user.target" ];
    before = authentikUnits;
    requiredBy = authentikUnits;
    path = [ pkgs.openssl pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -s ${secretEnv} ]; then
        install -d -m 0700 "$(dirname ${secretEnv})"
        umask 077
        echo "AUTHENTIK_SECRET_KEY=$(openssl rand -hex 50)" > ${secretEnv}
      fi
    '';
  };

  services.authentik = {
    enable = true;
    environmentFile = secretEnv;
    settings = {
      disable_startup_analytics = true;
      avatars = "initials";
    };
    nginx = lib.mkIf useNginx {
      enable = true;
      enableACME = true;
      host = domain;
    };
  };

  homelab.backup = {
    postgresql.databases = [ "authentik" ];
    paths = [
      "/var/lib/authentik-secrets"
      # Media dir location depends on the module's state dir.
      "/var/lib/authentik/media"
      "/var/lib/private/authentik/media"
    ];
  };
}
