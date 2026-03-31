{ config, pkgs, ... }:

{
  flake.homeModules.gui-apps = {pkgs,...}: {
    home.packages = with pkgs; [
      nicotine-plus
      localsend
      (discord.override {
        #withOpenASAR = true;
        withVencord = true; # can do this here too
      })
    ];
  };

}
