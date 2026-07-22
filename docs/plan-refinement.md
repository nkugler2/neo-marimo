---
id: plan-refinement
aliases: []
tags:
  - roadmap
  - planning
---

# neo-marimo — Plan: Refinement Pass (pre-release hardening)

> **Written:** 2026-07-01, from a four-agent full-codebase review (editing
> core, server/sync/transport, rendering stack, architecture/contributor
> experience). Findings marked **[confirmed]** were reproduced in live
> headless-nvim probes or verified end-to-end in the code; **[plausible]**
> items have a stated mechanism but need a repro.
>
> **Relationship to other plans:** this plan comes **before**
> [`plan-release.md`](plan-release.md) (R0–R7) and pauses
> [`plan-phases-7-15.md`](plan-phases-7-15.md) feature work. Rule of the
> pass: **no new features** — bugs, compounding architecture risks, and
> API-freeze prep only. R-phase items (LICENSE, stylua, CONTRIBUTING, R0
> config defaults) stay in plan-release.md; the one overlap is noted in F6.

## How to execute

Each `F*.n` item is sized for one implementer-subagent task: a scoped
change + regression test + `make test`. Phases are ordered by risk:
**F1** (data loss / silent corruption) → **F2** (daily-drive UX bugs with
known one-shot fixes) → **F3** (the one phase-sized architectural fix) →
**F4** (extension-API hardening before v0.1.0 freezes it) → **F5**
(consistency/observability) → **F6** (docs + coverage backfill). Don't
bundle items into one commit; each verifies independently.

Standing rules for every item: keep "why" comments, add new rationale
comments for non-obvious fixes, module-level single-instance state is by
design, regression test in the matching `*_spec.lua`
(`editing_spec.lua` for cell-tracking).

---

## Phase F1 — Data loss & silent-corruption fixes (do first) **DONE**

### F1.1 Undo of a multi-cell delete merges cells into the preceding cell **[confirmed — data loss]** **DONE**

`notebook.lua:218-282` (`try_undo_restore`), `notebook.lua:189-207`
(`push_undo_trash`).

Repro: cells a,b,c,d,e → `V2jd` deleting b,c,d → `u`. Buffer text comes
back, but the model ends as `a("a=1\nb=2\nc=3\nd=4"), e` — b/c/d are
absorbed into `a` and their IDs are gone permanently. Mechanism: each
deleted cell gets its own trash entry keyed by `(start_row, line_count)`,
but vim's undo restores the whole span as **one** on_bytes insertion whose
delta equals the *combined* line count — it matches no single entry, falls
through to the generic sync path, and the restored rows glue onto the
preceding anchor. `assert_consistent` can't catch it: the result is
row-contiguous and self-consistent; the corruption is semantic.

- [x] DONE Extend `try_undo_restore` to also match a **contiguous run** of
      trash entries (sorted by original `start_row`) whose summed
      `line_count` equals the delta and whose first `start_row` equals the
      insertion row; splice all matched cells back in order.
- [x] DONE Regression test in `editing_spec.lua`: capture IDs for a 3-cell
      `V2jd` span, undo, assert `#nb.cells` **and every id + code**
      (the existing multi-line-delete case at `editing_spec.lua:133-143`
      never undoes, and the offset validator passes on the merged state —
      assert IDs explicitly).
- [x] DONE Document the known limitation (B2 from review): an intervening edit
      between delete and undo shifts rows so the trash entry no longer
      matches; the cell returns with a fresh ID. One rationale comment at
      the match site; not fixable cheaply.

### F1.2 "Queued forever" — run gate stamped even when re-key bailed **[confirmed]** **DONE**

`ws_handlers.lua:177-185`. The `update-cell-ids` handler stamps
`nb._last_cell_ids_at` **unconditionally**, but `rekey_cells_from_server`
(`ws_handlers.lua:121-156`) can bail without reconciling (count-mismatch
while `sync.is_writing`, or `rekey:fail` after a disk rebuild).
`actions.flush_pending_edits` (`actions.lua:35-49`) treats the stamp as
"IDs are safe now" and lets the run POST under a stale local ID. The
kernel runs it (hence "the variable works later"), the eventual real
re-key rebuilds `cell_by_id` and drops the old mapping, and the terminal
`idle` cell-op arrives under the old ID → dropped as unknown → the
optimistic `queued` status never clears. This is the open TOCHANGE
"Queued cell but still can use" bug.

- [x] DONE `rekey_cells_from_server` returns `true`/`false` for "actually
      reconciled"; stamp `_last_cell_ids_at` only on `true`. Leave the
      `reload` (0.23+) handler's unconditional stamp alone — correct by
      design and already covered by `ws_dispatch_spec.lua:47-79`.
- [x] DONE Test in `ws_dispatch_spec.lua`: `update-cell-ids` with count
      mismatch + `sync.is_writing` true → `_last_cell_ids_at` must NOT
      advance (the exact gap that let this ship).
- [ ] Optional confirm on a live repro: add two cells in quick
      succession, run each immediately, check `:MarimoWsDebug` log for a
      `cell-op:DROP` whose ID isn't in `known_ids`.

### F1.3 `ws_client.py` dies silently on abnormal WS close (exit 0) **[confirmed]** **DONE**

