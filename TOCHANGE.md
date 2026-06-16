---
id: TOCHANGE
aliases: []
tags: []
---

# TOCHANGE — Backlog

Quick capture for things I want fixed or added. To turn an item into a formal
plan, copy it into the relevant phase in `docs/plan-phases-7-15.md` (the
current roadmap) and flesh out the implementation steps there.

---

## Open

### Markdown Rendering

**Improve markdown rendering** Changes were already made that improved the markdown rendering, but I want to improve it. Specifically, I would like the regular output that is just grey and italics to be more readable

**Bad Markdown rendering?** In the week one notebook, it looks like some of the markdown output came later then it was supposed to. Got rid of that notebook, but let me see if I can recreate it

**Markdown rendering not as wide as could be sometimes** So I make a 10x10 numpy array, but even though my screen is wide enough to view a 10x10 output, the lines truncate in a way, so each row of the 10x10 takes up 2 lines of output, while a 6x6 would have 1 row of output per row of the array. When I make my screen smaller it will adjust to take a smaller width, can I adjust it to take a bigger width? Like a 10x10 with 0s works, but not with larger numbers

### Cell Rendering

**Run text and output placement issues**: Sometimes the run button is in the cell, sometimes its below the cell. Sometimes output has the same issue. Ideally both of these things will go below the cell, and I will add more spacing or some subtle visuals to more clearly show the output

**Run button in wrong spot** if I have rune a cell, see the run icon in the cell, and then press enter, i sometimes see a new line within that run cell but the new line is under the run icon. the run icon should be at the bottom. Should try to see the exact cause of this, but maybe this is fixed by always having run after the cell

**Cell below what visable on my screen** when I create a new cell, and that cell is below what is visable in my screen in neovim, I cant press j to go down to it nor can I use ]m to go to that next cell, i have to do something like `zz` to center my screen where my cursor is, the last cell that is visable, and then I can see and navigate to the last cell

### Cell ID desync

This may have already been fixed, need to double check

**Cell-id desync → a cell silently stops working ("queued" forever, widget writes no-op)**
Hit this with two identical `mo.ui.slider` cells (`x`, `y`) in the week-one
notebook: `x` worked, `y` did not. Symptoms: on first load `y`'s widget didn't
render; after run-all it rendered but the slider thumb moved locally while the
downstream value never recomputed; re-running just the `y` cell sat on "queued"
forever. Browser worked fine for both, and browser→nvim read updates worked.

Root cause: nvim's cell-id for `y` (`nb.cell_by_id`) had diverged from the
kernel's id for that cell (a "shadow-registered" cell — see the existing
comment in `ws_handlers.lua` `update-cell-ids` handler, lines ~90-106). So
`/api/kernel/run` and `set_ui_element_value` for `y` targeted a cell the kernel
doesn't know; the kernel's responses came back under its real id and got
dropped by the unknown-cell early-return in `output.lua:handle_cell_op`
(`if not cell then … return`, ~line 562-580). The optimistic "queued" status is
set when the run is sent and never cleared because the idle cell-op is dropped.
It's the cell-id layer, NOT the render-side object-id (the `<marimo-ui-element>`
wrapper scoping in `tree_render.lua:408` captures object-ids correctly — ruled
that out).

Why only `y`: `rekey_cells_from_server` (`ws_handlers.lua:68`) maps cell-ids to
cells _by position_ and **hard-bails when `#cell_ids ~= #nb.cells`**. When a cell
is added/reordered in nvim and the order/count drifts from the kernel, the
rekey doesn't realign and one position ends up holding the wrong id.

Workaround that fixes it: clean restart of BOTH sides so ids are minted once
from the same on-disk file — `:w` to persist `# id:` comments, close the nvim
notebook (tear down the kiosk WS), stop the marimo server, restart and reopen.
Fresh `kernel-ready` re-keys every cell by position and they match again.

Proper fix (two parts):

1. `output.lua:handle_cell_op` — don't silently drop cell-ops for unknown ids;
   buffer them and replay after `kernel-ready`/`update-cell-ids` rekeys.
2. `rekey_cells_from_server` — don't hard-bail on a count mismatch; reconcile
   what can be matched (and/or fall back to the "or by scanning" the comment
   at `output.lua:561` already promises but never implements).
   Repro+diagnosis chat: Claude Code session `fc7c2961-2fc8-4909-83b2-6d95b761b2f7`
   (2026-06-15), transcript at
   `~/.claude/projects/-Users-noahkugler-Documents-code-learning-ml-marimo/fc7c2961-2fc8-4909-83b2-6d95b761b2f7.jsonl`
   — resume with `claude --resume fc7c2961-2fc8-4909-83b2-6d95b761b2f7`. To confirm
   on a fresh repro: enable WS logging and `grep "unknown cell" /tmp/neo-marimo-ws.log`.

### Editing Issues

`/Users/noahkugler/Desktop/Screenshot\ 2026-06-14\ at\ 11.19.14 PM.png`

**Pressing enter goes to new cell** When I try to do something like a for loop, when i do `for i in thing:` and press enter, it creates a new cell rather than staying in the same cell. In fact, when I press enter in a new cell, it just adds one row to the end of the previous cell and then keeps one line in the new cell.

**`Shift O` on first line of cell** when I do `Shift O` to add a line above the only line in a cell, that line goes to the cell above. This doesn't just happen on shift O, this also happens when i try to press enter and move the one line in the cell down, same bug

**External Editing warning** need more info on when this happens

## Ideas / rough requests

<!-- Add new items here. Keep them short — one or two sentences is enough. -->
<!-- When something gets promoted into the formal plan, move it to "Integrated" below. -->

---

## Integrated (removed from backlog)

The following were once in this file and are now fully done and reflected in the plan docs:

- Cell width fills the window, code soft-wraps (Phase 4.2)
- Bidirectional sync with the marimo browser (Phase 6)
- Hover information (`K`) works inside notebook cells (Phase 7)
- Toggle neo-marimo view on/off (`<leader>mv` / `:MarimoToggle`) (Phase 5.1)
- Marimo status icon in the statusline + `:MarimoServerList` (Phase 5.2)
- Visually distinct borders for `md`, `sql`, `mo` cell types (Phase 4.3)
- Enter in multi-line strings no longer corrupts cells (Phase 4.1)
- Database connections for SQL cells (Phase 10 in plan-phases-7-15.md)
- Widget UX improvements: single-widget smart act, ordered digit picker, tab cycling, pins, nudge (Phase 10 in plan-phases-9-12-detail.md)
