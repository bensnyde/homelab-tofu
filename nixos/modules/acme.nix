# Let's Encrypt certificate for settings.domain via the DNS-01 challenge: the
# host creates a TXT record through the DNS provider's API, so Let's Encrypt
# never has to connect to it and no ports are exposed.
#
# Active when tofu set both `domain` and `acme_email` for this host. Use the
# cert from nginx with `enableACME = true` on the virtual host named after the
# domain, or reference security.acme.certs.<domain> directly.
{ config, lib, settings, ... }:
let
  domain = settings.domain or "";
  enabled = domain != "" && (settings.acme_email or "") != "";
in
{
  config = lib.mkIf enabled {
    security.acme = {
      acceptTerms = true;
      defaults.email = settings.acme_email;
      certs.${domain} = {
        dnsProvider = settings.acme_dns;
        environmentFile = "/var/lib/secrets/acme-dns.env";
        # Check propagation against public DNS, not a LAN split-DNS override.
        dnsResolver = "1.1.1.1:53";
      };
    };

    # Disable nginx's HTTP-01 webroot so only DNS-01 is used.
    services.nginx.virtualHosts = lib.mkIf config.services.nginx.enable {
      ${domain}.acmeRoot = null;
    };
  };
}
