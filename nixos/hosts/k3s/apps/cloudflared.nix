# Cloudflare Tunnel in namespace "cloudflared": publishes selected apps on the
# internet through an outbound connection to Cloudflare. No inbound ports,
# no router changes, and the home IP stays hidden.
#
# The tunnel is "remotely managed": which public hostname goes to which
# service is configured in the Cloudflare dashboard (Zero Trust -> Networks ->
# Tunnels -> <tunnel> -> Public hostnames), e.g.
#   books.<domain> -> http://audiobookshelf.audiobookshelf.svc.cluster.local:80
# Only hostnames listed there are reachable from the internet.
#
# Token: CLOUDFLARE_TUNNEL_TOKEN in .env (the long "eyJ..." value, not the
# tunnel ID), written to /var/lib/secrets/cloudflared-token at install or by
# scripts/push-secrets.sh (needs secrets = ["cloudflared-token"] for the VM in
# nixos_vms). A systemd service turns it
# into a Kubernetes Secret, so it never touches git, tofu state or the Nix
# store. Until it exists, the pods wait in CreateContainerConfigError.
{ config, pkgs, ... }:
let
  ns = "cloudflared";
  image = "docker.io/cloudflare/cloudflared:2026.11.1";
  tokenFile = "/var/lib/secrets/cloudflared-token";
in
{
  homelab.k3s.apps.cloudflared = {
    namespace = ns;
    manifests = [{
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = "cloudflared";
        labels.app = "cloudflared";
      };
      spec = {
        # Two connectors, so a rolling update never drops the tunnel.
        replicas = 2;
        selector.matchLabels.app = "cloudflared";
        template = {
          metadata.labels.app = "cloudflared";
          spec = {
            containers = [{
              name = "cloudflared";
              inherit image;
              args = [ "tunnel" "--no-autoupdate" "--metrics" "0.0.0.0:2000" "run" ];
              env = [{
                name = "TUNNEL_TOKEN";
                valueFrom.secretKeyRef = { name = "cloudflared-token"; key = "token"; };
              }];
              ports = [{ name = "metrics"; containerPort = 2000; }];
              # /ready is 200 once the connector has a live connection to Cloudflare.
              livenessProbe = {
                httpGet = { path = "/ready"; port = "metrics"; };
                initialDelaySeconds = 10;
                periodSeconds = 10;
                failureThreshold = 3;
              };
              securityContext = {
                runAsNonRoot = true;
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = [ "ALL" ];
              };
              resources.requests = { cpu = "10m"; memory = "32Mi"; };
            }];
          };
        };
      };
    }];
  };

  systemd.services.cloudflared-token-secret = {
    description = "Create the Cloudflare Tunnel token secret";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    path = [ config.services.k3s.package pkgs.coreutils ];
    environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    unitConfig.ConditionPathExists = tokenFile;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 15;
    };
    script = ''
      for i in $(seq 1 40); do
        k3s kubectl get namespace ${ns} >/dev/null 2>&1 && break
        sleep 3
      done
      # $(cat) strips a trailing newline.
      result=$(k3s kubectl -n ${ns} create secret generic cloudflared-token \
        --from-literal=token="$(cat ${tokenFile})" --dry-run=client -o yaml \
        | k3s kubectl apply -f -)
      echo "$result"
      # Env vars from a Secret are only read at pod start.
      case "$result" in
        *configured*) k3s kubectl -n ${ns} rollout restart deployment/cloudflared ;;
      esac
    '';
  };
}
