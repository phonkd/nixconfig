# Host-specific NixOS config for blac.
#
# This file used to wire `flake.nixosConfigurations.blac` by hand and
# pick a module list. That responsibility moved to lib/registry.nix +
# modules/_builder.nix. Here we only declare what the *blac* host should
# do, and self-gate so the module is safe to import into any host.
{ ... }:
{
  flake.nixosModules.blac =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf (config.noughty.host.name == "blac") {
      # Shared desktop baseline (DE selection, steam, bluetooth, wheel,
      # networkmanager, nameservers, bolt, gvfs, libinput quirks) now lives
      # in modules/desktop.nix, gated on noughty.host.is.nixosDesktop.

      # SSH access (e.g. from the Mac). openssh opens port 22 itself.
      services.openssh = {
        enable = true;
        settings.PasswordAuthentication = false;
        settings.KbdInteractiveAuthentication = false;
        settings.PermitRootLogin = "no";
      };
      users.users.phonkd.openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDg0PjpVeFevKuUq7ZVAhL0fySgOomRT/SZ6jWFxfv0q06KgwLSInwXFZDIUNN9c2Uz6qgJvh/xZ9UQfuoYwBMwUDt89hhplZDeFG+0kTxPRyjKrtcOXefM2ne4eI93kvJfU5+SaxXs3GF5oChoml4Wwub74CVLWIlKTvA7YLEKzBffEJ4ypO97YTR734Cd1vHsIOVFylftIpe0n/oA7o3Bu+GSRwfW4cM9nbYcumydwyrA9osrQ6dLNFCJ6DSvBY65j9eU/wGEObmch645f+hAm1ROZxoUYtVBQjSNheYNIUAxjXDbHd/eA3TjG6qGfUSbFu1gitQBLY4M+YUmT+r/IjD3XBFwFCED3G/TKKBjKubCMk0yxegCa+JZt+HzSbRTILgFv0eC+DvZBgMHMx0RjefvOJY6mCWtwwYRULp+2ulls6RTX2F3aEEKO0+/9YxTfzvwE1zFLAVxNpCg25f35eWuBdIJD/2K42Krbe2xrGDJdFhRtpT1uoq0qGHreIk= phonkd@Eliss-MacBook-Pro.local"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPrr8owgaJr+6wpTafMrp7j2wALLAOAuzalPuFJrgV7m"
      ];
      networking.hostName = "blac";

      # blac's screen is OLED, so the one permanently-lit element on it -- the
      # taskbar -- gets hidden until the pointer asks for it. g14 is an LCD and
      # deliberately keeps its panel; see modules/kde-plasma-shell.nix, which
      # also drives the wallpaper slideshow (the other half of the same
      # burn-in story, and on by default for every KDE host).
      noughty.kde.panelAutoHide = true;

      networking.enableIPv6 = false;
      networking.nat.externalInterface = lib.mkForce "enp9s0";

      boot.loader.systemd-boot.enable = false;
      boot.loader.limine = {
        enable = true;
        secureBoot.enable = true;
      };
      boot.loader.efi.canTouchEfiVariables = true;

      boot.kernelParams = [
        "pci=noaer"
        "btusb.enable_autosuspend=n"
        "amd_iommu=on"
        "iommu=nopt"
      ];

      hardware.nvidia = {
        open = true;
        modesetting.enable = true;
        powerManagement.enable = true;
        package = config.boot.kernelPackages.nvidiaPackages.latest;
      };

      environment.systemPackages = with pkgs; [
        cudatoolkit
      ];

      services.sunshine = {
        enable = false;
        autoStart = true;
        capSysAdmin = true;
        openFirewall = true;
      };
      services.ollama = {
        enable = true;
        # Use the RTX 5080 (CUDA) rather than CPU. (services.ollama.acceleration
        # is defunct; the accelerated variant is picked via the package now.)
        package = pkgs.ollama-cuda;
        # Listen on the LAN so 204-agent (slop-trove) can reach it.
        host = "0.0.0.0";
        port = 11434;
        # Pull the embedding model on startup (slop-trove uses bge-m3, 1024-dim).
        loadModels = [ "bge-m3" ];
      };
      # Ollama has no auth; only open it on the trusted LAN. Tighten to 204
      # only if blac ever gets nftables (see services.hermes for the pattern).
      networking.firewall.allowedTCPPorts = [ 11434 ];
    };
}
