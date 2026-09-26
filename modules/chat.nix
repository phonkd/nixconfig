{
  self,
  inputs,
  config,
  pkgs,
  ...
}:

{
  flake.homeModules.desktop =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
      ];
    };

  flake.nixosModules.chat-server =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      imports = [ self.nixosModules.desktop ];
      config = {
        services.matrix-synapse = {
          settings = {
        
          };
        };
      };
    };
}
