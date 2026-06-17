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

**Comments move things underneath them** when i use `gcc` to make a comment, the top line of the cell below goes above the output of the cell that I am commenting in. this is a weird behavior, I don't think im explaining it perfectly. I 1. run the cell, output is in the right place without any problem. 2. `gcc` the bottom line of a cell, and then the ouptput of the cell im in is in the next cell below the first line of that cell. I think this must relate to other problems I am having with behaviors of lines on the top/bottom of any given cell, that is something that I should look into.

### Cell ID desync

**RESOLVED (2026-06-16)** — fixed in `ws_handlers.lua` + `output.lua` + `server.lua`.
Re-keying now matches cells by **code content** (kernel-ready / update-cell-codes)
instead of by position; ids-only `update-cell-ids` with a count mismatch rebuilds
from disk then re-keys instead of bailing; and an unknown-id cell-op now triggers a
debounced **kiosk-WS resync** (marimo replays kernel-ready + outputs) instead of
being dropped. Covered both marimo 0.19.x (update-cell-ids path) and 0.23.x (reload
path). Tests in `tests/spec/ws_dispatch_spec.lua`. Original diagnosis kept below for
reference.

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

Proper fix (two parts) — both DONE 2026-06-16:

1. [x] `output.lua:handle_cell_op` — no longer drops cell-ops for unknown ids;
   warns once and triggers a debounced `server.resync_ws` (kiosk reconnect →
   marimo replays kernel-ready, which re-keys by code, and re-emits outputs).
2. [x] `rekey_cells_from_server` — no longer hard-bails on a count mismatch;
   re-keys by code content when codes are available (kernel-ready /
   update-cell-codes) and, for ids-only with a count mismatch, rebuilds
   nb.cells from disk then re-keys positionally.
   Repro+diagnosis chat: Claude Code session `fc7c2961-2fc8-4909-83b2-6d95b761b2f7`
   (2026-06-15), transcript at
   `~/.claude/projects/-Users-noahkugler-Documents-code-learning-ml-marimo/fc7c2961-2fc8-4909-83b2-6d95b761b2f7.jsonl`
   — resume with `claude --resume fc7c2961-2fc8-4909-83b2-6d95b761b2f7`. To confirm
   on a fresh repro: enable WS logging and `grep "unknown cell" /tmp/neo-marimo-ws.log`.

### Live sync / browser sharing

**Dropped output + broken bidirectional sync in share-with-browser mode**
(P0 + P1 done 2026-06-16; P2/P3 open). Symptom: with the browser open
(`<leader>mo`), cell output stops rendering in neo-marimo from the first
desynced cell onward — a matplotlib chart, and everything after it (incl. a
later `print("hello")`) — even though the marimo web editor shows it all.
Widget value changes also stopped propagating in both directions.

Root cause: cell-ops arriving under cell-ids neo-marimo's map no longer knows
were dropped (`output.handle_cell_op` early-return), and the self-heal —
`server.resync_ws`, a kiosk reconnect that replays kernel-ready+codes and
re-emits every cell-op (verified against marimo 0.23.9 with a headless probe:
both main *and* kiosk `kernel-ready` carry `cell_ids` + `codes`, and kiosk
replay re-emits one cell-op per cell) — was gated behind
`if srv.browser_active then return false end`, i.e. disabled in exactly the
shared-editing case it was meant to fix. Same machinery as **Cell ID desync**
above (the resync churn there also widens this window). Separately,
`/api/kernel/run` 500s with "Invalid session id" when nvim's kiosk (whose
consumer id == our session id) is detached during a reconnect gap, because
marimo's `get_session` only resolves our id via the consumer fallback while
the kiosk is attached.

- [x] P0 — `resync_ws` now runs regardless of `browser_active`, forcing kiosk
      when the browser is active so it can't kick the browser's main slot
      (`server.lua`).
- [x] P1 — nvim-only mode: `server.start_headless` + `:MarimoStart` +
      `<leader>ms` start the server and connect nvim as the sole main consumer
      with no browser tab. Most robust mode — no kiosk handoff churn.
- [ ] P2 — detect HTTP 500 "Invalid session id" in `server.http_post_raw`
      (run + set_ui_element_value) and reclaim/resync + retry once.
- [ ] P3 — confirm and fix the desync *root* (suspected: a reorder where
      `rekey_by_code` fails all-or-nothing and the positional fallback then
      mis-assigns). Use the new `:MarimoWsDebug` traces — `rekey:in`/`rekey:done`,
      `cell-op` known/unknown, `cell-op:DROP`, `resync dispatched` — added in
      `log.lua` + `output.lua` + `ws_handlers.lua` to see the divergence.

### Editing Issues

`/Users/noahkugler/Desktop/Screenshot\ 2026-06-14\ at\ 11.19.14 PM.png`

**Pressing enter goes to new cell** When I try to do something like a for loop, when i do `for i in thing:` and press enter, it creates a new cell rather than staying in the same cell. In fact, when I press enter in a new cell, it just adds one row to the end of the previous cell and then keeps one line in the new cell.

**`Shift O` on first line of cell** when I do `Shift O` to add a line above the only line in a cell, that line goes to the cell above. This doesn't just happen on shift O, this also happens when i try to press enter and move the one line in the cell down, same bug

**External Editing warning** need more info on when this happens

### other bugs

**Queued cell but still can use** sometimes I make a cell with a variable, and then run it and it is only saying queued. However, I can still use that variable later in the notebook, so it is working

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
