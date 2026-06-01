---
id: Cross-phase-and-phase-4-issues
aliases: []
tags: []
---

# Issues in the most recent run

There are issue with the most recent run that you did.

## Cell issues

It seems like the change that you made to stop creating new cells when I press enter worked, but now there are some bugs.

For example, when I try to create a new cell, there are issues and I get the following warning repeadititly:

```
vim.schedule callback: .../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:145: Invalid 'line': out of range
stack traceback:
	[C]: in function 'nvim_buf_set_extmark'
	.../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:145: in function 'render_cell_borders'
	.../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:171: in function 'render_all_borders'
	.../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:318: in function 'on_bytes_changed'
	...im/site/pack/core/opt/neo-marimo/lua/neo-marimo/init.lua:144: in function 'fn'
	...m/site/pack/core/opt/neo-marimo/lua/neo-marimo/utils.lua:11: in function ''
	vim/_core/editor.lua: in function <vim/_core/editor.lua:0>
vim.schedule callback: .../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:145: Invalid 'line': out of range
stack traceback:
	[C]: in function 'nvim_buf_set_extmark'
	.../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:145: in function 'render_cell_borders'
	.../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:171: in function 'render_all_borders'
	...im/site/pack/core/opt/neo-marimo/lua/neo-marimo/init.lua:193: in function 'fn'
	...m/site/pack/core/opt/neo-marimo/lua/neo-marimo/utils.lua:11: in function ''
	vim/_core/editor.lua: in function <vim/_core/editor.lua:0>
vim.schedule callback: .../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:145: Invalid 'line': out of range
```

It seems like the first time I make a cell after opening a notebook, it works, But then the second time and onward, it breaks

When I tried to delete a cell, I also got a warning (I think this is the right one):

```
E5108: Lua: .../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:145: Invalid 'line': out of range
stack traceback:
	[C]: in function 'nvim_buf_set_extmark'
	.../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:145: in function 'render_cell_borders'
	.../site/pack/core/opt/neo-marimo/lua/neo-marimo/buffer.lua:171: in function 'render_all_borders'
	...site/pack/core/opt/neo-marimo/lua/neo-marimo/keymaps.lua:101: in function <...site/pack/core/opt/neo-marimo/lua/neo-marimo/keymaps.lua:80>
```

Sometimes when I delete cells, they fold into the cell before them. I'm not exactly sure the exact behaviour of it, it is just sometimes deleting cell n+2 then foldes that cell around cell n+1. it will shift cells up from the point that i deleted, so the ones below it go up into the deleted one kind of I think.

When I exit neovim and go back in, all the cells appear to be right, even the ones that I edited while the plugin was not working right and throwing errors.

## Misc.

1. AI told me that when I plot something and it makes a picture, there should be placeholder text, but there isn't any.
2. When i drag the window from the right to left to make my screen smaller, the cells nicely and smoothly shrink in size as i drag the window. But when I drag the window out back to full width, the cell drawing is janky and bad and kind of slow. I would like that to be more polished and clean
3. I don't know if ` require("neo-marimo").setup({ ui = { wrap_cells = false } }),` is working, but that could be on me.
4. `MarimoNewCell above` does not work properly. When I tried to do it from the first line of a cell, it took the text of the first line and put it in the new cell above.
