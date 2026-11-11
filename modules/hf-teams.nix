{ ... }:
{
  flake.homeModules.hf-teams =
    { config, ... }:
    let
      # HF is a separate private checkout, updated outside Nix. A missing
      # checkout leaves a dangling skill link; evaluation/builds never read it.
      skill = config.lib.file.mkOutOfStoreSymlink
        "${config.home.homeDirectory}/git/HF/skills/hf-teams";
    in
    {
      home.file.".codex/skills/hf-teams".source = skill;
      home.file.".claude/skills/hf-teams".source = skill;
    };
}
