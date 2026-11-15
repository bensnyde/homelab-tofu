# Kasm Workspaces (browser-streamed desktops and apps in containers), using
# the NixOS services.kasmweb module: the Kasm services run as Docker
# containers, and session containers are started by the Kasm agent on the
# same Docker daemon.
#
#   Web UI: https://<domain>/ (Let's Encrypt), or https://<vm-ip>/ (self-signed)
#   Login:  admin@kasm.local, password in /var/lib/kasmweb-secrets/admin-password
#           user@kasm.local,  password in /var/lib/kasmweb-secrets/user-password
#
# The passwords only seed the database on first start. Changing them in the
# UI later is fine; the files are not read again after that.
{ config, lib, pkgs, settings, ... }:
let
  domain = settings.domain or "";
  useTls = domain != "" && (settings.acme_email or "") != "";
  dataDir = config.services.kasmweb.datastorePath;
  secretDir = "/var/lib/kasmweb-secrets";
  dumpDir = "/var/backup/kasm";

  # The module's init script inserts these options unquoted into a shell
  # script, so a command substitution is evaluated there at runtime. That
  # keeps the real values out of the world-readable Nix store.
  secretNames = [ "admin-password" "user-password" "manager-token" "guac-token" "registration-token" ];
  fromFile = name: "$(cat ${secretDir}/${name})";
in
lib.mkMerge [{
  # Set once at install time; don't change it on an existing host.
  system.stateVersion = "26.05";

  # Kasm's packaged config/web assets are under a proprietary license.
  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "kasmweb";

  virtualisation.docker.enable = true;

  services.kasmweb = {
    enable = true;
    listenPort = 443;
    defaultAdminPassword = fromFile "admin-password";
    defaultUserPassword = fromFile "user-password";
    defaultManagerToken = fromFile "manager-token";
    defaultGuacToken = fromFile "guac-token";
    defaultRegistrationToken = fromFile "registration-token";
    # Also passed literally to the redis container, so it can't come from a
    # file. Redis is only reachable on the internal Docker network.
    redisPassword = "kasm-redis-internal";
  } // lib.optionalAttrs useTls {
    # Copied into Kasm when init-kasmweb runs (boot); kasm-tls-sync handles
    # the first issue and renewals.
    sslCertificate = "/var/lib/acme/${domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${domain}/key.pem";
  };

  networking.firewall.allowedTCPPorts = [ 443 ];

  # Random passwords/tokens, generated once on the VM.
  systemd.services.kasmweb-secrets = {
    description = "Generate Kasm Workspaces passwords and tokens";
    before = [ "init-kasmweb.service" ];
    requiredBy = [ "init-kasmweb.service" ];
    path = [ pkgs.openssl pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0700 ${secretDir}
      umask 077
      for name in ${lib.concatStringsSep " " secretNames}; do
        f=${secretDir}/$name
        # Hex only: the values are spliced into sed/yq/printf by the init script.
        [ -s "$f" ] || openssl rand -hex 16 | tr -d '\n' > "$f"
      done
    '';
  };
  systemd.services.init-kasmweb = {
    after = [ "kasmweb-secrets.service" ];
    requires = [ "kasmweb-secrets.service" ];
  };

  # Nightly database dump for restic (raw Postgres files aren't consistent
  # while the container is running).
  systemd.services.kasm-db-dump = {
    description = "Dump the Kasm database";
    startAt = "*-*-* 02:00:00";
    path = [ config.virtualisation.docker.package pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      install -d -m 0700 ${dumpDir}
      docker exec kasm_db pg_dump -U postgres kasm > ${dumpDir}/kasm.sql.tmp
      mv ${dumpDir}/kasm.sql.tmp ${dumpDir}/kasm.sql
    '';
  };

  homelab.backup.paths = [
    dumpDir
    secretDir
    # Server IDs referenced by the database, and Kasm's file mappings.
    "${dataDir}/ids.env"
    "${dataDir}/file_mappings"
  ];
}

(lib.mkIf useTls {
  security.acme.certs.${domain}.reloadServices = [ "kasm-tls-sync.service" ];

  # Copy the Let's Encrypt certificate into Kasm's proxy after every
  # issue/renewal (init-kasmweb only copies it at boot).
  systemd.services.kasm-tls-sync = {
    description = "Copy the Let's Encrypt certificate into Kasm";
    wantedBy = [ "multi-user.target" ];
    after = [ "acme-${domain}.service" "init-kasmweb.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      src=/var/lib/acme/${domain}
      [ -s $src/fullchain.pem ] && [ -d ${dataDir}/certs ] || exit 0
      cp $src/fullchain.pem ${dataDir}/certs/kasm_nginx.crt
      cp $src/key.pem ${dataDir}/certs/kasm_nginx.key
      systemctl try-restart docker-kasm_proxy.service
    '';
  };
})]