`python/ws_client.py:63-72, 118-123`. The receive pump guards only
`json.loads`; the `async for raw in ws:` iteration is unguarded, so a
`ConnectionClosedError` (kernel restart, session eviction) raises inside
the task. `main()` uses `asyncio.wait(..., FIRST_COMPLETED)` and never
calls `task.exception()` — the exception is discarded, the process exits
**0**, and `server.lua:574` only warns on nonzero. A dead WS looks like a
clean shutdown: no warning, and any in-flight run is stuck at "queued"
with nothing left to trigger the resync self-heal.

- [x] DONE After `asyncio.wait`, check `task.exception()` on the done set; on
      error, emit `{"op": "neo_marimo_error", ...}` and `sys.exit(1)` so
      `on_exit` warns. Wrap the `async for` to distinguish clean vs
      abnormal `ConnectionClosed`.
- [x] DONE Minimal python test (first in the repo): feed a mock WS iterator
      that raises into the pump; assert nonzero exit + `neo_marimo_error`
      emitted. If a python harness is too much scaffolding for one test,
      an inline `python3 -c` smoke check driven from `server_spec.lua` is
      acceptable — but say so in the commit message.

### F1.4 `# id:` comment matching disagrees between Lua and Python **[confirmed mechanism]** **DONE**

Two halves, fix together with one shared, stricter rule
("an id comment counts only when immediately preceding `@app.cell`"):

- `sync.lua:90-99` `strip_id_comments` strips **any** `# id: XXX`-shaped
  line before hashing for the own-write dedup — a user's literal comment
  of that shape can make an external edit false-positive as "our own
  echo" and get silently swallowed by the watcher.
- `python/bridge.py:24-47` `extract_cell_ids`: a user comment matching
  the pattern as the *last* line of cell N's body is misattributed as the
  id-comment of cell N+1 when N+1 has no id yet; a collision with a real
  ID would silently overwrite a `cell_by_id` entry.
- [x] DONE Bridge round-trip test: cell whose body ends with `# id: user123`,
      followed by a fresh id-less cell → the fresh cell must NOT inherit
      `user123`. Add an `async def` cell round-trip case while there
      (currently uncovered).

### F1.5 `prune_phantoms` can empty the notebook **[plausible]** **DONE**

`notebook.lua:136-176` has no last-cell guard, unlike `delete_cell`
(`notebook.lua:77-91`, refuses when `#nb.cells <= 1`). A compound delete
that collapses every remaining cell's range in one pass leaves
`nb.cells == {}`; nothing re-seeds, and `sync.write_to_file` / marimo
assume ≥1 cell.

- [x] DONE Mirror the guard: never prune the last survivor; keep the
      least-broken candidate. Direct unit test on `prune_phantoms` with a
      synthetic all-collapsed `nb.cells`, assert non-empty result.

---

## Phase F2 — Output positioning & daily-drive UX bugs **DONE**

> F2.1 is the keystone: three independently-reported TOCHANGE bugs
> (run-icon placement, Enter-under-icon, `gcc` shifting output) share it.

### F2.1 Output/status extmark: wrong gravity + never repositioned **[confirmed, reproduced twice independently]** **DONE**

Two compounding causes, one fix site:

1. **Creation-order stacking.** `buffer.lua:283` (bottom border,
   `ns_border`) and `output.lua:564` (status+output, `ns_output`) anchor
   at the same `(cell.end_row, 0)` with `virt_lines_above = false`.
   Verified empirically: nvim renders same-anchor virt_lines in **extmark
   creation order — the `priority` field does not order them**.
   `render_all_borders` recreates every border mark on every buffer
   mutation; output marks only re-render on cell-ops. Relative age flips
   nondeterministically → "run icon sometimes inside the cell, sometimes
   below."
2. **Dead anchor + default gravity.** The `ns_output` mark is placed at a
   plain integer row with default `right_gravity = true` and never
   revisited by `refresh_after_mutation` (`buffer.lua:425-434`). Typing
   `<CR>` at the end of the last line grows the buffer past the pinned
   mark → new text appears **under** the run icon. `gcc` on the last line
   (delete+insert of that exact line) makes the right-gravity mark ride
   the insertion onto the next cell's start row → output renders after
   the next cell's top line. Both reproduced with isolated probes;
   `right_gravity = false` empirically pins the `gcc` case.

- [x] DONE `output.lua:564`: pass `right_gravity = false`.
- [x] DONE Re-render/reposition outputs after border redraws: stash the
      debounced `redraw_outputs` that `init.lua:278-288` already built
      for WinResized onto the notebook (e.g. `nb._redraw_outputs`) and
      call it from `refresh_after_mutation` after `render_all_borders`,
      for cells with `cell.output or cell.console` set. This makes output
      marks always younger than border marks (fixes stacking order
      deterministically) and re-anchors them to the live `end_row`.
- [x] DONE Regression tests: (a) in `output_spec.lua` — render output, replace
      the cell's last line (gcc-style delete+insert), assert the
      `ns_output` mark row still equals the cell's current `end_row`;
      (b) in `editing_spec.lua` — border + output extmark order via
      `nvim_buf_get_extmarks(..., {details=true})` after an unrelated
      edit elsewhere in the buffer.

