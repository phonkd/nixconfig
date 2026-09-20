-- Neovim configuration. Loaded through programs.neovim.extraLuaConfig in
-- modules/code-editors.nix, which reads this file verbatim into the init.lua
-- home-manager generates.
--
-- There is no plugin manager here and nothing to bootstrap: Nix installs the
-- plugins and the nvim wrapper has them on the runtimepath before this file
-- runs, so a plain `require` at the top level already works. Adding a plugin
-- means adding it to the `plugins` list in modules/code-editors.nix; adding
-- configuration for it means a file under lua/phonkd/ and a line here.
--
-- The `phonkd.` prefix is load-bearing. ~/.config/nvim is *first* on the
-- runtimepath, ahead of every plugin, so a bare lua/telescope.lua would
-- shadow the telescope plugin's own `telescope` module and break the very
-- thing it configures. Namespacing keeps our modules in a corner nothing
-- else claims.
--
-- Order is the old plugin-list order, kept so the diff against the string
-- version stays readable. Nothing here depends on it: every plugin is already
-- loaded, so these only talk to each other through the config they set.
require("phonkd.colorscheme")
require("phonkd.telescope")
require("phonkd.completion")
require("phonkd.lsp")
require("phonkd.ui")
