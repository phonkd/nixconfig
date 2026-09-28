# Zen Browser (a Firefox fork), with smooth scrolling turned on.
#
# A perSystem package rather than a bare `inputs.zen-browser...default`:
# modules/desktop.nix installs it into the user profile and
# modules/gui-session/_scope.nix builds an absolute store path for the SUPER-B
# launcher -- both must be the *same* derivation, or tuning one leaves the
# other (the one that actually launches) stock.
#
# How the prefs get in: `wrapFirefox`'s `extraPrefs` string is appended to
# the autoconfig file at lib/zen-*/mozilla.cfg -- profile-independent, which
# matters since Zen names its profile dirs randomly under ~/.zen (no fixed
# path for a home.file user.js).
#
# We call `wrapFirefox` ourselves on the input's *unwrapped* package, not
# `inputs'.zen-browser.packages.default.override { extraPrefs = ... }`: that
# `default` is built by `callPackage ./zen-browser.nix`, so `.override`
# overrides that file's *arguments* -- and since its signature ends in
# `...`, an unknown `extraPrefs` is silently dropped, building the
# byte-identical stock package.
#
# `defaultPref`, not `lockPref`: sets the *default* branch so about:config
# stays live-tunable. A pref already set by hand in an existing profile wins
# over the value below -- if a change seems to do nothing, check whether
# about:config shows that row as "modified".
{
  perSystem =
    {
      pkgs,
      inputs',
      ...
    }:
    {
      packages.zen-browser = pkgs.wrapFirefox inputs'.zen-browser.packages.zen-browser-unwrapped {
        pname = "zen-browser";

        extraPrefs = ''
          // Mouse wheel: the mass-spring-damper scroll model. Off by default
          // upstream, and the one switch that turns a wheel tick from a jump
          // into a glide.
          defaultPref("general.smoothScroll", true);
          defaultPref("general.smoothScroll.msdPhysics.enabled", true);

          // ScrollAnimationMSDPhysics::ComputeSpringConstant picks one of the
          // three constants below per event: a gap of at least
          // continuousMotionMaxDeltaMS since the last one means "fresh flick"
          // -> motionBegin, a slowing event rate -> slowdown, otherwise ->
          // regular. Dropping that threshold from its 120ms default to 12ms
          // puts every discrete wheel tick (tens of ms apart) in the first
          // bucket, so motionBeginSpringConstant is what governs wheel feel;
          // the other two govern the near-continuous stream a touchpad makes.
          //
          // All three are softer than stock (1250 / 1000 / 2000) -- a lower
          // spring constant is a longer, lazier settle.
          defaultPref("general.smoothScroll.msdPhysics.continuousMotionMaxDeltaMS", 12);
          defaultPref("general.smoothScroll.msdPhysics.motionBeginSpringConstant", 600);
          defaultPref("general.smoothScroll.msdPhysics.regularSpringConstant", 650);
          defaultPref("general.smoothScroll.msdPhysics.slowdownSpringConstant", 250);
          defaultPref("general.smoothScroll.msdPhysics.slowdownMinDeltaMS", 12);
          // Float-typed prefs are string-backed in Firefox: quote them, or
          // they parse as the wrong type and are silently ignored.
          defaultPref("general.smoothScroll.msdPhysics.slowdownMinDeltaRatio", "1.2");
          defaultPref("general.smoothScroll.currentVelocityWeighting", "1.0");
          defaultPref("general.smoothScroll.stopDecelerationWeighting", "1.0");

          // How far one wheel tick travels, as a percentage of stock. The
          // softer springs make a tick feel shorter, so it gets more ground to
          // cover. First knob to reach for if the feel is off.
          defaultPref("mousewheel.default.delta_multiplier_y", 200);

          // Touchpad, which does not use the MSD model at all: GTK pan
          // gestures go to APZ, which does its own pixel-precise panning and
          // fling. Both already default on under MOZ_ENABLE_WAYLAND (set in
          // modules/hyprland.nix); pinned here so the touchpad and
          // the wheel are described in one place.
          defaultPref("apz.gtk.pangesture.enabled", true);
          defaultPref("apz.gtk.kinetic_scroll.enabled", true);
          // Rubber-band at the ends of a page. Stock default is off on Linux.
          defaultPref("apz.overscroll.enabled", true);
        '';
      };
    };
}
