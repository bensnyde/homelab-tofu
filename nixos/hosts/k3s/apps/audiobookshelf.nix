# Audiobookshelf in namespace "audiobookshelf".
#   Web UI: https://audiobookshelf.<domain>/  (Traefik + Let's Encrypt)
#           http://<vm-ip>:13378/             (only when the VM has no domain)
#   Login:  the first visit creates the root user.
#
# Config and metadata (covers, cache, the app's own backups) live on PVCs and
# are part of the B2 backup. The media library is a hostPath under
# /srv/audiobookshelf on purpose: it's outside the backed-up k3s storage, so
# gigabytes of audio don't end up in B2. Copy files there, or replace the
# hostPath volumes with an NFS share from your NAS.
{ lib, settings, ... }:
let
  ns = "audiobookshelf";
  image = "ghcr.io/advplyr/audiobookshelf:2.38.0";
  mediaDir = "/srv/audiobookshelf";
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
                  { name = "audiobooks"; mountPath = "/audiobooks"; }
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
}
