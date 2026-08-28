# Plan: Reconcile neo-marimo with marimo 0.23.9

## Context

`marimo` was just upgraded via pip from **0.19.4 → 0.23.9** in the global pyenv
env (`3.12.10`), which is what `marimo` on `$PATH` now resolves to — so the
plugin's real runtime now hits 0.23.9. The test env `MyMainTestingPython` is
still pinned at 0.19.4, so the test suite and the committed fixtures
(`tests/fixtures/0.19/`) no longer reflect what users actually run.

I empirically diffed both installed versions (HTML output, WS message enum,
HTTP routes, CLI flags). Almost everything is stable. **One real regression**
exists: marimo removed the `update-cell-codes` and `update-cell-ids` WebSocket
notifications and replaced them with a single, payload-less `reload`
notification emitted by the `--watch` file-change handler. The plugin has no
`reload` handler, which breaks the run-after-save flow and external-edit sync.

Decisions (confirmed with user): **support both 0.19.x and 0.23.x**; scope is
**protocol fix + fixture regeneration + health update**.

### What is NOT broken (verified, no work needed)
- Server launch: `--headless --no-token --watch --port` all still exist.
- HTTP API: `/api/kernel/{run,instantiate,interrupt,set_ui_element_value}` all
  present under the `/api/kernel` prefix; `Marimo-Session-Id` /
  `Marimo-Server-Token` headers unchanged.
- WS ops `cell-op`, `kernel-ready` (still carries `cell_ids`), `completed-run`
  unchanged.
- HTML/widget parsing: the only change is `&lt;`/`&gt;` → `<`/`>`
  inside JSON attribute values. `html.lua`'s decode chain already handles this
  (`decode_entities` turns `&#92;`→`\`, then `vim.json.decode` resolves
  `<`). New additive attrs (`data-disabled`, `data-orientation`) are inert.

## The regression in detail

- `flush_pending_edits` (`lua/neo-marimo/actions.lua:46`) blocks up to **1.5s**
  on `nb._last_cell_ids_at >= nb._last_save_at`. `_last_cell_ids_at` is stamped
  **only** by the `update-cell-ids` handler (`ws_handlers.lua:105`). On 0.23.9
  that op never arrives → every run waits the full 1.5s, then POSTs `/run`
  with locally-minted IDs.
- `update-cell-codes` (`ws_handlers.lua:130`) drove `sync.apply_remote_changes`
  for browser/`--watch` edits. Gone on 0.23.9 → external edits stop syncing
  into the buffer.
- 0.23.9 `ReloadNotification` carries **no payload** ("Instructs frontend to
  reload the page"); re-keying from it is impossible, but 0.23 is
  client-ID-authoritative (`/run` registers unseen cell IDs), so the plugin's
  existing IDs are valid and only a re-sync/unblock is needed.

## Changes

### 1. Add a `reload` WS handler — `lua/neo-marimo/ws_handlers.lua`

Register a new handler alongside (not replacing) the existing
`update-cell-ids` / `update-cell-codes` handlers so the plugin keeps working on
0.19.x:

```lua
M.register("reload", function(_, ctx)
  if not ctx.nb then return end
  -- Unblock actions.flush_pending_edits: on 0.23 no update-cell-ids will
  -- arrive, so stamp the moment the reload lands instead.
  ctx.nb._last_cell_ids_at = (vim.uv.hrtime() / 1e6)
  -- External/browser/--watch edit: re-sync from disk. Skip inside our own
  -- write-suppression window so a save we triggered doesn't clobber edits
  -- the user typed between :w and the echo.
  local sync = require("neo-marimo.sync")
  if not sync.is_writing(ctx.nb) then
    sync.reload_from_file(ctx.nb)
  end
end)
```

- Reuses `sync.reload_from_file` (`lua/neo-marimo/sync.lua:232`) and
  `sync.is_writing` (`lua/neo-marimo/sync.lua:72`) — same primitives the old
  `update-cell-codes` handler used.
- Idempotent and safe on 0.19.x: stamping a timestamp is harmless, and the
  `is_writing` guard + `apply_remote_changes` minimal-diff inside
  `reload_from_file` make a redundant resync a no-op.
- Update the handler-roster comment block at the top of the file
  (`ws_handlers.lua:5-7`) to mention the `reload` op.

### 2. Regenerate fixtures for 0.23 — `tests/fixtures/0.23/`

`tests/capture_fixtures.py` already version-stamps its output dir from
`mo.__version__` and skips cases whose optional libs are missing. The 0.23.9
env currently lacks `pandas`/`altair`/`plotly`, so a bare run would drop ~12
table/chart fixtures. Install those into a 0.23.9 env first, then capture:

```sh
# into the env whose `marimo` is 0.23.9 (global 3.12.10 here)
~/.pyenv/versions/3.12.10/bin/pip install pandas altair plotly
~/.pyenv/versions/3.12.10/bin/python tests/capture_fixtures.py
```

This writes `tests/fixtures/0.23/*.html`. Commit them. `helpers.lua:54-58`
auto-selects the highest available fixture version, so the Lua render tests
will run against 0.23 once the dir exists — no test-code change needed. Keep
`tests/fixtures/0.19/` so the older series stays represented.

### 3. Mark 0.23 as tested — `lua/neo-marimo/health.lua:9`

```lua
local TESTED_MARIMO_SERIES = { ["0.19"] = true, ["0.23"] = true }
```

Stops the spurious "untested marimo version" warning in
`:checkhealth neo-marimo`.

## Verification

1. **Render tests** against the new fixtures:
   `make test` (or the project's busted runner). Confirm `render_spec.lua` and
   the widget/dataframe/markdown specs pass with `tests/fixtures/0.23/`
   selected. The decode chain is unchanged, so the stripped-label output should
   match — any failure points at a genuine 0.23 shape change to investigate.
2. **WS dispatch test** for the new op: add/extend a case in
   `tests/spec/ws_dispatch_spec.lua` asserting a `reload` message stamps
   `_last_cell_ids_at` and (when not writing) invokes the resync path.
3. **End-to-end against live 0.23.9** (manual, with `marimo` = 0.23.9 on PATH):
   - Open a notebook, edit a cell, run it (`<leader>mr`). Confirm the run is
     near-instant (no ~1.5s stall) and output renders.
   - Add a new cell (`<leader>mn`), run-all (`<leader>mR`); confirm no
     duplicate/shadow cells and output appears.
   - Edit the file in a browser tab (or external editor) and confirm the change
     syncs back into the nvim buffer (exercises the `reload` → `reload_from_file`
     path).
4. **Regression check on 0.19.x**: run the same e2e using the
   `MyMainTestingPython` (0.19.4) `marimo` to confirm the added `reload`
   handler didn't disturb the still-present `update-cell-ids`/`update-cell-codes`
   path.

## Notes / follow-ups (out of scope)
- 0.23.9 adds `POST /api/kernel/restart_session`; `restart_kernel`
  (`actions.lua:329`) currently recycles the whole server process. Switching to
  the endpoint is a future enhancement, not part of this fix.
- Per memory: plugin changes take effect for the installed copy only after
  pushing to GitHub (dev repo vs `vim.pack` install path). Test via the
  dev-link workflow before release.
