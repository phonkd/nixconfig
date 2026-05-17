{ inputs, self, ... }:

{
  flake.homeModules.gaming =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      programs.prismlauncher.enable = false;
      home.packages = with pkgs; [
        (prismlauncher.override {
          # Add binary required by some mod
          additionalPrograms = [ ffmpeg ];

          # Change Java runtimes available to Prism Launcher
          jdks = [
            graalvmPackages.graalvm-ce
            zulu8
            zulu17
            zulu
          ];
        })
      ];
    };
}