### F2.2 New cell below the viewport is unreachable (`j` / `]m` dead until `zz`) **[confirmed]** **DONE**

`init.lua:14-22` and `actions.lua:51-57` are two duplicate copies of
`jump_to_cell`, both a bare `nvim_win_set_cursor` with no scroll/redraw.
virt_lines-inflated buffers desync the viewport on programmatic cursor
moves; `keymaps.lua:309-335` (`focus_cycle`) already discovered this and
follows the move with `normal! zz` + `redraw` — the two `jump_to_cell`
copies never got the treatment.

- [x] DONE Consolidate into one shared helper (in `buffer.lua` or a small
      `cell_nav.lua`) with the `zz` + `redraw` handling; point `init`,
      `actions`, and (if reasonable) `focus_cycle` at it.

### F2.3 `cell.console` grows without bound **[confirmed]** **DONE**

`output.lua:527-537, 675-686`. `cell.output` is capped (`MAX_LINES = 30`)
but console entries accumulate across cell-ops untrimmed and every line
of every historical entry re-renders on each pass — a print-heavy loop
re-opens exactly the freeze scenario `MAX_OUTPUT_BYTES` was written to
prevent.

- [x] DONE Cap `cell.console` on append (drop oldest) and/or apply
      `MAX_LINES`-style truncation to the console block in `M.render`.
      Test alongside the existing output-truncation case
      (`output_spec.lua:77`).

### F2.4 Plain output/markdown body text is unreadable grey italic **[confirmed]** **DONE**

`highlights.lua:31` links `MarimoOutputText` to `Comment` — dim + italic
by design in most colorschemes, and it's used both for all plain
`repr()` output (`output.lua:95`) and as the base for unmarked markdown
prose (`markdown.lua:139`). This is the open TOCHANGE readability item.

- [x] DONE Give `MarimoOutputText` its own normal-brightness, non-italic
      definition (e.g. the Kanagawa fg `#DCD7BA` already used by
      `MarimoMarkdownBold`), and split the two semantic uses into
      `MarimoOutputText` vs `MarimoMarkdownText` so they can be tuned
      independently.

### F2.5 Stale widget value overrides after cell delete (one-liner) **DONE**

`actions.lua:106-159` calls `widgets.clear_for_cell` but not
`widgets.clear_overrides_for_cell` (`widgets.lua:72-78`); overrides are
keyed by object_id at module level and leak until session end. Note in
the code why undo-restore of the same cell benefits from lazy clearing if
that motivated the current shape — if so, clear on trash-expiry instead.

### F2.6 Orphaned image placements after cell re-key / disk reload **[confirmed — duplicate stale graph]** **DONE**

> Found 2026-07-03 from a live repro (two versions of a plot in one
> notebook: stale values above, fresh below, revealed at different
> scroll positions). Same defect class as F2.5: module-level registries
> keyed by `cell.id` that nobody reconciles when ids change.

`image.lua:164` `_placements[bufnr]` is keyed by `cell.id`, and
`render_path` tears down the previous placement under that same key
before drawing — correct only while ids are stable. But
`rekey_by_position` / `rekey_by_code` (`ws_handlers.lua:81-110`)
overwrite `cell.id` in place, and `sync.reload_from_file` rebuilds
`nb.cells` as brand-new objects with fresh local ids; nothing migrates
or clears the placement registry (`image.clear_for_cell` is only called
from `output.lua`'s render path and `clear_all`, which only the
kernel-restart action and clear-outputs keymap reach). After an id
flip, the next render looks up the new id, finds nothing to clear, and
draws a **second** backend placement; the orphan keeps painting at its
old row (image.nvim/snacks own extmark) until session end.
`widgets._by_cell` has the identical exposure — invisible only because
it paints no pixels.

- [x] Migrate keyed registries on re-key: build the old→new id mapping
      in both rekey fns and remap `image` placements (via a public
      accessor, not by reaching into `_placements`) and the widget
      registry in one shared helper. (`migrate_registries` in
      ws_handlers; two-pass collect-then-apply remap in both modules so
      id swaps/chains can't drop or double an entry. Widget value
      overrides/pins confirmed keyed by server-minted object_id — no
      migration needed.)
- [x] `reload_from_file`: tear down the buffer's image placements and
      widget registry entries — the rebuilt cells are new objects, so
      the old keys are permanently unreachable. This also covers the
      `reload` (0.23+) ws handler, which goes through it. (Verified:
      the rekey count-mismatch fallback clears under old ids then
      no-ops the migration for the never-registered fresh ids.)
- [x] Tests: `ws_dispatch_spec.lua` — placement registered under the
      old id is still owned (and cleanly replaceable) after an
      `update-cell-ids` re-key flips ids; reload path closes
      placements (close-spy called). (189 passing.)

### F2.7 tmux kitty-graphics fossils: no cleanup at exit, no sweep at attach **[confirmed mechanism]** **DONE**

> Follow-up to F2.6 and the Deferred tmux-ghost note. Inside tmux
> (`allow-passthrough on`), kitty-graphics images outlive nvim: the
> terminal keeps the pixels, tmux doesn't know they exist, and nothing
> deletes them — `init.lua`'s BufWipeout cleanup closes watcher/LSP/
> server but not image placements, and there is no VimLeavePre hook.
> A session that exits (or crashes) with a plot onscreen leaves a
> fossil that the next session shows as a "stale graph." Timeline
> evidence: ghosts became routine when F1.2 (2026-07-02) made id-flip
> re-keys common (orphaning placements pre-F2.6); post-F2.6 the log
> shows clean single placements, and outside tmux there are no ghosts.

