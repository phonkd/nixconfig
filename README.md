# nixconfig

A [flake-parts](https://flake.parts) NixOS / nix-darwin / home-manager config built
around a **dendritic** module tree: features wire themselves up, and the homelab
dashboard builds itself from the modules that are active.

## Dendritic structure

`flake.nix` imports the whole module tree with one line:

```nix
imports = [ (import-tree ./modules) ];
```

[`import-tree`](https://github.com/vic/import-tree) recursively pulls in **every
`.nix` file under `modules/`** as a flake-parts module — there is no central list to
edit. Dropping a new file into `modules/` is the only step needed to add a feature.
Each file contributes named outputs (`flake.nixosModules.<name>`,
`flake.darwinModules.<name>`, `flake.homeModules.<name>`) that compose freely.

Hosts live in `lib/registry.nix`, the single source of truth: one stanza per machine
(`kind`, `platform`, `desktop`, `tags`, `gpu`, …). `modules/builder.nix` reads the
registry and routes each host by platform suffix (`*-linux` → `nixosConfigurations`,
`*-darwin` → `darwinConfigurations`).

## Self-activating modules

Modules are **not** hand-wired into each host. Instead they gate themselves on host
facts exposed by the `noughty` module (`lib/noughty/`):

- predicates like `noughty.host.is.nixosDesktop` / `is.darwinDesktop` / `is.server`
- freeform tags via `noughtyLib.hostHasTag "<tag>"`

```nix
# modules/homelab/apps/vaultwarden.nix — activates on any "homelab-server" host
flake.nixosModules.homelab-vaultwarden = { lib, noughtyLib, ... }:
  lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
    services.vaultwarden.enable = true;
    # ...
  };
```

Tag a host in the registry and every module guarding on that tag switches on. No host
file imports them explicitly.

## Auto-populating dashboard

Homelab apps register themselves in a central typed registry,
`phonkds.modules.<app>` (declared in `modules/phonkds-options.nix`). A *producer*
module just describes itself:

```nix
phonkds.modules.vaultwarden = {
  ip = "127.0.0.1";
  port = 8000;
  dashboard.enable = true;
  traefik = { enable = true; domain = "vw.w.phonkd.net"; };
};
```

The *consumer* — `modules/homelab/dashboard.nix`, gated on the `reverse-proxy` tag —
reads that registry, filters for apps that are dashboard- and Traefik-enabled with a
domain, and generates the [homepage-dashboard](https://gethomepage.dev) service list
automatically. The same registry feeds Traefik routing.

The net effect: enabling an app with `dashboard.enable = true` makes it appear on the
dashboard (and get proxied) with **no edits to the dashboard module**.

## Secrets

Two mechanisms, for two different consumers:

| | consumer | mechanism |
|---|---|---|
| `modules/homelab/global-secrets/` | **services** on homelab hosts | sops-nix, decrypted at activation into `/run/secrets` |
| `secretspec.toml` | **a human at a terminal** | [secretspec](https://github.com/cachix/secretspec), read on demand from Vaultwarden |

`secretspec.toml` at the repo root declares *which* secrets exist and where they
live, never their values, so it is checked in. `modules/secretspec.nix` installs
the `secretspec` and `bw` CLIs on every desktop and writes
`~/.config/secretspec/config.toml` pointing at our own Vaultwarden
(`vw.w.phonkd.net`).

### One-time setup per machine

The `bw` CLI keeps its own state in `~/.config/Bitwarden CLI/` and its server can
only be set while logged out, so this part is interactive rather than declarative:

```bash
bw config server https://vw.w.phonkd.net
bw login
```

S3 clients are deliberately left alone. `mc` and `aws` keep their own config
(`mc alias set …`, `aws configure`), set up by hand once per machine; feeding
them from secretspec was tried and reverted as more machinery than it was
worth. Pull the values with `secretspec get` when you need them.

### Daily use

```bash
bwu                                  # unlock, exports BW_SESSION into this shell
secretspec check                     # are all declared secrets resolvable?
secretspec get S3_ACCESS_KEY_ID
secretspec run -- <cmd>              # inject them into a command's environment
```

The provider URI pins `?server=https://vw.w.phonkd.net`. That does not configure
the `bw` CLI — it is an assertion secretspec checks before every operation, so a
CLI accidentally pointed at bitwarden.com fails loudly instead of quietly
answering from the wrong vault.
