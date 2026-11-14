# Single-node k3s with declarative apps. Each app gets its own namespace:
#
#   homelab.k3s.apps.<name> = {
#     namespace = "<name>";            # default: the app name
#     manifests = [ { kind = "Deployment"; ... } ];   # Kubernetes objects as Nix attrs
#     charts.<chart> = { repo = ...; name = ...; version = ...; hash = ...; values = { }; };
#   };
#
# Manifests are written to k3s's auto-deploy directory and applied by k3s
# itself; charts become HelmChart resources (services.k3s.autoDeployCharts).
# metadata.namespace / targetNamespace default to the app's namespace.
#
# With a `domain` (and acme_email) set for the VM, a Let's Encrypt certificate
# for <domain> and *.<domain> is obtained via DNS-01 and becomes Traefik's
# default certificate: any Ingress with a `tls` section for <app>.<domain> is
# served over HTTPS without further setup.
{ config, lib, settings, ... }:
let
  cfg = config.homelab.k3s;
  domain = settings.domain or "";
  useTls = domain != "" && (settings.acme_email or "") != "";
  tlsSecret = "homelab-tls";
  manifestDir = "/var/lib/rancher/k3s/server/manifests";
  target = name: "homelab-app-${name}.yaml";

  clusterScoped = [
    "Namespace" "ClusterRole" "ClusterRoleBinding" "CustomResourceDefinition"
    "StorageClass" "PersistentVolume" "IngressClass" "PriorityClass"
    "ValidatingWebhookConfiguration" "MutatingWebhookConfiguration"
  ];
  withNamespace = ns: obj:
    if lib.elem (obj.kind or "") clusterScoped || (obj.metadata.namespace or null) != null
    then obj
    else lib.recursiveUpdate obj { metadata.namespace = ns; };

  appModule = { name, ... }: {
    options = {
      namespace = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Namespace the app's objects and charts are deployed to.";
      };
      manifests = lib.mkOption {
        type = with lib.types; listOf attrs;
        default = [ ];
        description = "Kubernetes objects. Don't put secrets here: they end up in the world-readable Nix store.";
      };
      charts = lib.mkOption {
        type = with lib.types; attrsOf attrs;
        default = { };
        description = "Helm charts, as services.k3s.autoDeployCharts entries (repo, name, version, hash, values).";
      };
    };
  };
in
{
  options.homelab.k3s = {
    enable = lib.mkEnableOption "single-node k3s";
    apps = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule appModule);
      default = { };
      description = "Declarative apps, one namespace each.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [{
    services.k3s = {
      enable = true;
      role = "server";
      # Lets a kubeconfig that points at the VM's address/name validate the API cert.
      extraFlags = [ "--tls-san=${settings.ipv4_address}" ]
        ++ lib.optional (domain != "") "--tls-san=${domain}";

      manifests = lib.mapAttrs' (name: app: lib.nameValuePair "homelab-app-${name}" {
        target = target name;
        content = [{
          apiVersion = "v1";
          kind = "Namespace";
          metadata.name = app.namespace;
        }] ++ map (withNamespace app.namespace) app.manifests;
      }) cfg.apps;

      autoDeployCharts = lib.concatMapAttrs (name: app:
        lib.mapAttrs' (chart: spec: lib.nameValuePair "${name}-${chart}" ({
          targetNamespace = app.namespace;
          createNamespace = true;
        } // spec)) app.charts
      ) cfg.apps;
    };

    # Removing an app from the config removes its manifest file. k3s does not
    # delete the objects themselves; run `kubectl delete namespace <ns>` for that.
    system.activationScripts.k3s-prune-apps = {
      deps = [ ];
      text = ''
        for f in ${manifestDir}/homelab-app-*.yaml; do
          [ -L "$f" ] || continue
          case " ${lib.concatMapStringsSep " " target (lib.attrNames cfg.apps)} " in
            *" $(basename "$f") "*) ;;
            *) echo "k3s: removing stale manifest $f"; rm -f "$f" ;;
          esac
        done
      '';
    };

    networking.firewall = {
      allowedTCPPorts = [ 6443 ]; # Kubernetes API (LAN)
      trustedInterfaces = [ "cni0" "flannel.1" ];
    };

    # PersistentVolume data (local-path provisioner).
    homelab.backup.paths = [ "/var/lib/rancher/k3s/storage" ];
  }

  (lib.mkIf useTls {
    # One certificate for the domain and all its subdomains (DNS-01 allows
    # wildcards). The base cert itself is defined in modules/acme.nix.
    security.acme.certs.${domain} = {
      extraDomainNames = [ "*.${domain}" ];
      reloadServices = [ "k3s-tls-sync.service" ];
    };

    # Copy the certificate into k3s after every issue/renewal.
    systemd.services.k3s-tls-sync = {
      description = "Copy the Let's Encrypt certificate into k3s";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" "acme-${domain}.service" ];
      wants = [ "k3s.service" ];
      path = [ config.services.k3s.package ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 15;
      };
      script = ''
        for i in $(seq 1 40); do
          k3s kubectl get namespace kube-system >/dev/null 2>&1 && break
          sleep 3
        done
        k3s kubectl -n kube-system create secret tls ${tlsSecret} \
          --cert=/var/lib/acme/${domain}/fullchain.pem \
          --key=/var/lib/acme/${domain}/key.pem \
          --dry-run=client -o yaml | k3s kubectl apply -f -
      '';
    };

    # Make it Traefik's default certificate.
    services.k3s.manifests.homelab-tls-default.content = {
      apiVersion = "traefik.io/v1alpha1";
      kind = "TLSStore";
      metadata = {
        name = "default";
        namespace = "kube-system";
      };
      spec.defaultCertificate.secretName = tlsSecret;
    };
  })]);
}
