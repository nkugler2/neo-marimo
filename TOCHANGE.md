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

**Dropped output + broken sync — ROOT CAUSE: WS frame > 1 MiB killed the
socket (FIXED 2026-06-17).** Symptom: cell output stops rendering in
neo-marimo from the first big-output cell onward — a matplotlib chart, and
everything after it (incl. a later `print("hello")`) — even though the marimo
web editor shows it all; widget changes stopped syncing both ways; and
`/api/kernel/run` 500s with "Invalid session id".

Real root cause (found from a snacks.nvim log dump, not the desync theory
below): `python/ws_client.py` called `websockets.connect()` with the library
**default `max_size` of 1 MiB**. marimo streams cell outputs as WS frames, and
one rich output (a matplotlib PNG, a large DataFrame's dataresource JSON, an
inline `data:` URI) exceeds 1 MiB, so `websockets` closed the connection with
**1009 MESSAGE_TOO_BIG**. That silently killed the WS mid-run: the oversized
cell-op was dropped, every cell-op after it was lost, and the now-detached
session made HTTP runs 500. The browser's native WebSocket has no such cap —
hence it always worked there. Reproduced both ways with a headless probe:
default → `1009 ... 1414068 bytes exceeds limit of 1048576`; `max_size=None` →
a 1.87 MB cell-op delivered cleanly.

- [x] **THE FIX** — `ws_client.py` now passes `max_size=None` (unbounded,
      matching the browser; kernel is local + trusted). Resolves the dropped
      chart/`print`, the 500, and the broken widget sync in one shot.
- [x] P1 — nvim-only mode: `server.start_headless` + `:MarimoStart` +
      `<leader>ms` start the server and connect nvim as the sole main consumer
      with no browser tab. Most robust mode — no kiosk handoff churn.
- [x] P0 (kept as hardening, NOT the root cause) — `resync_ws` now runs
      regardless of `browser_active`, forcing kiosk when the browser is active
      so it can't kick the browser's main slot. Still correct for genuine
      cell-id desyncs; just wasn't what bit here.
- [ ] P2 (now likely moot) — the 500 "Invalid session id" was a _downstream_
      symptom of the dead socket; with the frame no longer killing the WS the
      session stays attached. Revisit a `http_post_raw` 500 reclaim+retry only
      if 500s still appear.
- [ ] P3 — only if real cell-id desync resurfaces: use the new `:MarimoWsDebug`
      traces (`rekey:in`/`rekey:done`, `cell-op` known/unknown, `cell-op:DROP`,
      `resync dispatched`) added in `log.lua` + `output.lua` + `ws_handlers.lua`.

A diagnostic note for next time: when output silently stops mid-notebook,
check the ws_client stderr in `:messages` for `1009`/`MESSAGE_TOO_BIG` before
chasing cell-id logic.

**Images/figures never render in nvim — ROOT CAUSE: large stdout lines were
split across chunks and dropped (FIXED 2026-06-17).** Symptom: matplotlib
charts (and any large output) never appeared in nvim — as kiosk _or_ as the
main consumer (`<leader>ms`) — while the browser always showed them and small
outputs (text, sliders, markdown) rendered fine in nvim too. The user's logs
showed figure cells arriving with NO `output` field while later non-figure
cells had outputs, so the socket was alive — the big frame was simply missing.

Real root cause: `ws_client.py` writes each WS message as one newline-
terminated JSON line on stdout, and `server.lua`'s `connect_ws` `on_stdout`
handler decoded **each element of the jobstart `data` chunk as a complete
line**. But Neovim splits stdout on "\n" into chunks where the first element
continues the previous chunk's partial line and the last element is itself
partial (`:help channel-lines`). A rich cell-op — a matplotlib PNG is a single
multi-megabyte JSON line — spans many chunks, so every fragment failed
`json.decode` and was silently dropped (no `else`). Small outputs fit in one
chunk and survived. The browser uses a native WebSocket with no stdio bridge,
so it was never affected. This is also why "images worked when I added snacks"
— those early test images were small enough to fit a single pipe read.

- [x] **THE FIX** — `connect_ws` now reassembles partial lines across chunks
      via `M._reassemble_stdout` (carries the trailing partial in a per-job
      closure buffer, dispatches only newline-terminated lines). Proven with a
      deterministic headless-nvim probe: a 2 MB line arrives as 18 chunk
      fragments — old handler decoded 1/2 messages, new handler 2/2. Regression
      tests in `tests/spec/server_spec.lua`.
- [x] **Headless hardening (NOT the image fix)** — `server.lua` `M.start`
      spawns marimo with `env = { MPLBACKEND = "Agg" }` unless the user already
      set `MPLBACKEND`. Agg is the right backend for a headless figure-capturing
      server and stops a `plt.show()` cell from trying to open a macOS GUI
      window from the server subprocess. An earlier note claimed Agg made
      figures "render deterministically" — that was a degraded test harness,
      not reality; the stdout fix above is what actually fixes images.

Note on `plt.show()`: it returns None → no output, so it's a marimo
anti-pattern regardless — end figure cells with a bare `fig` / `plt.gca()`.

**Widget glyph didn't move when a value changed in the other editor
(browser→nvim FIXED 2026-06-17; nvim→browser is a marimo limitation).**
Symptom: change a slider in the marimo browser and nvim's dependent cells +
images recompute, but nvim's slider thumb stays put; change it in nvim and the
browser recomputes but its thumb stays put.

Root cause (confirmed by capturing cross-consumer WS traffic): when any
consumer sets a UI element value, marimo reruns the _dependent_ cells and
broadcasts a `variable-values` op with the new value, but it NEVER
re-broadcasts the widget's own cell-op. nvim handled neither `variables` nor
`variable-values`, so it never learned the new value. The widget's displayed
value comes from `data-initial-value` in its cached cell output (overlaid by
`widgets._value_overrides`), and nothing was updating that override on a
remote change.

- [x] **browser→nvim FIX** — `ws_handlers.lua` now handles `variables` (keeps
      name → declaring-cell, since a widget's object-id is `<declaring-cell>-<n>`)
      and `variable-values` (maps the changed variable to its widget, stashes a
      value override, re-renders the cell). Coerces int/float/bool/str; skips
      nulls, non-scalar datatypes (range-slider tuples), and cells that produced
      more than one widget (ambiguous). Verified both modes get `variables` +
      `variable-values` on connect (main and kiosk). New `find_by_object_prefix`
      in `widgets.lua`. Tests in `tests/spec/ws_dispatch_spec.lua`.
- [ ] **nvim→browser is NOT fixable from the plugin** — the browser receives
      the exact same `variable-values` broadcast and marimo's frontend doesn't
      reposition another session's widget from it either (it only re-renders a
      widget from the session's own interaction). The value and every
      downstream cell still sync both ways; only the _other_ editor's widget
      glyph stays put. Would need an upstream marimo change (or RTC).

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
