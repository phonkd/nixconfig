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
          additionalPrograms = [ ffmpeg ];

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
