{ self, inputs, ...}:
{
  flake.nixosModules.mailserver =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    {
      imports = [
        inputs.simple-nixos-mailserver.nixosModule
      ];
      config = lib.mkIf (noughtyLib.hostHasTag "mailserver") {
        sops.secrets."mail-secret" = {
          sopsFile = ./secrets/mail-secret.yaml;
        };
        mailserver = {
          enable = true;
          fqdn = "mail.phonkd.net";
          domains = [ "phonkd.net" ];

          systemName = "phonkd.net Mail Server";
          systemDomain = "phonkd.net";

          tlsrpt.enable = true;
          systemContact = "spam1@phonkd.net";
          accounts = {
            "phonkd@phonkd.net" = {
              hashedPasswordFile = config.sops.secrets."mail-secret".path;
              aliases = [
                "test@phonkd.net"
                "spam@phonkd.net"
                "spam1@phonkd.net"
                "elis@phonkd.net"
                "info@phonkd.net"
                "spam2@phonkd.net"
                "spam3@phonkd.net"
              ];
            };
          };
          stateVersion = 3;
          x509.useACMEHost = "mail.phonkd.net";
        };

        security.acme.acceptTerms = true;
        security.acme.defaults.email = "bhonk123@gmail.com";

        services.radicale = {
          enable = true;
          settings = {
            auth = {
              type = "htpasswd";
              htpasswd_filename = "/run/radicale/htpasswd";
              htpasswd_encryption = "bcrypt";
            };
          };
        };

        systemd.services.radicale = {
          serviceConfig = {
            RuntimeDirectory = "radicale";
          };
        };

        systemd.services.radicale-setup = {
          description = "Setup radicale htpasswd file";
          before = [ "radicale.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            mkdir -p /run/radicale
            echo "phonkd@phonkd.net:$(cat ${config.sops.secrets."mail-secret".path})" > /run/radicale/htpasswd
            chmod 600 /run/radicale/htpasswd
            chown radicale:radicale /run/radicale/htpasswd
          '';
        };

        services.nginx = {
          enable = true;
          virtualHosts = {
            "mail.phonkd.net" = {
              forceSSL = true;
              enableACME = true;
            };
            "cal.phonkd.net" = {
              forceSSL = true;
              enableACME = true;
              locations."/" = {
                proxyPass = "http://localhost:5232/";
                extraConfig = ''
                  proxy_set_header  X-Script-Name /;
                  proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_pass_header Authorization;
                '';
              };
            };
          };
        };

        networking.firewall.allowedTCPPorts = [
          80
          443
        ];
      };
    };
}