- [x] Close all image placements at exit (`VimLeavePre`) and in the
      BufWipeout cleanup (`image.clear_for_cell(bufnr)`), so normal
      session ends stop minting fossils. (`image.clear_all()`; the
      VimLeavePre hook is module-level, once per session, pcall'd.)
- [x] Attach-time ghost sweep: when `$TMUX` is set and an image backend
      exists, emit the kitty delete-all-images escape (tmux
      passthrough-wrapped) once before the first render — clears
      fossils inherited from crashed/pre-fix sessions at the one moment
      it cannot hit our own placements. Config escape hatch to disable.
      (`image.sweep_terminal`; flag `images.tmux_sweep_on_attach`,
      default on. Escape sequences verified byte-for-byte in review.)
- [x] `:MarimoImageRepaint` command: delete-all escape + close registry
      placements + re-render outputs — one-keystroke recovery when a
      passthrough delete gets eaten mid-session. (Warns instead of
      claiming success when no image backend is installed.)
- [x] Tests for the pure parts (escape-sequence construction tmux vs
      bare, sweep gating, wipeout closes placements); terminal pixels
      can't be asserted headless — say so in the spec comments.
      (`image_sweep_spec.lua`, 7 cases; 196 passing.)

---

## Phase F3 — Cell-boundary anchor redesign (phase-sized, architectural) **DONE**

### F3.1 Single start-only anchor cannot disambiguate boundary inserts **[confirmed — root cause of Enter + Shift-O bugs]** **DONE**

`buffer.lua:9-21`. Verified with isolated probes, both gravity settings:

- `right_gravity = true` (current): a mark at `(row, 0)` on an empty line
  **follows text typed at that position** char-by-char, and `<CR>` pushes
  it onto the new row. Everything typed on a fresh cell's first line
  before the first Enter lands in the **previous** cell (TOCHANGE
  "pressing Enter goes to new cell" — reproduced exactly). `O` on a
  cell's first line donates the opened line to the cell above (TOCHANGE
  Shift-O bug — reproduced).
- `right_gravity = false` fixes both but breaks the case the current
  setting was chosen for: `o` at the end of the previous cell stops
  growing that cell and donates the line to the next.

It's a strict trade because `cell.end_row` is *derived* as
`next.start_row - 1` — "end of A" and "start of B" are the same byte
position, so no single gravity choice can serve both intents. This will
keep resurfacing with every boundary-adjacent whole-line replace
(comment plugins, snippets, LSP text edits, autopairs) — it is the
highest-leverage fix in this plan and should land **before any further
editing features**.

- [x] Design + implement a genuine second anchor per cell: a trailing
      anchor at the cell's last line end with `right_gravity = true`,
      and flip the start anchor to `right_gravity = false`. "Append after
      A" and "insert before B" become distinct positions; the ambiguity
      is eliminated rather than re-aimed. (Landed as ONE range extmark
      per cell — `right_gravity = false` start, `end_right_gravity =
      true` end — nvim clamps end ≥ start, so the inversion class is
      gone by construction. One residual: `o` on a cell's last line is
      byte-identical to `O` on the next cell's first line, so no gravity
      scheme can split them; a buffer-local `o` map rewrites the
      boundary case as `A<CR>` — same precedent as smart paste.)
- [x] `sync_cells_from_extmarks` reads both anchors; keep prune as the
      defensive sweep for collapsed cells; audit `push_undo_trash` /
      `try_undo_restore` and the smart-paste re-anchor (`61cc648`
      rationale comment) for assumptions about start-only anchoring.
      (3-pass resolver: read range geometry → zero-width-last sort →
      forward-clamp + anchor re-normalization; whole-line replaces pull
      the next cell's start back, healed by the clamp. Smart paste
      gained a linewise-`p`-at-boundary branch for the same reason.)
- [x] Regression tests (all currently missing from `editing_spec.lua`):
      (a) feedkeys-driven: type two lines with an `<CR>` into a fresh
      `<leader>mn` cell starting at col 0 → both land in the new cell;
      (b) `O` on a cell's first/only line → opened line belongs to that
      cell; (c) `o` at the end of the previous cell → line grows the
      previous cell (the case the old gravity protected);
      (d) the full 7.5.x suite stays green. (Plus: gcc-shape whole-line
      replace at a boundary, linewise `p` on a cell's last row, and a
      partial-dead-anchor survivor case from review. 187 passing.)
- [x] This is the one item that should NOT go straight to an implementer
      subagent without a design pass — run it through the Plan agent or a
      dedicated session first; it touches the invariant every editing
      path relies on. (Done: Plan-agent design pass with headless-nvim
      probes → implementer → lua-reviewer → review fixes.)

---

## Phase F4 — Extension-API hardening (before v0.1.0 freezes it) **DONE**

### F4.1 Error containment for renderers and detectors **[confirmed]** **DONE**

