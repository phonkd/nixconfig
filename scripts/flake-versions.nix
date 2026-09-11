# The software versions one host actually runs, for the weekly flake.lock
# update PR (.github/workflows/flake-update.yml). scripts/flake-versions.sh
# calls this once per host, so a host that fails to evaluate costs only its
# own entries, not the whole report.
#
# Collects, keyed by pname:
#   - the package of every enabled `services.<x>` that has one  -> "service"
#   - environment.systemPackages + every HM user's home.packages -> "package"
#
# This only reads option values -- nothing is built.
{
  flakeRef,
  host,
  kind ? "nixos",
}:
let
  flake = builtins.getFlake flakeRef;
  inherit (flake.inputs.nixpkgs) lib;
  configs = if kind == "darwin" then flake.darwinConfigurations else flake.nixosConfigurations;
  cfg = configs.${host}.config;
  opts = configs.${host}.options;

  tryShallow =
    default: x:
    let
      r = builtins.tryEval x;
    in
    if r.success then r.value else default;
  # tryEval is shallow; deepSeq so a throw hiding in a field is caught here
  # rather than when the JSON is printed. Only for the small {name, version}
  # records -- deepSeq on a derivation recurses forever.
  try = default: x: tryShallow default (builtins.deepSeq x x);

  describe =
    category: p:
    try [ ] (
      if !(lib.isDerivation p) then
        [ ]
      else
        let
          parsed = builtins.parseDrvName p.name;
          version = toString (p.version or parsed.version);
        in
        lib.optional (version != "") {
          name = p.pname or parsed.name;
          inherit version category;
        }
    );

  # Walk the option *declarations*, not config: renamed/removed options
  # (services.frp.enable, services.bitwarden_rs, ...) are hidden aliases whose
  # value `abort`s -- which tryEval cannot catch -- so they must never be read.
  realOption = o: lib.isOption o && (o.visible or true) != false;

  services = lib.concatMap (
    n:
    let
      o = opts.services.${n};
      s = cfg.services.${n};
    in
    try [ ] (
      if
        builtins.isAttrs o
        && !(lib.isOption o)
        && realOption (o.enable or null)
        && realOption (o.package or null)
        && s.enable == true
      then
        describe "service" s.package
      else
        [ ]
    )
  ) (builtins.attrNames opts.services);

  packages = lib.concatMap (describe "package") (
    tryShallow [ ] cfg.environment.systemPackages
    ++ lib.concatMap (u: tryShallow [ ] u.home.packages) (
      lib.attrValues (cfg.home-manager.users or { })
    )
  );
in
lib.mapAttrs (_: es: {
  kind = if lib.any (e: e.category == "service") es then "service" else "package";
  versions = lib.unique (
    lib.sort (a: b: builtins.compareVersions a b < 0) (map (e: e.version) es)
  );
}) (lib.groupBy (e: e.name) (services ++ packages))
