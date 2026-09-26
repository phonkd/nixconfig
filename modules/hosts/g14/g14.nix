# Host-specific NixOS config for g14 (ASUS Zephyrus laptop), generated via
# modules/builder.nix from lib/registry.nix and referenced from the g14
# entry's extraModules (nixos-hardware imports can't live in alwaysImport --
# imports must stay unconditional).
#
# Long-form pattern: `imports` is unconditional; `config` is gated as
# defense-in-depth even though only ever loaded on g14.
{ self, ... }:
{
  flake.nixosModules.g14 =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # The GA401's fingerprint reader (Goodix 27c6:521d) has no mainline
      # libfprint driver -- the pid only appears in the autosuspend hwdb
      # whitelist, not a driver list, and Goodix ships none. The only working
      # driver is infinytum's reverse-engineered `goodixtls` fork (same code
      # as AUR's libfprint-goodix-521d), abandoned at libfprint 1.94.1
      # (Nov 2021) -- too old for nixpkgs' fprintd (needs >= 1.94.9). So we
      # graft just the driver (self-contained: a new drivers/goodixtls/ dir
      # plus meson wiring) onto current libfprint instead of running the
      # whole stale fork; upstream's test suite still passes.
      goodixtlsSrc = pkgs.fetchFromGitHub {
        owner = "infinytum";
        repo = "libfprint";
        rev = "5e14af7f136265383ca27756455f00954eef5db1"; # branch `unstable`
        hash = "sha256-MFhPsTF0oLUMJ9BIRZnSHj9VRwtHJxvWv0WT5zz7vDY=";
      };

      libfprint-goodixtls = pkgs.libfprint.overrideAttrs (old: {
        pname = "libfprint-goodixtls";

        postPatch = (old.postPatch or "") + ''
          cp -r ${goodixtlsSrc}/libfprint/drivers/goodixtls libfprint/drivers/
          chmod -R u+w libfprint/drivers/goodixtls

          # The fork treats this press sensor as a swipe sensor. See the patch
          # header; without it the sensor enrols but never matches.
          patch -p1 < ${./goodixtls-52xd-press-capture.patch}

          substituteInPlace meson.build \
            --replace-fail "    'goodixmoc',
    'nb1010'," "    'goodixmoc',
    'goodixtls511',
    'goodixtls52xd',
    'goodixtls53xd',
    'nb1010'," \
            --replace-fail "    'uru4000' : [ 'openssl' ]," "    'uru4000' : [ 'openssl' ],
    'goodixtls511' : [ 'openssl', 'goodixtls' ],
    'goodixtls52xd' : [ 'openssl', 'goodixtls' ],
    'goodixtls53xd' : [ 'openssl', 'goodixtls' ],"

          substituteInPlace libfprint/meson.build \
            --replace-fail "    'focaltech_moc' :
        [ 'drivers/focaltech_moc/focaltech_moc.c' ],
}" "    'focaltech_moc' :
        [ 'drivers/focaltech_moc/focaltech_moc.c' ],
    'goodixtls511' :
        [ 'drivers/goodixtls/goodix511.c' ],
    'goodixtls52xd' :
        [ 'drivers/goodixtls/goodix52xd.c' ],
    'goodixtls53xd' :
        [ 'drivers/goodixtls/goodix53xd.c' ],
}" \
            --replace-fail "    'openssl' :
        [ ]," "    'openssl' :
        [ ],
    'goodixtls' :
        [ 'drivers/goodixtls/goodix_proto.c', 'drivers/goodixtls/goodix.c', 'drivers/goodixtls/goodixtls.c' ],"

          # These three pids are now claimed by real drivers, so they must leave
          # the "no driver, just autosuspend" whitelist and gain driver sections
          # in the shipped hwdb. libfprint's own `udev-hwdb` test diffs the
          # checked-in file against the generated one, so it verifies this edit.
          substituteInPlace libfprint/fprint-list-udev-hwdb.c \
            --replace-fail "  { .vid = 0x27c6, .pid = 0x5110 },
" "" \
            --replace-fail "  { .vid = 0x27c6, .pid = 0x521d },
" "" \
            --replace-fail "  { .vid = 0x27c6, .pid = 0x538d },
" ""

          substituteInPlace data/autosuspend.hwdb \
            --replace-fail "usb:v27C6p5110*
" "" \
            --replace-fail "usb:v27C6p521D*
" "" \
            --replace-fail "usb:v27C6p538D*
" "" \
            --replace-fail "# Supported by libfprint driver nb1010" "# Supported by libfprint driver goodixtls511
usb:v27C6p5110*
 ID_AUTOSUSPEND=1
 ID_PERSIST=0

# Supported by libfprint driver goodixtls52xd
usb:v27C6p521D*
 ID_AUTOSUSPEND=1
 ID_PERSIST=0

# Supported by libfprint driver goodixtls53xd
usb:v27C6p538D*
 ID_AUTOSUSPEND=1
 ID_PERSIST=0

# Supported by libfprint driver nb1010"
        '';

        # `&payload` (guint8 (*)[N]) where a guint8* is wanted -- same
        # address, but GCC 14 makes this an error by default.
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = "-Wno-incompatible-pointer-types";
        };
      });
    in
    {
      imports = [
        "${builtins.fetchGit { url = "https://github.com/NixOS/nixos-hardware.git"; }}/asus/zephyrus/ga401"
      ];
      config = lib.mkIf (config.noughty.host.name == "g14") {
        # Shared desktop baseline (DE selection, steam, bluetooth, wheel,
        # networkmanager, nameservers, bolt, libinput quirks) lives in
        # modules/desktop.nix, gated on noughty.host.is.nixosDesktop.
        networking.hostName = "g14";

        boot.loader.systemd-boot.enable = false;
        boot.loader.limine = {
          enable = true;
        };
        boot.loader.efi.canTouchEfiVariables = true;

        systemd.tmpfiles.rules = [
          "w /sys/devices/system/cpu/cpufreq/boost - - - - 0"
        ];
        hardware.nvidia.prime = {
          offload.enable = lib.mkForce false;
          reverseSync.enable = true;
          allowExternalGpu = true;
        };
        programs.rog-control-center.enable = true;
        boot.extraModprobeConfig = ''
          options nvidia NVreg_EnableGpuFirmware=0
        '';
        hardware.nvidia = {
          open = false;
          powerManagement.enable = false;
          modesetting.enable = true;
        };
        systemd.services.nvidia-powerd = {
          unitConfig.StartLimitAction = "none";
          serviceConfig.Restart = "no";
          wantedBy = lib.mkForce [ ];
        };

        # EasyEffects preset tuned for the GA401's own speakers -- host-scoped
        # rather than in modules/desktop.nix's shared services.easyeffects. HM
        # writes extraPresets under the JSON's top-level key ("output" here),
        # so this lands at ~/.local/share/easyeffects/output/g14.json;
        # `preset` applies it via --load-preset on the daemon's ExecStart. The
        # file is a store symlink -- to retune, save under another name in
        # the GUI and copy that JSON over ./g14.json.
        home-manager.users.phonkd.services.easyeffects = {
          extraPresets.g14 = builtins.fromJSON (builtins.readFile ./g14.json);
          preset = "g14";
        };

        # AirPlay audio *out*: g14 is the sender, turning reachable receivers
        # into PipeWire sinks (PipeWire's own raop-{discover,sink} modules
        # are enough -- pointed at 203-media's shairport-sync, the RTSP
        # handshake completes and snapserver's Airplay stream goes
        # idle -> playing). Receiving is the separate shairport-sync stack on
        # 203-media (modules/gigaplayer.nix).
        #
        # Three things were missing: avahi (module-raop-discover browses
        # mDNS via its client lib; publish stays off, only browsing), the
        # raop-discover module (not in PipeWire's default set, hence the
        # drop-in below), and firewall holes for the control/timing ports a
        # receiver connects back on -- this is what actually broke LAN
        # playback, silently: a Sonos 200s OPTIONS/auth-setup/ANNOUNCE and
        # then never replies to SETUP, no error logged anywhere (confirmed by
        # 25s of passive capture on wlp2s0 seeing zero mDNS/SSDP packets from
        # three Sonos + an Apple TV on the LAN).
        #
        # AirPlay 1 (RAOP) only -- PipeWire has no pair-setup/pair-verify for
        # HomeKit pairing (the Apple TV here 403s the first OPTIONS); Sonos
        # speaks the legacy path and is the expected beneficiary.
        services.avahi = {
          enable = true;
          nssmdns4 = true;
          openFirewall = true; # UDP 5353 in, or the discovery replies are dropped
        };
        services.pipewire.raopOpenFirewall = true; # UDP 6001-6002: RAOP control + timing
        services.pipewire.extraConfig.pipewire."10-airplay" = {
          "context.modules" = [ { name = "libpipewire-module-raop-discover"; } ];
        };

        # Fingerprint reader (Goodix 27c6:521d): driven, provisioned, enrols
        # -- and left DISABLED, because it cannot authenticate. See
        # plans/g14-fingerprint.md.
        #
        # The driver works: captures are clean 64x80 images with
        # well-defined ridges, NBIS binarizes them correctly. But the sensor
        # window is only ~2.3 x 2.8 mm (measured from ridge period), which
        # physically contains just 1-2 minutiae -- NBIS finds exactly that,
        # and bozorth3's threshold of 24 needs an order of magnitude more, so
        # verification always scores 0. This is the sensor's size, not a bug
        # (and why upstream libfprint declined it); Windows only works via
        # Goodix's proprietary non-minutiae matcher.
        #
        # Do NOT "fix" this by lowering bz3_threshold: fprintAuth defaults to
        # services.fprintd.enable, so this sits in front of sudo and the
        # login greeter, and a threshold low enough to admit these scores
        # authenticates on noise.
        #
        # The libfprint graft, driver patch and
        # scripts/goodix-521d-provision.sh stay: the sensor is already
        # provisioned, so a non-minutiae matcher landing later is one
        # boolean away.
        services.fprintd = {
          enable = false;
          package = pkgs.fprintd.override { libfprint = libfprint-goodixtls; };
        };
      };
    };
}
