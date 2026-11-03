# Lily58 configuration from the terminal

The split keyboard on `blac` is a Mechboards Lily58 Pro R2G, USB
`7171:0012`, running Vial protocol 6 with four layers. Its raw configuration
interface is `/dev/hidraw15` as of 2026-10-25; device numbering can change.
`modules/hosts/blac.nix` grants the `phonkd` group access to its HID interfaces.

[Vitaly](https://github.com/bskaplou/vitaly) provides native CLI commands for
reading and changing keys, layers, macros, combos and settings. Upstream
release 0.1.32 was downloaded, checked against its published SHA-256, and kept
at `~/.local/share/vitaly/0.1.32/vitaly`. No custom helper or package override
was added. The generic Linux binary needs the NixOS loader and libudev:

```sh
/nix/store/fsd4vbp9zjd9iaicq2fb9lpc1h5j973y-glibc-2.42-100/lib/ld-linux-x86-64.so.2 \
  --library-path /run/current-system/systemd/lib \
  ~/.local/share/vitaly/0.1.32/vitaly -i 18 devices -c
```

The loader path above was tested on 2026-10-25; locate the current glibc loader
if an upgrade or garbage collection removes it. Product ID 18 is hexadecimal
0012; always use `-i 18` to target the Lily58.

Replace `devices -c` with these native subcommands:

- `save -f /path/to/backup.vil`: back up the current configuration.
- `layers -n 0`: read the base layer.
- `layers -p`: read matrix coordinates for physical keys.
- `keys -l 0 -p ROW,COL`: read a key; add `-v KC_ESC` to assign Escape.
- `lock`: inspect lock status. `lock -u` starts the physical unlock procedure.
- `load -f /path/to/backup.vil`: restore a saved configuration.

Use each subcommand's `--help` before editing. Back up before changes, read
affected keys back afterward, and retain access to the layer-switching keys.
Some operations require the user to hold the physical unlock keys; follow the
tool's instructions rather than bypassing Vial security.

The initial backup, verified as valid JSON, is local to `blac`:
`~/.local/share/keyboard-backups/lily58/2026-10-25-before-agent-changes.vil`.
It contains the full configuration, including macros, so it is kept outside Git.
No keyboard mappings were changed while setting up this access.