Only `register_ws_handler` contains errors (`ws_handlers.lua:45-60`,
pcall + once-per-op warn — the gold standard). Elsewhere:

- A throwing output renderer (`output.lua:294-316`, no pcall anywhere in
  the file) propagates into the `cell-op` handler, whose dispatch pcall
  then suppresses **all** further rendering with a misattributed "WS
  handler failed" warning. Worse: `M.render` clears `ns_output`
  *before* building new virt_lines (`output.lua:465-468`), so a throw
  mid-build leaves the cell silently blank.
- A throwing widget renderer: raw call at `widgets.lua:505`.
- A throwing detector predicate: raw call at `cell.lua:29` → breaks
  `cell.new` during parse → **attach fails entirely**.
- [x] pcall-wrap all three with the ws_handlers once-per-key warn
      pattern; failed output renderers emit a visible placeholder line
      (e.g. `✖ renderer error: <mime>`) + `log.write`, never a blank.
      Wrap `tree_render.render_node` dispatch too. (`safe_render` in
      output.lua; widgets/detectors/tree_render mirror it with
      `_*_errors` introspection tables like `ws_handlers._handler_errors`.
      Review follow-up: `_render_ctx.image_drawn` is now set only AFTER
      a successful `image.render_*` — set-before-call meant a thrown
      image renderer skipped the stale-placement cleanup; same fix in
      tree_render's img/svg helpers, plus `object_id`/`tab` reset
      per-render.)
- [x] Tests: register a throwing renderer for a fake mime → render pass
      survives, placeholder appears, next cell renders fine. (Plus
      throwing detector falls through to later-priority detectors, and
      a stubbed throwing `image.render_base64` proves the cleanup
      ordering. 205 passing.)

### F4.2 `register_cell_detector` signature + missing example **DONE**

Only registry that's fn-first (`(predicate, type_name, priority)` vs
key-first everywhere else); `priority` is undocumented in
`architecture.md:145` and `README.md:300`; no worked example (the other
three have one). `init.lua:459` says "These three registries" above four.

- [x] Normalize to key-first `(type_name, predicate, priority)` (now is
      the only cheap time) or explicitly document fn-first + priority;
      add the worked example; fix the "three" comment. (Key-first,
      priority optional/default 50; worked example + append-not-replace
      caveat in architecture.md; README/vimdoc snippets updated.)

### F4.3 Public renderers can't reach the render context **[confirmed]** **DONE**

`output.lua:44-51` documents `fn(data, opts)` but every call site passes
`opts = {}`; built-ins reach bufnr/cell_id/row via the private
`_render_ctx` upvalue. A third-party renderer cannot draw an image or
register a widget — the two things a Phase 9/10 extension would want.

- [x] Populate `opts` with `{ bufnr, cell_id, row, filepath }` before the
      contract freezes. Document the `tree_render` ctx fields
      (`tree_render.lua:16-26`) as the internal contract they already are.
      (`current_opts()` built from `_render_ctx`, passed at both dispatch
      sites; `image_drawn`/`skip_cap` explicitly excluded from the public
      contract.)

### F4.4 Declare the rest of the public surface **DONE**

- [x] Registry storage consistency: `output.M.renderers`,
      `ws_handlers.M.handlers`, `cell.M.detectors` are public mutable
      tables; `widgets` keeps `RENDERERS` local. Pick one (local +
      accessor is safest to freeze). (All four now local; the one write
      path is `register_*(key, fn)`, and `register_*(key, nil)`
      deregisters — consistent across registries, no separate
      unregister fns.)
- [x] Mark `init.current_notebook` / `attached_for` as public (statusline
      + blink integrations already depend on them); triage the 23 user
      commands into stable vs debug-unstable (`MarimoKillAll`,
      `MarimoWsPing`, `MarimoInspectOutput`, `MarimoWsDebug`) in
      README/vimdoc. (Actual count is 24; triaged 19 daily-drive vs 5
      debug-unstable — the four named plus `MarimoCheck`. README +
      vimdoc gained a Public Lua API section. Found while triaging:
      vimdoc falsely called `MarimoOpen` an alias of `MarimoEdit` — it
      actually spawns a raw untracked `marimo edit`; description fixed,
      but whether the command should exist at all is a maintainer
      decision, see Deferred.)
- [x] `plugin/neo-marimo.lua:27` reads `marimo._suppress_attach` —
      rename to a non-underscore name or document the exception to the
      `_`-private rule. (Renamed to `suppress_attach`, documented.)
- [x] Decide `html.lua`'s status: bless a minimal helper subset for
      custom renderers or state it's internal-only. (Internal-only;
      header comment states no compatibility promise.)

---

## Phase F5 — Consistency & observability **DONE**

### F5.1 Converge on `utils.warn/error/info` **DONE**

~78 direct `vim.notify("[neo-marimo] …")` sites (server.lua ×12,
widget_picker ×11, plugin/neo-marimo.lua ×35, …) vs ~41 through utils.
Every new call site copies whichever idiom it lands next to.

- [x] DONE Sweep to utils helpers; fix the `utils.info` docstring lie
      (utils.lua:68 claims debug-gated; implementation is unconditional —
      either gate it or fix the doc). (Doc fixed, behavior kept
      unconditional — INFO sites like "Connected (nvim-only)" are
      deliberate user feedback; gating them would be a behavior change.
      ~78 sites converted across 12 files; post-sweep grep shows
      `vim.notify` only inside utils.lua itself. No leftovers — every
      site used a WARN/ERROR/INFO level with no extra opts.)

