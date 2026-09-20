-- Presentation plugins that only need their defaults turned on.
--
-- neoscroll-nvim: smooth scrolling for <C-d>/<C-u> and friends.
require('neoscroll').setup()

-- render-markdown-nvim: in-buffer rendering of headings, tables and code
-- fences. vim-markdown, bullets-vim and vim-table-mode are installed next to
-- it and need no setup call of their own.
require('render-markdown').setup({})
