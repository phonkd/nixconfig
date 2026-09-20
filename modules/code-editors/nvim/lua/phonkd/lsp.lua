-- nvim-lspconfig. nixd is the only server configured here; `cmd` can stay a
-- bare name because modules/code-editors.nix puts it on the wrapper's PATH
-- via extraPackages, so it resolves even when nixd is not in the user profile.
local capabilities = require('cmp_nvim_lsp').default_capabilities()

vim.lsp.config('nixd', {
  capabilities = capabilities,
  cmd = { 'nixd' },
  filetypes = { 'nix' },
})
vim.lsp.enable('nixd')