### F5.2 `server.lua` never writes to the debug log **[gap]** **DONE**

`log.lua` is used by image/output/ws_handlers only. The async transport —
where the R3.3 issue template will tell reporters to look — logs nothing
to `:MarimoWsDebug`. Add `log.write` at: WS connect/disconnect/exit
(with code), slot handoffs (main↔kiosk), resync dispatches, HTTP non-200s.
(Done: tags `ws:connect` (spawn + established), `ws:exit` (code +
expected/unexpected), `ws:handoff` (release / reconnect_kiosk / skip),
`resync:dispatch`, `http:non200` (method/path/status, no bodies). Purely
additive — no control-flow or timing changes. `http_get` untouched: its
`curl -sf` never surfaces a status code without changing flags.
`resync:dispatch` has a spec via the exported `resync_ws` seam; the other
sites sit behind real process spawns / deferred timers and are untested,
stated per plan.)

### F5.3 Config fallback literals **DONE**

`or "python3"` ×4, `or 2718` ×4, `or "marimo"` ×3 re-encode
`config.defaults` at call sites and will diverge the first time a default
changes; `server.lua:324/860/920` index `config.options.server.port`
unguarded while `init.lua:224` guards. Add a `config.get(path)` (or rely
on defaults always being merged) and delete the scattered literals.
Coordinate with **R0.1** — do this in the same sitting as the default-path
restore so there's one authoritative defaults story.
(Done: `config.get(path)` dot-path accessor — walks options, falls back
to defaults per-path, and distinguishes an explicit user `false` from
"not set" (spec-covered). Confirmed real bug: `M.options` is `{}` until
`setup()` runs, so the unguarded nested indexes could error pre-setup.
All listed literals converted; parser.lua keeps its arg-defaults as a
documented last-resort net (module is deliberately config-free), callers
now pass `config.get("python_path")`. New `tests/spec/config_spec.lua`.
**R0.1 remains open in plan-release.md** — with get() in place the
default-path restore is now a two-line value change in config.defaults.)

### F5.4 Unbounded `nb._unknown_cell_ids` + handoff magic delay (small) **DONE**

- [x] DONE `output.lua:612-625`: prune `_unknown_cell_ids` (e.g. clear on
      successful rekey); once marked, an ID never re-triggers resync.
      (Cleared on all three success paths of `rekey_cells_from_server` —
      same condition that stamps `_last_cell_ids_at`, so the F1.2 bail
      path correctly leaves it intact; both directions spec-covered in
      `ws_dispatch_spec.lua`. `reload_from_file` mutates the same `nb`
      in place but its ws-handler call site is inside a success path, so
      the clear there covers it.)
- [x] DONE `server.lua:892-914`: the fixed 1200ms browser-handoff delay is
      timing-dependent on slow machines; at minimum add a rationale
      comment + config escape hatch. Not worth adaptive backoff now.
      (`server.browser_handoff_delay_ms = 1200` in config.defaults;
      header comment extended. Also converted the same function's
      unguarded `share_with_browser` read to `config.get`, `~= false`
      semantics preserved.)

---

## Phase F6 — Docs & coverage backfill **DONE**

### F6.1 Docs-drift batch (one commit) **DONE**

- [x] DONE `init.lua:459` "three registries" → four. Already fixed by
      F4.2 (now at `init.lua:505`, reads "These four registries") — no
      edit needed, confirmed only.
- [x] DONE `architecture.md:145` + `README.md:300`: detector `priority` +
      worked example. Already present and correct from F4.2 (key-first
      `(type_name, predicate, priority)`, priority optional/default 50,
      worked example) — no edit needed there. Found and fixed one nearby
      staleness while verifying: README's "Extending" intro claimed
      *every* registry "replaces the built-in" with no exception, which
      contradicts `register_cell_detector`'s actual append-to-chain
      behavior (`cell.lua:27-40`, confirmed by reading the code) and
      contradicts architecture.md's own text a few paragraphs later.
      Fixed the README summary line to state the exception.
- [x] DONE `architecture.md:76`: added the `reload` op (0.23+) to the ws
      built-ins list; `architecture.md:100-101`: added `log.lua` to the
      module map (Support row).
- [x] DONE Killed the "8-layer architecture" phrase in CLAUDE.md and
      plan-release.md — architecture.md's module map has six groupings
      (entry/lifecycle, notebook model, kernel connection, output
      rendering, LSP, support); reworded both references to point at the
      module map instead of restating a layer count that will drift
      again. CLAUDE.md's "12 spec files" also reworded to avoid a
      brittle literal count (actual count at time of writing: 14 —
      `config_spec.lua` and `image_sweep_spec.lua` were added since this
      plan's 2026-07-01 count of 11, and it'll keep moving).
