{ ... }:
{
  flake.nixosModules."ext-mail" =
    {
      config,
      pkgs,
      lib,
      modulesPath,
      ...
    }:
    {
      imports = [
        (modulesPath + "/profiles/qemu-guest.nix")
      ];
      config = lib.mkIf (config.noughty.host.name == "ext-mail") {
        networking.hostName = "ext-mail";
        services.openssh = {
          enable = true;
          ports = [ 5432 ];
          openFirewall = true;
          settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = "no";
            AllowUsers = [ "phonkd" ];
          };
        };
        boot.loader.systemd-boot.configurationLimit = 10;
        time.timeZone = lib.mkDefault "Europe/Zurich";
        i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
        services.xserver.xkb = lib.mkDefault {
          layout = "ch";
          variant = "";
        };
        console.keyMap = lib.mkDefault "sg";
        users.users.phonkd = {
          isNormalUser = true;
          description = "phonkd";
          extraGroups = [
            "networkmanager"
            "wheel"
            "docker"
          ];
        };
        security.sudo.wheelNeedsPassword = false;
        sops.secrets."mail-secret" = {
          sopsFile = ./secrets/mail-secret.yaml;
        };
        virtualisation.docker.enable = true;
        system.stateVersion = lib.mkForce "26.05";

        users.users."phonkd".openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDg0PjpVeFevKuUq7ZVAhL0fySgOomRT/SZ6jWFxfv0q06KgwLSInwXFZDIUNN9c2Uz6qgJvh/xZ9UQfuoYwBMwUDt89hhplZDeFG+0kTxPRyjKrtcOXefM2ne4eI93kvJfU5+SaxXs3GF5oChoml4Wwub74CVLWIlKTvA7YLEKzBffEJ4ypO97YTR734Cd1vHsIOVFylftIpe0n/oA7o3Bu+GSRwfW4cM9nbYcumydwyrA9osrQ6dLNFCJ6DSvBY65j9eU/wGEObmch645f+hAm1ROZxoUYtVBQjSNheYNIUAxjXDbHd/eA3TjG6qGfUSbFu1gitQBLY4M+YUmT+r/IjD3XBFwFCED3G/TKKBjKubCMk0yxegCa+JZt+HzSbRTILgFv0eC+DvZBgMHMx0RjefvOJY6mCWtwwYRULp+2ulls6RTX2F3aEEKO0+/9YxTfzvwE1zFLAVxNpCg25f35eWuBdIJD/2K42Krbe2xrGDJdFhRtpT1uoq0qGHreIk= phonkd@Eliss-MacBook-Pro.local"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFrYSWQbmJ2oL4nORm6U0qiJAmrgE2dNQVKlV36i5uiF phonkd@blac"
        ];

        mailserver = {
          enable = true;
          fqdn = "mail.phonkd.net";
          domains = [ "phonkd.net" ];

          systemName = "phonkd.net Mail Server";
          systemDomain = "phonkd.net";

          tlsrpt.enable = true;
          systemContact = "spam1@phonkd.net";
          loginAccounts = {
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
          certificateScheme = 3;
          stateVersion = 3;
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

        boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
        boot.initrd.kernelModules = [ ];
        boot.kernelModules = [ ];
        boot.extraModulePackages = [ ];
        boot.loader.grub = {
          enable = true;
          efiSupport = true;
          efiInstallAsRemovable = true;
          device = "nodev";
        };
        boot.loader.efi.efiSysMountPoint = "/efi";
        fileSystems."/" = {
          device = "/dev/disk/by-uuid/4c720436-405e-43af-abed-be474257acd9";
          fsType = "ext4";
        };
        fileSystems."/efi" = {
          device = "/dev/disk/by-uuid/564D-E28E";
          fsType = "vfat";
          options = [ "fmask=0077" "dmask=0077" ];
        };
        swapDevices = [ ];
        networking.useDHCP = lib.mkDefault true;
        nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
      };
    };
}
