{ ... }:
{
  flake.homeModules.hf-teams =
    { config, ... }:
    {
      # HF is a separate private checkout, updated outside Nix. A missing
      # checkout leaves a dangling skill link; evaluation/builds never read it.
      home.file.".codex/skills/hf-teams".source =
        config.lib.file.mkOutOfStoreSymlink
          "${config.home.homeDirectory}/git/HF/skills/hf-teams";
    };
}
