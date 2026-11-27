# Audiobookshelf in namespace "audiobookshelf".
#   Web UI: https://audiobookshelf.<domain>/  (Traefik + Let's Encrypt)
#           http://<vm-ip>:13378/             (only when the VM has no domain)
#   Login:  the first visit creates the root user.
#
# Config and metadata (covers, cache, the app's own backups) live on PVCs and
# are part of the B2 backup.
#
# The audiobook library is its own B2 bucket, mounted with rclone at
# /srv/audiobookshelf/audiobooks (read-write: uploads in the web UI go to B2),
# so it takes no space on the VM's disk or in the VM backups. A local cache
# (up to 5 GB) keeps playback and scans fast. Credentials and bucket:
# /var/lib/secrets/audiobooks-b2.env (B2_AUDIOBOOKS_* in .env). Podcasts stay
# on the VM's disk.
{ lib, pkgs, settings, ... }:
let
  ns = "audiobookshelf";
  image = "ghcr.io/advplyr/audiobookshelf:2.38.0";
  mediaDir = "/srv/audiobookshelf";
  b2Env = "/var/lib/secrets/audiobooks-b2.env";
  cacheDir = "/var/cache/rclone-audiobooks";
  domain = settings.domain or "";
  host = "audiobookshelf.${domain}";

  pvc = name: size: {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    metadata.name = name;
    spec = {
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = size;
    };
  };
in
{
  homelab.k3s.apps.audiobookshelf = {
    namespace = ns;
    manifests = [
      (pvc "audiobookshelf-config" "1Gi")
      (pvc "audiobookshelf-metadata" "5Gi")
      {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "audiobookshelf";
          labels.app = "audiobookshelf";
        };
        spec = {
          replicas = 1;
          strategy.type = "Recreate"; # RWO volumes + SQLite
          selector.matchLabels.app = "audiobookshelf";
          template = {
            metadata.labels.app = "audiobookshelf";
            spec = {
              containers = [{
                name = "audiobookshelf";
                inherit image;
                env = [
                  { name = "TZ"; value = settings.timezone; }
                  { name = "PORT"; value = "80"; }
                ];
                ports = [{ name = "http"; containerPort = 80; protocol = "TCP"; }];
                volumeMounts = [
                  { name = "config"; mountPath = "/config"; }
                  { name = "metadata"; mountPath = "/metadata"; }
                  # HostToContainer: the pod sees the B2 mount even if it's
                  # (re)mounted after the pod started.
                  { name = "audiobooks"; mountPath = "/audiobooks"; mountPropagation = "HostToContainer"; }
                  { name = "podcasts"; mountPath = "/podcasts"; }
                ];
                readinessProbe = {
                  httpGet = { path = "/healthcheck"; port = "http"; };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                };
                resources.requests = { cpu = "50m"; memory = "128Mi"; };
              }];
              volumes = [
                { name = "config"; persistentVolumeClaim.claimName = "audiobookshelf-config"; }
                { name = "metadata"; persistentVolumeClaim.claimName = "audiobookshelf-metadata"; }
                { name = "audiobooks"; hostPath = { path = "${mediaDir}/audiobooks"; type = "DirectoryOrCreate"; }; }
                { name = "podcasts"; hostPath = { path = "${mediaDir}/podcasts"; type = "DirectoryOrCreate"; }; }
              ];
            };
          };
        };
      }
      {
        apiVersion = "v1";
        kind = "Service";
        metadata.name = "audiobookshelf";
        spec = {
          # Without a domain, ServiceLB exposes the UI on the node's own IP.
          type = if domain == "" then "LoadBalancer" else "ClusterIP";
          selector.app = "audiobookshelf";
          ports = [{
            name = "http";
            port = if domain == "" then 13378 else 80;
            targetPort = "http";
          }];
        };
      }
    ] ++ lib.optional (domain != "") {
      apiVersion = "networking.k8s.io/v1";
      kind = "Ingress";
      metadata = {
        name = "audiobookshelf";
        annotations."traefik.ingress.kubernetes.io/router.entrypoints" = "websecure";
      };
      spec = {
        # No secretName: Traefik uses the default (wildcard) certificate.
        tls = [{ hosts = [ host ]; }];
        rules = [{
          inherit host;
          http.paths = [{
            path = "/";
            pathType = "Prefix";
            backend.service = { name = "audiobookshelf"; port.number = 80; };
          }];
        }];
      };
    };
  };

  networking.firewall.allowedTCPPorts = lib.optional (domain == "") 13378;

  # The library bucket, mounted before k3s starts. If B2 is unreachable at
  # boot, Audiobookshelf sees an empty folder and marks books as missing until
  # the next scan after the mount is back (no data is lost).
  systemd.services.audiobooks-mount = {
    description = "Audiobookshelf library (B2 bucket, rclone mount)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    before = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = b2Env;
    path = [ "/run/wrappers" ]; # fusermount3
    serviceConfig = {
      Type = "notify";
      EnvironmentFile = b2Env; # rclone remote "b2" + AUDIOBOOKS_BUCKET
      Environment = "RCLONE_CONFIG=/dev/null";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${mediaDir}/audiobooks ${cacheDir}";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.rclone}/bin/rclone mount b2:\${AUDIOBOOKS_BUCKET} ${mediaDir}/audiobooks"
        "--allow-other --umask 002"
        "--vfs-cache-mode full --cache-dir ${cacheDir}"
        "--vfs-cache-max-size 5G --vfs-cache-min-free-space 3G --vfs-cache-max-age 168h"
        "--dir-cache-time 5m"
      ];
      ExecStop = "/run/wrappers/bin/fusermount3 -uz ${mediaDir}/audiobooks";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  # rclone on the command line too, e.g. to copy books into the bucket:
  #   set -a; . /var/lib/secrets/audiobooks-b2.env; set +a
  #   RCLONE_CONFIG=/dev/null rclone copy <dir> b2:$AUDIOBOOKS_BUCKET/<title>
  environment.systemPackages = [ pkgs.rclone ];
}
