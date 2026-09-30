# Host-specific NixOS config for z14 (ASUS Zenbook 14 UM3406GA), generated via
# lib/registry.nix / modules/builder.nix. Deliberately short: this laptop
# briefly ran the retired g14 (Zephyrus GA401) config as a stopgap but shares
# almost no hardware with it (Radeon 840M iGPU vs that machine's NVIDIA dGPU)
# -- see plans/z14-zenbook.md.
#
# No nixos-hardware profile exists for the UM3406; verified by eval that the
# generic settings it would add (fstrim, enableRedistributableFirmware,
# enable32Bit, amd.updateMicrocode) are already set here or via
# hardware-configuration.nix.
#
# tlp stays off: it and power-profiles-daemon (enabled in modules/desktop.nix)
# fight over the same CPU governor.
{ inputs, ... }:
{
  flake.nixosModules.z14 =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # The internal mic read "atrocious quality" rather than "quiet" because
      # PipeWire's alsa-card-profile merges ALC294's two capture gain controls
      # (Capture ADC 0..63 @ 0.75dB/step, Mic Boost pre-amp 0..3 @ 10dB/step)
      # into one slider spanning -17.25..+60dB, with unity gain at only ~10%.
      # Measured: ambient room noise alone drove the ADC to peak 0.99997 at
      # 100%, clipping in the analog domain before any encoder sees it. At 0%
      # PipeWire applies a literal x0 multiply -- capture returns all-zero
      # samples, not faint audio.
      #
      # Fix: pin Mic Boost to 0dB (volume = zero) and cap Capture at
      # volume-limit=33 (+7.5dB), leaving a -17.25..+7.5dB slider with unity at
      # ~75%. Measured after: peak 0.016 at 100%, ~49dB lower noise floor, no
      # clipping anywhere on the slider.
      #
      # ACP_PATHS_DIR takes a whole directory, so this copies upstream's mixer
      # paths and rewrites analog-input-mic.conf; both pipewire and
      # wireplumber need it (wireplumber's monitor is what builds the ACP
      # device). The greps are build-time assertions against a PipeWire bump
      # reshaping the file silently.
      acpMixerPaths = pkgs.runCommand "z14-acp-mixer-paths" { } ''
        mkdir -p "$out"
        cp -rL ${config.services.pipewire.package}/share/alsa-card-profile/mixer/paths/. "$out"/
        chmod -R u+w "$out"
        awk '
          /^\[Element /                { sec = $0 }
          sec == "[Element Capture]"   && /^volume = merge$/ { print; print "volume-limit = 33"; next }
          sec == "[Element Mic Boost]" && /^volume = merge$/ { print "volume = zero"; next }
                                       { print }
        ' "$out"/analog-input-mic.conf > "$out"/analog-input-mic.conf.new
        mv "$out"/analog-input-mic.conf.new "$out"/analog-input-mic.conf
        grep -qx 'volume-limit = 33' "$out"/analog-input-mic.conf
        grep -qx 'volume = zero' "$out"/analog-input-mic.conf
      '';
    in
    lib.mkIf (config.noughty.host.name == "z14") {
      # Use Betterbird for mail on this laptop; Owl is its Exchange add-on.
      home-manager.users.phonkd.programs.thunderbird.enable = lib.mkForce false;
      services.flatpak.packages = [
        {
          appId = "eu.betterbird.Betterbird";
          origin = "flathub";
        }
      ];

      noughty.proxy.protonReddit.enable = true;
      networking.hostName = "z14";

      # limine (not systemd-boot): the g14-stopgap rebuild already installed
      # limine to this disk. No secureBoot -- that's blac's, which has
      # enrolled keys.
      boot.loader.systemd-boot.enable = false;
      boot.loader.limine.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # nixos-hardware's cpu/amd/pstate.nix would pick "active" for kernel
      # >=6.3 (we're on 6.18) -- lets the CPU scale itself vs acpi-cpufreq.
      boot.kernelParams = [ "amd_pstate=active" ];

      # Real ambient light sensor (IIO `als`, HID usage 200041) behind the AMD
      # sensor-fusion hub -- readings sat at a flat 0 because nothing held the
      # device open (in_illuminance_raw only updates once something polls it).
      # iio-sensor-proxy is that consumer, and the D-Bus interface GNOME/KDE
      # auto-brightness both use; nothing here yet acts on the brightness
      # itself -- see plans/auto-brightness-z14.md.
      hardware.sensor.iio.enable = true;

      # AirPlay audio *out* (carried over from g14, now retired): z14 is the sender,
      # turning reachable AirPlay/Sonos receivers into PipeWire sinks. Needs
      # three things PipeWire doesn't do alone: avahi (module-raop-discover
      # browses mDNS via avahi's client lib; publish stays off, this only
      # browses), the raop-discover module (not in PipeWire's default set),
      # and firewall holes for the control/timing ports a receiver connects
      # back on (silent failure otherwise -- a Sonos answers up to SETUP and
      # never replies). AirPlay 1 (RAOP) only -- PipeWire has no
      # pair-setup/pair-verify for HomeKit pairing (an Apple TV 403s OPTIONS).
      # Receiving is the separate shairport-sync stack on 203-media
      # (modules/gigaplayer.nix).
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        openFirewall = true; # UDP 5353 in, or the discovery replies are dropped
      };
      services.pipewire.raopOpenFirewall = true; # UDP 6001-6002: RAOP control + timing
      services.pipewire.extraConfig.pipewire."10-airplay" = {
        "context.modules" = [ { name = "libpipewire-module-raop-discover"; } ];
      };

      # DisplayLink dock. Off by default (modules/work/default.nix) because
      # pkgs.displaylink is requireFile and needs the installer already in
      # the store -- fetched here via the option's own nix-prefetch-url, hash
      # verified against nixpkgs. 205-builder's offloaded build copies the
      # requireFile path across fine (verified, not assumed). Host-scoped
      # rather than under the "work" tag: it's a fact about this machine's
      # store, not about bedag.
      noughty.work.displaylink.enable = true;

      # Citrix Workspace: same requireFile shape as displaylink, but the
      # tarball isn't fetched yet (deliberately) -- next rebuild stops with
      # the package's own message naming the exact file and download page
      # (Citrix's click-through can't be scripted ahead of time). Fetch it
      # and rebuild:
      #
      #     nix-prefetch-url "file://$PWD/linuxx64-<version>.tar.gz"
      #
      # Drop this line to get a building config while that download waits.
      noughty.work.citrix.enable = true;

      # See acpMixerPaths above. asDropin because both units come from
      # packages via systemd.packages -- a plain definition would replace the
      # packaged unit wholesale instead of adding one line to it.
      systemd.user.services.pipewire = {
        overrideStrategy = "asDropin";
        environment.ACP_PATHS_DIR = "${acpMixerPaths}";
      };
      systemd.user.services.wireplumber = {
        overrideStrategy = "asDropin";
        environment.ACP_PATHS_DIR = "${acpMixerPaths}";
      };

      # Local LLM inference on the Radeon 840M. Three choices that each cost
      # a wrong turn to find:
      #
      # 1. Vulkan, not ROCm: rocminfo reports this iGPU as gfx1153, but
      #    rocmPackages.clr.gpuTargets stops at gfx1151 -- rocBLAS ships no
      #    code objects for it, so ollama-rocm would need
      #    HSA_OVERRIDE_GFX_VERSION to masquerade as gfx1102. RADV enumerates
      #    the device natively ("RADV GFX1153") and its closure is 34 MiB vs
      #    ollama-rocm's 2.2 GiB.
      # 2. OLLAMA_IGPU_ENABLE=1: ollama finds the iGPU and deliberately
      #    discards it by default ("dropping integrated GPU"), silently
      #    falling back to CPU.
      # 3. The unstable pin: 26.05 ships ollama 0.32.3, whose registry
      #    refuses qwen3.8 (HTTP 412) -- that needs 0.32.13, Flash-Next needs
      #    0.33.1; unstable is on 0.34.0. Drop this override once 26.05
      #    catches up.
      #
      # A 27B fits because RADV exposes the 6 GiB BIOS UMA carve-out plus the
      # ~12.5 GiB GTT aperture as one 18.5 GiB heap, so a 16.5 GiB q4_K_M 27B
      # needs no partial offload. GTT pages are ordinary system RAM though
      # (this host has no swap), and generation stays memory-bandwidth-bound
      # over shared LPDDR5x either way -- the iGPU earns its keep on prompt
      # processing, not tokens/s.
      #
      # user/group give the module's staticUser branch a real ollama user for
      # a stable uid (the 17 GiB blob store needs stable ownership across
      # restarts); the module still sets DynamicUser unconditionally, so
      # StateDirectory still resolves through /var/lib/private/ollama.
      #
      # OLLAMA_CONTEXT_LENGTH=32768: the module's VRAM-derived default lands
      # on a useless 4096. 32K is free -- measured 3.294 tok/s vs 3.286 tok/s
      # at 4K -- because KV at 32K (1920 MiB) just pushes ~1.8 GiB of weights
      # onto the CPU side of the same LPDDR5x bus. KV costs ~60 KiB/token
      # measured; the 48 Gated DeltaNet layers are a flat ~150 MiB regardless
      # of context, only the 16 Gated Attention layers scale. 64K needs
      # 3.75 GiB KV (fits, tight); 128K needs 7.5 GiB and won't fit alongside
      # a desktop session with no swap.
      services.ollama = {
        enable = true;
        package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.ollama-vulkan;
        environmentVariables = {
          OLLAMA_IGPU_ENABLE = "1";
          OLLAMA_CONTEXT_LENGTH = "32768";
        };
        user = "ollama";
        group = "ollama";
      };

      # Auto-brightness consumer (hardware.sensor.iio above only wakes the
      # ALS). wluma over clight/a hand-rolled timer per
      # plans/auto-brightness-z14.md: it learns a lux->brightness curve from
      # what you set by hand instead of shipping one, working with the
      # existing Super+I habit instead of against it.
      #
      # nixpkgs' wluma package builds only bin/wluma (postPatch drops
      # upstream's udev rule and unit), so both are recreated here:
      # 1. Config: this panel is amdgpu_bl1 / asus::kbd_backlight, not
      #    upstream's Dell defaults. /etc/xdg is first in XDG_CONFIG_DIRS so
      #    environment.etc suffices; the unit sets XDG_CONFIG_DIRS anyway
      #    since a systemd *user* unit doesn't inherit the login shell's env.
      # 2. A unit bound to hyprland-session.target (not
      #    graphical-session.target), same as everything under
      #    modules/hyprland.nix.
      #
      # Deliberately NOT added: upstream's udev rule + "video" group.
      # wluma's Backlight::new tries a direct sysfs write first and only
      # falls back to org.freedesktop.login1.Session.SetBrightness on
      # failure -- which it does here (file is root:root 0644) -- and that
      # D-Bus path (the same one brightnessctl/Super+I use) works because the
      # caller owns the active session, no group needed. Verified running as
      # phonkd (in dialout/wheel/networkmanager only, not video): logs show
      # it using D-Bus successfully.

      # Thresholds had to be measured: this sensor's scale=0.1/offset=0 means
      # a lit room at night reads raw=17 -> 1.7 lux -> cast to u64 1, so
      # upstream's ladder (which only breaks out "night" below 20 lux) would
      # leave this panel in the darkest bucket permanently. These thresholds
      # are that ladder compressed onto what the sensor actually produces;
      # confirmed classifying a lit room at night as "dark". To retune: read
      # in_illuminance_raw, divide by 10, adjust the nearest threshold --
      # getting one wrong only miscategorizes the bucket, wluma still learns
      # your preferred brightness inside it.
      #
      # Learned state lives outside Nix, in
      # ~/.local/share/wluma/<output-name>.yaml (eDP-1.yaml,
      # keyboard-asus.yaml) -- plain {lux, luma, brightness} YAML, survives
      # rebuilds; delete to make wluma forget and start over.
      #
      # Both outputs resolve enough steps to be worth listing: the panel
      # (max_brightness 399000) resolves 1% steps distinctly; the keyboard
      # (asus::kbd_backlight, max_brightness 3) only has 4 levels but that's
      # enough for the behaviour worth having (dark room on, daylight off).
      environment.etc."xdg/wluma/config.toml".text = ''
        [als.iio]
        path = "/sys/bus/iio/devices"
        thresholds = { 0 = "night", 1 = "dark", 3 = "dim", 10 = "normal", 30 = "bright", 100 = "outdoors" }

        [[output.backlight]]
        name = "eDP-1"
        path = "/sys/class/backlight/amdgpu_bl1"
        capturer = "none"

        [[keyboard]]
        name = "keyboard-asus"
        path = "/sys/class/leds/asus::kbd_backlight"
      '';

      # capturer = "none": screen-contents dimming (capturer = "wayland")
      # segfaults Hyprland 0.55.4 inside its own screencopy path
      # (CScreenshareFrame::copyDmabuf -> ... -> ~CHyprGLRenderbuffer
      # SIGSEGV) -- three crashes in ninety seconds took down the whole
      # session via Hyprland's watchdog safe-mode relaunch. Hyprland's bug,
      # not wluma's (wluma only requests frames through a protocol the
      # compositor advertises), but "none" sidesteps the path entirely
      # (feeds a constant luma, never touches Wayland) at the cost of
      # content-aware dimming. Worth retrying (set back to "wayland") on a
      # Hyprland bump.
      systemd.user.services.wluma = {
        description = "Adaptive brightness from ambient light";
        partOf = [ "hyprland-session.target" ];
        after = [ "hyprland-session.target" ];
        wantedBy = [ "hyprland-session.target" ];
        environment.XDG_CONFIG_DIRS = "/etc/xdg";
        serviceConfig = {
          ExecStart = lib.getExe pkgs.wluma;
          Restart = "always";
          RestartSec = 2;
        };
      };
    };
}
