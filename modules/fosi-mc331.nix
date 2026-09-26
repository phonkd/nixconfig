# Fosi Audio MC331 -- stop the DSP noise gate chopping up quiet passages.
#
# The amp ships with its noise-suppressor threshold at -68 dB, which cuts off
# fade-ins and anything played quietly. Writable over USB, but the amp's MCU
# reloads the factory parameter set into the DSP at every power-on, so the
# packet has to be re-sent whenever the amp comes back -- hence a service, not
# a one-off. plans/fosi-mc331-noise-gate.md has the decoded frame format;
# modules/fosi-mc331-fix.py is the sender. Self-gates on the "fosi-mc331" tag.
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
        python = pkgs.python3.withPackages (ps: [ ps.pyusb ]);

        # No args -> the community Android app's payload verbatim, the only
        # thing confirmed to work: it carries the *stock* -68 dB threshold, so
        # it's the flags byte, not the threshold, that turns the gate off.
        # Arguments pass through for experiments: `fosi-mc331-fix -90` for a
        # threshold, `--flags 0x00` for the other reading of that byte.
        fosi-mc331-fix = pkgs.writeShellScriptBin "fosi-mc331-fix" ''
          exec ${python}/bin/python3 ${./fosi-mc331-fix.py} "$@"
        '';
      in
      {
        environment.systemPackages = [ fosi-mc331-fix ];

        # Match the USB device, not hidraw: this amp's HID interface has no
        # endpoints, so /dev/hidraw* never appears -- the sender talks control
        # transfers through /dev/bus/usb instead. Both PIDs matched because the
        # amp re-enumerates under a different one per input selector (1717 =
        # USB, 171E = OPT/AUX/BT); turning the selector also re-fires the fix.
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
