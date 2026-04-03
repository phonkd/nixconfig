{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."server-sops" = { config, pkgs, lib, ... }:
    {
      # Install dependencies
      environment.systemPackages = with pkgs; [
        curl
        jq
      ];

      # Install the script
      environment.etc."local/bin/cloudflare-ddns.sh" = {
        text = ddnsScript;
        mode = "0755";
      };

      # Cron job every 15 minutes
      services.cron = {
        enable = true;
        systemCronJobs = [
          "*/15 * * * * root /etc/local/bin/cloudflare-ddns.sh >/dev/null 2>&1"
        ];
      };

      # Your existing SOPS secret
      sops.secrets.cfapikey = { };
    };

}
