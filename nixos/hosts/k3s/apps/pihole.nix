# Pi-hole in namespace "pihole".
#   DNS:    <vm-ip>:53 (UDP + TCP)
#   Web UI: https://pihole.<domain>/admin/  (Traefik + Let's Encrypt)
#           http://<vm-ip>:8080/admin/      (only when the VM has no domain)
#   Login:  password in /var/lib/pihole-secret/password on the VM
#
# With a domain, Pi-hole also answers <domain> and *.<domain> with the VM's IP,
# so every app on this cluster resolves for clients that use Pi-hole.
{ config, lib, pkgs, settings, ... }:
let
  ns = "pihole";
  image = "docker.io/pihole/pihole:2026.11.0";
  secretFile = "/var/lib/pihole-secret/password";
  domain = settings.domain or "";
  host = "pihole.${domain}";
in
{
  homelab.k3s.apps.pihole = {
    namespace = ns;
    manifests = [
      {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        metadata.name = "pihole-data";
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = "1Gi";
        };
      }
      {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "pihole";
          labels.app = "pihole";
        };
        spec = {
          replicas = 1;
          strategy.type = "Recreate"; # single RWO volume
          selector.matchLabels.app = "pihole";
          template = {
            metadata.labels.app = "pihole";
            spec = {
              containers = [{
                name = "pihole";
                inherit image;
                env = [
                  { name = "TZ"; value = settings.timezone; }
                  {
                    name = "FTLCONF_webserver_api_password";
                    valueFrom.secretKeyRef = { name = "pihole-admin"; key = "password"; };
                  }
                  # Queries arrive from the pod network, not the local subnet.
                  { name = "FTLCONF_dns_listeningMode"; value = "ALL"; }
                  { name = "FTLCONF_dns_upstreams"; value = "1.1.1.1;9.9.9.9"; }
                ] ++ lib.optional (domain != "") {
                  # Local record: <domain> and all subdomains -> this VM.
                  name = "FTLCONF_misc_dnsmasq_lines";
                  value = "address=/${domain}/${settings.ipv4_address}";
                };
                ports = [
                  { name = "dns-udp"; containerPort = 53; protocol = "UDP"; }
                  { name = "dns-tcp"; containerPort = 53; protocol = "TCP"; }
                  { name = "http"; containerPort = 80; protocol = "TCP"; }
                ];
                volumeMounts = [{ name = "data"; mountPath = "/etc/pihole"; }];
                readinessProbe = {
                  httpGet = { path = "/admin/"; port = "http"; };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                };
                resources.requests = { cpu = "50m"; memory = "128Mi"; };
              }];
              volumes = [{ name = "data"; persistentVolumeClaim.claimName = "pihole-data"; }];
            };
          };
        };
      }
      {
        apiVersion = "v1";
        kind = "Service";
        metadata.name = "pihole";
        spec = {
          # k3s's ServiceLB exposes this on the node's own IP.
          type = "LoadBalancer";
          # Keep real client IPs in Pi-hole's query log.
          externalTrafficPolicy = "Local";
          selector.app = "pihole";
          ports = [
            { name = "dns-udp"; port = 53; targetPort = "dns-udp"; protocol = "UDP"; }
            { name = "dns-tcp"; port = 53; targetPort = "dns-tcp"; protocol = "TCP"; }
          ] ++ lib.optional (domain == "") {
            name = "web"; port = 8080; targetPort = "http"; protocol = "TCP";
          };
        };
      }
    ] ++ lib.optionals (domain != "") [
      {
        # Cluster-internal service for the Ingress.
        apiVersion = "v1";
        kind = "Service";
        metadata.name = "pihole-web";
        spec = {
          selector.app = "pihole";
          ports = [{ name = "http"; port = 80; targetPort = "http"; }];
        };
      }
      {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        metadata = {
          name = "pihole";
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
              backend.service = { name = "pihole-web"; port.number = 80; };
            }];
          }];
        };
      }
    ];
  };

  networking.firewall = {
    allowedTCPPorts = [ 53 ] ++ lib.optional (domain == "") 8080;
    allowedUDPPorts = [ 53 ];
  };

  # Admin password: generated on the VM and stored as a Kubernetes Secret, so
  # it never touches git, tofu state or the Nix store.
  systemd.services.pihole-admin-secret = {
    description = "Create the Pi-hole admin password secret";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    path = [ config.services.k3s.package pkgs.openssl pkgs.coreutils ];
    environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 15;
    };
    script = ''
      if [ ! -s ${secretFile} ]; then
        install -d -m 0700 "$(dirname ${secretFile})"
        umask 077
        openssl rand -base64 18 | tr -d '\n' > ${secretFile}
      fi
      # k3s creates the namespace from the app manifest shortly after starting.
      for i in $(seq 1 40); do
        k3s kubectl get namespace ${ns} >/dev/null 2>&1 && break
        sleep 3
      done
      # $(cat) strips any trailing newline, which would otherwise become part
      # of the password (and can't be typed into the login form).
      result=$(k3s kubectl -n ${ns} create secret generic pihole-admin \
        --from-literal=password="$(cat ${secretFile})" --dry-run=client -o yaml \
        | k3s kubectl apply -f -)
      echo "$result"
      # Env vars from a Secret are only read at pod start.
      case "$result" in
        *configured*) k3s kubectl -n ${ns} rollout restart deployment/pihole ;;
      esac
    '';
  };

  homelab.backup.paths = [ "/var/lib/pihole-secret" ];
}
