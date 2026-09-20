# Neovim, plus the language servers the editors here share.
#
# The Lua is not in this file. It lives in modules/code-editors/nvim/ as real
# .lua files -- init.lua and a lua/phonkd/ module per concern -- because Lua
# inside a Nix string is Lua that no tool can see: no syntax highlighting, no
# lua_ls, no `gf`, and an indentation mistake surfaces as a runtime error at
# nvim startup rather than at build time.
#
# Nix keeps the job it is good at: installing the plugins and the servers, and
# placing the config. The split is
#
#   extraLuaConfig             <- nvim/init.lua, read verbatim into the
#                                 init.lua home-manager generates
#   xdg.configFile."nvim/lua"  <- nvim/lua/, linked whole
#
# so adding a module means a file under nvim/lua/phonkd/ and a `require` line
# in nvim/init.lua, and nothing in this file changes.
#
# modules/code-editors/ needs no leading underscore the way modules/hyprland/'s
# helpers do: import-tree only claims paths ending in .nix, and there are none
# in there.
{ config, pkgs, ... }:

{
  flake.homeModules.code-editors =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        nil
        nixd
        yaml-language-server
        sox
      ];

      xdg.configFile."nvim/lua".source = ./code-editors/nvim/lua;

      programs.neovim = {
        enable = true;
        vimAlias = true;
        defaultEditor = true;
        extraPackages = with pkgs; [
          ripgrep
          fd
          nil
          nixd
        ];
        extraLuaConfig = builtins.readFile ./code-editors/nvim/init.lua;
        # Order is no longer load-bearing -- configuration order is decided by
        # the `require`s in init.lua now -- but it is kept as it was so the
        # diff against the previous, config-carrying list stays readable.
        plugins = with pkgs.vimPlugins; [
          catppuccin-nvim
          telescope-nvim
          plenary-nvim # telescope dependency
          vim-nix
          luasnip
          cmp_luasnip
          cmp-nvim-lsp
          nvim-cmp
          nvim-lspconfig
          neoscroll-nvim
          vim-markdown
          bullets-vim
          vim-table-mode
          render-markdown-nvim
        ];
      };
    };
}
