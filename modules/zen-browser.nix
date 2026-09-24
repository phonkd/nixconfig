# Zen Browser (a Firefox fork), with smooth scrolling turned on.
#
# A perSystem package rather than a bare `inputs.zen-browser...default` at each
# use site, for the reason the hyprland helpers are packaged that way: there is
# more than one consumer. modules/desktop.nix installs it into the user profile
# and modules/hyprland/_scope.nix builds an absolute store path for the SUPER-B
# launcher, and those two must be the *same* derivation -- when they were two
# separate references, tuning one left the other stock, and the launcher is the
# one that actually starts the browser.
#
# How the prefs get in
# --------------------
# nixpkgs' `wrapFirefox` takes an `extraPrefs` string and appends it to the
# autoconfig file it writes at lib/zen-*/mozilla.cfg. That is the
# profile-independent route, which is what matters here: Zen names its profile
# directories randomly under ~/.zen, so a home.file user.js would have no fixed
# path to be written to.
#
# We call `wrapFirefox` ourselves on the input's *unwrapped* package rather than
# doing `inputs'.zen-browser.packages.default.override { extraPrefs = ... }`,
# which looks equivalent and is not. The input's `default` is built by
# `callPackage ./zen-browser.nix`, so the `.override` on it belongs to
# callPackage and overrides that file's *arguments* -- and since that file's
# signature ends in `...`, an unknown `extraPrefs` argument is accepted and
# silently dropped. The result builds happily to the byte-identical stock store
# path, which is exactly how this was first written and how it was caught.
#
# `defaultPref` rather than `lockPref` on purpose. These set the *default*
# branch, so about:config stays live-tunable while dialling the feel in and
# whatever wins comes back here. The flip side is that a pref already set by
# hand in an existing profile beats the value below -- if a change here seems
# to do nothing, check whether about:config shows that row as "modified".
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
          // modules/hyprland/_compositor.nix); pinned here so the touchpad and
          // the wheel are described in one place.
          defaultPref("apz.gtk.pangesture.enabled", true);
          defaultPref("apz.gtk.kinetic_scroll.enabled", true);
          // Rubber-band at the ends of a page. Stock default is off on Linux.
          defaultPref("apz.overscroll.enabled", true);
        '';
      };
    };
}
