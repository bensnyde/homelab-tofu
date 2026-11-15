# Mealie (recipe manager) in namespace "mealie".
#   Web UI: https://mealie.<domain>/  (Traefik + Let's Encrypt)
#           http://<vm-ip>:9000/      (only when the VM has no domain)
#   Login:  changeme@example.com / MyPassword on first start. Change both
#           right away (Profile -> Edit). Sign-up is disabled; invite users
#           from the admin settings.
#
# Data (SQLite database, recipe images) lives on PVC "mealie-data", which is
# part of the R2 backup.
{ lib, settings, ... }:
let
  ns = "mealie";
  image = "ghcr.io/mealie-recipes/mealie:v3.31.0";
  domain = settings.domain or "";
  host = "mealie.${domain}";
  baseUrl = if domain != "" then "https://${host}" else "http://${settings.ipv4_address}:9000";
in
{
  homelab.k3s.apps.mealie = {
    namespace = ns;
    manifests = [
      {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        metadata.name = "mealie-data";
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = "2Gi";
        };
      }
      {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "mealie";
          labels.app = "mealie";
        };
        spec = {
          replicas = 1;
          strategy.type = "Recreate"; # RWO volume + SQLite
          selector.matchLabels.app = "mealie";
          template = {
            metadata.labels.app = "mealie";
            spec = {
              containers = [{
                name = "mealie";
                inherit image;
                env = [
                  { name = "TZ"; value = settings.timezone; }
                  { name = "BASE_URL"; value = baseUrl; }
                  { name = "ALLOW_SIGNUP"; value = "false"; }
                  # One API worker keeps memory use low on a small node.
                  { name = "MAX_WORKERS"; value = "1"; }
                  { name = "WEB_CONCURRENCY"; value = "1"; }
                ];
                ports = [{ name = "http"; containerPort = 9000; protocol = "TCP"; }];
                volumeMounts = [{ name = "data"; mountPath = "/app/data"; }];
                readinessProbe = {
                  httpGet = { path = "/api/app/about"; port = "http"; };
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                };
                resources = {
                  requests = { cpu = "50m"; memory = "256Mi"; };
                  limits.memory = "1Gi";
                };
              }];
              volumes = [{ name = "data"; persistentVolumeClaim.claimName = "mealie-data"; }];
            };
          };
        };
      }
      {
        apiVersion = "v1";
        kind = "Service";
        metadata.name = "mealie";
        spec = {
          # Without a domain, ServiceLB exposes the UI on the node's own IP.
          type = if domain == "" then "LoadBalancer" else "ClusterIP";
          selector.app = "mealie";
          ports = [{
            name = "http";
            port = if domain == "" then 9000 else 80;
            targetPort = "http";
          }];
        };
      }
    ] ++ lib.optional (domain != "") {
      apiVersion = "networking.k8s.io/v1";
      kind = "Ingress";
      metadata = {
        name = "mealie";
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
            backend.service = { name = "mealie"; port.number = 80; };
          }];
        }];
      };
    };
  };

  networking.firewall.allowedTCPPorts = lib.optional (domain == "") 9000;
}