- [x] DONE Confirmed the README 0.19-only claim (`README.md:48, 359-360`)
      vs `health.lua`'s `TESTED_MARIMO_SERIES = { ["0.19"] = true,
      ["0.23"] = true }` — discrepancy still exists exactly as R4.4
      describes it. Left untouched here; belongs to R4.4 in
      plan-release.md.
- [x] DONE Added a "Sanctioned dependency cycles" paragraph to
      architecture.md documenting the `buffer.lua ↔ notebook.lua` lazy
      edge (`notebook.lua`'s `try_undo_restore`, line drifted from 225 to
      ~323 since this plan was written — F1.1's undo-restore rewrite
      moved it) and the "leaf modules (`blink.lua`, `lsp.lua`) lazily
      require the root `init` module for `current_notebook`" pattern.

### F6.2 `lsp.lua` pure-function specs **DONE**

Largest wholly-uncovered module (728 lines); position mapping
(`notebook_to_shadow_pos` / `shadow_to_notebook_pos`) and the
return-rewrite are pure and need no server. Every future LSP change
currently ships blind.
(Done: new `tests/spec/lsp_spec.lua`, 14 cases. Part 1 is pure math on
the mapping pair — offsets, before-first/past-last rows, the defensive
inter-cell-gap branch, negative-col clamp, round-trip loop. Part 2 goes
through the public `lsp.refresh_shadow(nb)` so the real
`build_shadow_text`/`transform_returns` machinery is exercised: marker
lines, `return X` → `_RET = X` rewrite (indented returns untouched),
marker/separator shadow rows resolve to nil, full notebook↔shadow
round-trip on a 3-cell notebook. One minimal seam: local
`shadow_to_notebook_pos` promoted to `M.shadow_to_notebook_pos`,
mirroring the pattern `notebook_to_shadow_pos` already used; no
behavior change.)

### F6.3 Remaining coverage gaps from the reviews **DONE**

- [x] DONE `render_error` (`output.lua:103-116`, drifted to ~192-211):
      4 new cases in `output_spec.lua` (array payload, bare-string
      entry, non-table payload, non-array table). Code fix included: a
      dict-shaped/empty table payload made `ipairs` walk zero
      iterations → silently blank cell; now emits a fallback
      `✖ Error (unrecognized payload)` line, with rationale comment.
- [x] DONE `image.lua` pure helpers — already public `M.*` fns, no seam
      needed; new `tests/spec/image_helpers_spec.lua` covers
      match/no-match/nil for `extract_data_uri`, `extract_inline_svg`,
      `extract_virtual_file` (+ `has_embedded_image`).
- [x] DONE `wrap_spec.lua`: documentation case proving `wrap_virt_line`
      operates one kernel-split line at a time and never rejoins
      (numpy `linewidth=75` reprs stay narrow even when the window
      would fit more) — documents current behavior only, per the
      Deferred note; no fix.
- [x] DONE Run-POST test in `ws_dispatch_spec.lua`: drives
      `actions.run_cell_at_cursor` with stubbed
      `sync.write_to_file`/`server.is_running`/`server.run_cells`,
      schedules a bailed `update-cell-ids` (count mismatch +
      `is_writing`) then a successful positional rekey inside
      `flush_pending_edits`'s wait window, asserts the POSTed id is the
      server id, not the stale local one. Reviewer ran it 5× in
      isolation — not flaky (1500ms wait budget vs 10/50ms defers).

Phase verified: full suite 245 passed / 0 failed; lua-reviewer pass on
the F6 diff came back clean (all docs claims checked against source).

---

## Deferred / decisions for the maintainer

- **`:MarimoOpen` (found during F4.4 docs triage, 2026-07-09)** — spawns
  a raw detached `jobstart({marimo_cmd, "edit", filepath})` that
  bypasses the managed-server registry and WS handoff entirely; it can
  mint an untracked second `marimo edit` process for a notebook that
  already has a managed server. The vimdoc used to (falsely) call it an
  alias of `MarimoEdit` — now documented accurately, but consider
  removing or reimplementing it on top of `server.start_and_open`
  before v0.1.0.
- **Numpy/DataFrame width (TOCHANGE "not as wide as could be")** — NOT a
  plugin bug: the kernel's `repr` embeds line breaks at numpy's default
  `linewidth=75`; nvim can wrap further but never rejoin. Options:
  (a) document the limitation; (b) feature: push a window-width
  `np.set_printoptions(linewidth=…)` hint into the kernel. (b) is a
  feature → post-release. Minor related note: `output_text_width`
  (`output.lua:430-438`) uses `win_findbuf(bufnr)[1]` — first window
  wins; wrong width with two splits of the same buffer.
- **nvim→browser widget glyph** — upstream marimo limitation, already
  documented in TOCHANGE; no action.
- **Stale plot "ghosts" under tmux (2026-07-03)** — NOT a plugin
  registry bug: after F2.6, the debug log shows a single placement per
  cell with clean closes, yet a fossilized first render can stay
  onscreen when nvim runs inside tmux (`allow-passthrough on`) —
  kitty-graphics images are painted by the terminal at absolute screen
  pixels, tmux redraws text only, and deletes/repositions for scrolled
  placements don't reliably land. Reproduces with snacks.image +
  Ghostty + tmux; **confirmed clean outside tmux (2026-07-04): the
  same notebook/widget flow shows no ghosts when nvim runs directly in
  Ghostty** — the bug is strictly tmux-passthrough-related, **and F2.7
  (below) fixes it for the tmux case too**: exit/wipeout cleanup plus a
  once-per-session attach sweep clear inherited fossils automatically.
- **Image placement drift (rendering B4)** — depends on image.nvim /
  snacks internals; re-test after F2.1 lands, likely resolved by it.
- **`server.lua` split** (process/http/ws) — stays deferred per
  plan-release Appendix A.
- **TOCHANGE "Bad markdown rendering / output came later than supposed"**
  — no repro notebook survives; F2.1 (stale output anchors) is the most
  plausible culprit; re-observe after F2 lands before investigating.

## Suggested execution order & sizing

| Phase | Items | Size | Agent routing | Status |
| --- | --- | --- | --- | --- |
| F1 | 1.1–1.5 | ~1 session | implementer per item; 1.4 touches Lua+Python | DONE |
| F2 | 2.1–2.7 | ~1 session | implementer; 2.1 first, 2.5 is inline-trivial, 2.6/2.7 found post-F3 | DONE |
| F3 | 3.1 | 1–2 sessions | Plan agent design pass first, then implementer | DONE |
| F4 | 4.1–4.4 | ~1 session | implementer; 4.4 partly docs-writer | DONE |
| F5 | 5.1–5.4 | ~half session | implementer (5.1 is mechanical) | DONE |
| F6 | 6.1–6.3 | ~1 session | docs-writer (6.1), implementer (6.2–6.3) | DONE |

After F6, resume `plan-release.md` at R0 with a much stronger "what
exists works flawlessly" baseline — F1/F2 close every reproducible
TOCHANGE bug, F3 closes the class the editing bugs came from, and F4
means v0.1.0 freezes an API that can actually be extended.

---

## Post-execution reconciliation (2026-07-21)

The four review agents were re-run to completion after a session
interruption and their final reports cross-checked against the executed
F1–F6 plan. Result: **every confirmed bug and architecture finding maps
to a shipped F-item** — with three small exceptions that never made it
into the plan. Captured here as **F7** so they aren't lost; each is a
single implementer-subagent task.

### F7.1 Silent drop of undecodable WS stdout lines (small) **DONE**

`server.lua` `dispatch_line`: `if err or not msg then return end` — a
line that fails `json_decode` (e.g. a stray `\r` making a CRLF-shaped
line, or any future framing bug) drops a whole WS message with **zero
diagnostic**. F5.2 added `log.write` to connect/exit/handoff/resync/
http-non-200 but not here.

- [x] DONE Added the drop-log with length + error only (never the body — the
      line can be multi-megabyte per the chunked-stdout comment). Extracted
      the decode+log into a module-level `M._decode_ws_line` seam that
      `dispatch_line` calls, so the drop branch is directly assertable
      without spawning a real ws_client job (same seam pattern as F5.2's
      `resync_ws`).
- [x] DONE `server_spec.lua` cases: (a) stream ends mid-fragment with no
      trailing newline → partial stays buffered, never emitted; (b) verified
      `vim.json.decode` already tolerates a trailing `\r` as insignificant
      whitespace and asserted the tolerated line fires NO drop-log; (c)
      drives `M._decode_ws_line` on a genuinely malformed line with
      `log.write` stubbed, asserting exactly one `ws:drop-undecodable` entry
      with `len`+`err` and — explicitly — no field carrying the raw body.
      (lua-reviewer flagged the original tests only exercised the
      precondition; this seam closes that gap.)

### F7.2 `bridge_spec.lua`: decorator-with-args round-trip (small) **DONE**

F1.4 added the `async def` round-trip; a cell whose decorator carries
args (e.g. `@app.cell(hide_code=True)`) still has no round-trip case
covering `# id:` injection/extraction adjacency.

