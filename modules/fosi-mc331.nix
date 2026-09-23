# Fosi Audio MC331 -- stop the DSP noise gate chopping up quiet passages.
#
# The amp ships with its noise-suppressor threshold at -68 dB, which cuts off
# fade-ins, film ambience and anything played quietly. The threshold is
# writable over USB, but the amp's MCU reloads the factory parameter set into
# the DSP at every power-on, so there is nothing to configure once -- the
# packet has to be re-sent whenever the amp comes back. That is the whole
# reason this is a service and not a one-off.
#
# plans/fosi-mc331-noise-gate.md has the decoded frame format and the hardware
# reasoning; modules/fosi-mc331-fix.py is the sender.
#
# Self-gates on the "fosi-mc331" host tag.
{ ... }:
{
  flake.nixosModules.fosi-mc331 =
    {
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "fosi-mc331") (
      let
        # Hundredths of a dB are honoured. -90 is the field-proven value; stock
        # is -68. Lower = the gate stays out of the way for longer. The wrapper
        # takes an override, so `fosi-mc331-fix -80` tries one without a rebuild.
        threshold = "-90.0";

        python = pkgs.python3.withPackages (ps: [ ps.pyusb ]);

        # No args -> the configured threshold. Anything passed wins, so
        # `fosi-mc331-fix -80` or `fosi-mc331-fix --off` (disable the
        # suppressor outright) can be tried by hand without a rebuild.
        fosi-mc331-fix = pkgs.writeShellScriptBin "fosi-mc331-fix" ''
          if [ $# -eq 0 ]; then set -- ${threshold}; fi
          exec ${python}/bin/python3 ${./fosi-mc331-fix.py} "$@"
        '';
      in
      {
        environment.systemPackages = [ fosi-mc331-fix ];

        # Match the USB device, not hidraw: this amp's HID interface has no
        # endpoints, so usbhid never binds it and /dev/hidraw* never appears for
        # it -- the sender talks control transfers through /dev/bus/usb instead.
        #
        # Both PIDs are matched because the amp re-enumerates under a different
        # one depending on the input selector (1717 = USB, 171E = OPT/AUX/BT).
        # Handy side effect: turning the selector also re-fires the fix.
        services.udev.extraRules = ''
          ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8888", ATTR{idProduct}=="1717|171e", TAG+="systemd", ENV{SYSTEMD_WANTS}+="fosi-mc331-fix.service"
        '';

        systemd.services.fosi-mc331-fix = {
          description = "Lower the Fosi MC331 DSP noise-suppressor threshold";
          # [Unit], not [Service] -- systemd only reads the start-limit keys
          # there (same trap as the *arr units).
          startLimitBurst = 5;
          startLimitIntervalSec = 60;
          serviceConfig = {
            Type = "oneshot";
            # The MCU is still pushing factory defaults into the DSP for the
            # first couple of seconds after the amp appears on the bus; writing
            # before it finishes just gets overwritten.
            ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
            ExecStart = "${fosi-mc331-fix}/bin/fosi-mc331-fix";
            # The USB interface is single-owner: if ACPWorkbench or another
            # sender holds it, back off and try again rather than giving up.
            Restart = "on-failure";
            RestartSec = "5s";
          };
        };

        # Safety net for the cases udev can't see -- the amp coming out of a
        # standby that reloads the DSP without re-enumerating, or a missed
        # coldplug event. The sender exits 0 when the amp is absent, so this is
        # genuinely a no-op whenever the amp is off.
        systemd.timers.fosi-mc331-fix = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "5min";
          };
        };
      }
    );
}
