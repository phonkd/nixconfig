# Pure helper functions for noughty system attributes.
# No module system dependency; independently testable.
{ lib }:
{
  hostName,
  userName,
  hostTags,
  userTags,
}:
{
  isUser = users: lib.elem userName users;
  isHost = hosts: lib.elem hostName hosts;
  hostNameCapitalised =
    (lib.strings.toUpper (builtins.substring 0 1 hostName))
    + (builtins.substring 1 (builtins.stringLength hostName) hostName);
  hostHasTag = tag: lib.elem tag hostTags;
  userHasTag = tag: lib.elem tag userTags;
  hostHasTags = ts: lib.all (t: lib.elem t hostTags) ts;
  userHasTags = ts: lib.all (t: lib.elem t userTags) ts;
  hostHasAnyTag = ts: lib.any (t: lib.elem t hostTags) ts;
  userHasAnyTag = ts: lib.any (t: lib.elem t userTags) ts;
}