- [x] DONE Added `"bridge: decorator-with-args cell round-trips code,
      options, and id"` to `bridge_spec.lua`: asserts `@app.cell(hide_code=True)`
      survives `generate_py`, the injected `# id:` lands immediately before
      the decorated (non-bare) line, code/id round-trip through `parse_file`,
      and `options.hide_code` survives. Executed against marimo 0.19.4 (not
      skipped).

### F7.3 Watch-list additions (no action, record only)

From the transport review, judged not worth acting on now:

- `http_post_raw` status-line parse (`stdout:match("^(.*)\n(%d+)%s*$")`)
  could misparse a response body ending in a digits-only line;
  marimo's JSON responses make this near-impossible.
- `SAVE_SUPPRESS_MS = 1500` vs marimo's ~1s polling fallback — under
  heavy load a late echo could slip past the suppression window and
  round-trip a stale reload. Needs a slow-fs repro before touching.

### Working-tree note (2026-07-21)

An uncommitted follow-up to F2.1 sits in the working tree (8 files,
+358/−65, suite green at 249/249): the border/output gravity assignment
is **inverted** (border `right_gravity = false`, output `true`) so output
renders **below the cell's box** instead of inside it — the TOCHANGE
"run text and output should go below the cell" item — with by-id output
mark cleanup (`cell._output_mark_id`) replacing row-range clears in
`output.render`, `delete_cell_at_cursor`, and the output-toggle keymap,
plus `parser.lua` nil-guards for empty bridge output. Specs updated to
the inverted contract (ride-then-heal is the documented trade-off).
Needs a commit once the maintainer signs off on the diff.
