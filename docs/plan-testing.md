# plan-testing.md — automated testing pipeline (phases T0–T6)

Goal: make the whole test story runnable with **one command**, and make every
manual verification either (a) automated as a replayed session + snapshot, or
(b) reproducible with one keystroke. This attacks the real cause of the
project stall: manual testing is slow, tedious, and unrepeatable.

## How to read this plan

**This is a route, not doctrine.** Each phase states a goal, a suggested
build, and acceptance criteria. The *goal and acceptance criteria are the
contract*; the build steps are the current best guess. If the suggested
approach hits a serious wall (an nvim API behaves differently headless, a
marimo message turns out to be unrecordable, timing can't be made
deterministic), the implementer should pick a different route to the same
acceptance criteria and leave a short note in this file under the phase
("Deviation: …") explaining what changed and why.

Rules that always apply (from CLAUDE.md):

- Pre-release: this is **test infrastructure, not features** — allowed.
- Never strip "why" comments; add rationale for non-obvious fixes.
- Match style: 2-space indent, existing naming, specs register via
  `t.case(name, fn)` in `tests/spec/*_spec.lua`.
- Marimo-dependent work is gated on `NEO_MARIMO_TEST_PYTHON` and must
  **self-skip** cleanly when marimo is absent (see `bridge_spec.lua` for the
  pattern), so `make test` stays green on any machine.

Phase order matters for T0→T2 (each builds on the last). T3–T7 are
independent of each other and can go to separate implementer agents in
parallel once T2 lands.

Key seams (verified against the code, 2026-08):

- WS messages arrive as JSON lines on `ws_client.py` stdout, reassembled by
  `server._reassemble_stdout`, decoded by `server._decode_ws_line`, and
  dispatched at `init.lua:165` via `ws_handlers.dispatch(op, payload, ctx)`.
  **Recording = capturing those JSON lines; replaying = feeding them back
  through `_decode_ws_line` + `dispatch`.** No kernel needed to replay.
- `tests/helpers.lua` already provides `make_notebook(codes)` (real buffer,
  real change tracking, no python/server) and `flat_lines`/`joined` for
  virt_lines. The replay layer composes these; it should not rebuild them.
- Fixture versioning precedent: `tests/fixtures/<marimo major.minor>/`,
  captured by `tests/capture_fixtures.py`. Transcripts follow the same shape.

---

## T0 — Snapshot engine + render-state serializer

**Goal:** writing a new render assertion becomes nearly free: serialize the
full observable state, diff against a checked-in golden, regenerate goldens
with one env var. This is the foundation every later phase asserts through.

**Build:**

1. `tests/helpers.lua` gains a snapshot API:
   - `t.snapshot(name, text)` — compares `text` against
     `tests/snapshots/<name>.txt`.
     - Missing golden + `NEO_MARIMO_UPDATE_SNAPSHOTS=1` → write it, pass.
     - Missing golden without the env var → fail with "run `make snapshots`".
     - Mismatch → fail with a unified diff (small; `vim.diff()` exists in
       0.11 and produces one) **and** write the actual output to
       `tests/snapshots/<name>.actual.txt` so the user can inspect/diff with
       any tool. `.actual.txt` files are gitignored.
     - `NEO_MARIMO_UPDATE_SNAPSHOTS=1` on mismatch → overwrite golden, pass,
       print "updated".
2. A render-state serializer, `t.render_state(bufnr)` → one stable string
   containing, in order: buffer lines; then per-namespace extmarks
   (`nvim_buf_get_extmarks` with `details = true`) showing row/col, virt_text,
   and virt_lines flattened through the existing `H.flat_lines`. Highlight
   group names included (they're part of what the user sees); byte offsets of
   volatile things excluded.
3. A **scrub pass** inside the serializer for values that vary run-to-run:
   cell ids (map to `<cell-1>`, `<cell-2>`… in first-seen order), tmp paths,
   port numbers, durations/timestamps. Centralize the scrub rules in one
   table in helpers.lua so future volatile values get one-line fixes.
4. Makefile: `make snapshots` = `NEO_MARIMO_UPDATE_SNAPSHOTS=1 make test`.
   `.gitignore` gets `tests/snapshots/*.actual.txt`.
5. Prove it by converting **two or three** existing assertion-heavy cases in
   `output_spec.lua` or `render_spec.lua` to snapshots. Do not mass-convert
   the suite — hand-written assertions that already exist and pass are fine;
   snapshots are for new tests and for cases where the assertions were
   painful to write.

**Acceptance:**

- `make test` green with no env vars, on a machine without marimo.
- Deleting a golden and running `make snapshots` regenerates it identically
  (determinism check — run twice, `git diff` clean).
- A deliberately broken render (edit a spec input) fails with a readable diff
  and leaves an `.actual.txt`.

---

## T1 — WS session recorder + scenario corpus

**Goal:** capture real kernel behavior once, as committed, versioned,
deterministic transcripts — the raw material T2 replays. After this phase,
"what does marimo actually send when X happens" is a file you can read, not a
session you have to reproduce.

**Build:**

1. `tests/scenarios/` — small, committed marimo notebooks, one per scenario.
   Start with roughly:
   - `basic_run.py` — two dependent cells, scalar outputs.
   - `widgets.py` — slider + dependent cell (exercises `variables` /
     `variable-values` / widget re-render).
   - `error_cell.py` — a cell that raises (error output path).
   - `rich_output.py` — dataframe + matplotlib/image output (exercises the
     large-message / chunked-stdout path — keep one output big enough to
     span stdout chunks, since that reassembly has bitten before).
   - `edit_rerun.py` — notebook whose scripted actions include a code change
     + save + re-run (exercises reload / update-cell-ids / re-key).
2. `tests/record_transcripts.py` (python, sibling of `capture_fixtures.py`):
   for each scenario, start a real marimo kernel the same way the plugin
   does, connect `python/ws_client.py`, drive a scripted action list (run
   cell N, set widget value, save modified code — via the same HTTP endpoints
   `server.lua` POSTs to), and record **every raw JSON line** from the WS
   client to `tests/transcripts/<marimo major.minor>/<scenario>.jsonl`.
   - Interleave action markers into the stream as comment lines
     (`{"__action__": "run-cell", ...}`) so a replay knows where user actions
     happened and a human can read the file.
   - Wait for quiescence (no messages for ~2s) between actions before
     recording the next, so transcripts don't depend on race timing.
3. A **normalization pass** on the recorded lines before writing: stable
   placeholder substitution for session ids, cell ids, ports, absolute paths,
   timestamps. Cell-id substitution must be *consistent within a transcript*
   (same real id → same placeholder everywhere) or replay re-keying breaks.
   Keep the substitution table in one place; T2's replayer reverses nothing —
   placeholders are just the ids the replay world uses.
4. Makefile: `make transcripts` (needs `NEO_MARIMO_TEST_PYTHON`, like
   `make fixtures`). Re-run + re-commit when bumping supported marimo.
5. Record against the current test python (marimo 0.19.4 per the Makefile
   default). If a 0.23 env is available, record that too; otherwise leave the
   `0.23/` directory for later — the layout supports it either way.

**Acceptance:**

- `make transcripts` produces `.jsonl` files that are **byte-identical across
  two consecutive runs** (this is the hard part; the normalization pass is
  what makes it true — iterate on scrub rules until it holds).
- Transcripts are human-readable: one JSON object per line, action markers
  visible, no megabyte-scale base64 blobs unscrubbed (big payloads may be
  truncated with a `"__truncated__"` marker *only if* T2 proves the renderer
  doesn't need the full body — otherwise keep them whole; correctness beats
  file size).
- Files are committed under `tests/transcripts/0.19/`.

**Known risk / permitted deviation:** if driving actions over HTTP from
python proves fragile, an alternative recorder is a thin Lua script run via
`nvim -l` that uses `server.lua` itself to start/connect and tees
`_decode_ws_line` input to a file. Either route satisfies the acceptance
criteria; pick whichever is less code.

**Deviation taken:** built `tests/record_transcripts.lua` (the permitted
`nvim -l` alternative) instead of a python HTTP driver. Reimplementing
marimo's start/health/token-fetch/instantiate/save/rekey choreography from
scratch in Python would have duplicated a lot of already-battle-tested logic
in `server.lua`, `sync.lua`, `actions.lua` and `ws_handlers.lua` (port
selection, skew-token fetch, the save→watch→update-cell-ids rekey dance,
widget object-id lookup). Driving those exact production code paths
directly was less code, and every recorded action is byte-for-byte what a
keymap press does — not a hand-rolled approximation of one. The recorder
wraps `server._decode_ws_line` (not `on_message`) so it sees the exact raw
line before anything mutates it, and calls `ws_handlers.dispatch` itself,
synchronously, right there — giving deterministic ordering against the
scripted action list instead of racing `connect_ws`'s own
`vim.schedule`-deferred forwarding.

Non-obvious things worth recording for whoever touches this next (T2, or a
future re-record):
- **`python_path` vs `marimo_cmd` are separate config knobs.** The recorder
  must derive `marimo_cmd` from `NEO_MARIMO_TEST_PYTHON`'s own directory
  (the sibling `marimo` binary) rather than trust `config.lua`'s default,
  which points at the maintainer's personal pyenv env. Using mismatched
  envs silently records a *different* marimo's output (caught this via a
  version-mismatched "Update available" alert and 0.23-only ops appearing
  in a "0.19" recording).
- **marimo's own cell ids are already deterministic**, not just scrubbed
  to be: `CellIdGenerator` (`_ast/cell_id.py`) seeds `random.Random(42)`, so
  the same notebook structure mints the same ids every process run. The
  `<cell-N>` substitution is still done (readability, and it's the one
  place T1 and T0 deliberately share placeholder spelling), but it isn't
  load-bearing for determinism the way it would be for a naively-random ID
  scheme.
- **`PYTHONHASHSEED` had to be pinned** (`vim.fn.setenv` before spawning,
  inherited by the `--headless` subprocess). marimo's static analysis walks
  `set`s of assigned/used names per cell; with the default randomized hash
  seed, a cell binding several names (`rich_output.py`'s matplotlib cell)
  broadcasts its `variables`/`variable-values` list in a different order
  every run. This was the single largest source of non-reproducibility
  found — worth checking first if a future scenario reintroduces flakiness.
- **The `alert` op (CLI update-nag) is dropped, not scrubbed.** It hits a
  real network endpoint and its content changes as new marimo versions
  ship, independent of anything this repo controls — recording it would
  make goldens flake on both network access and the passage of time.
- **Object reprs can embed memory addresses** (`<Figure object at
  0x...>` for anything without a custom `__repr__`) — scrubbed via a
  generic `0x%x+` pattern; unrelated to the hash-seed fix above (ASLR, not
  iteration order).
- **JSON key order needed to be forced for the recorder's own `__action__`
  markers** — `vim.json.encode` on a multi-key Lua table has no defined key
  order, so the *same* action produced differently-ordered JSON across
  runs. Built manually with `extra`'s keys sorted instead. (marimo's own
  message JSON was never affected by this — Python dict/dataclass
  serialization preserves insertion order regardless of hash seed; only
  `set`-backed list *contents*, per the PYTHONHASHSEED point above, needed
  a fix.)

Recording ran three consecutive times against marimo 0.19.4
(`MyMainTestingPython`); all five scenarios were byte-identical across all
three runs.

---

## T2 — Replay spec layer (the payoff)

**Goal:** every scenario transcript replays through the *real* dispatch and
render pipeline against a *real* buffer, headless, no kernel, in
milliseconds — and the final render state is snapshot-asserted. This is the
layer that replaces most manual testing.

**Build:**

1. `tests/helpers.lua` gains `t.replay(transcript_name, nb, bufnr, opts)`:
   - Read `tests/transcripts/<newest-version>/<name>.jsonl` (reuse the
     `fixture_dir`-style newest-version-wins lookup).
   - For each line: skip/handle `__action__` markers; otherwise feed the raw
     line through `server._decode_ws_line`, then
     `ws_handlers.dispatch(msg.op, msg.payload, ctx)` with the same ctx shape
     `init.lua:165` builds (`nb`, `bufnr`, …) — read that call site and match
     it, don't approximate it.
   - After each dispatch (or batch), drain scheduled callbacks:
     `vim.wait(0)` + a helper that pumps until `vim.uv` has no pending
     `defer_fn` work, capped by a timeout. Rendering paths that use
     `vim.schedule` must actually run before the snapshot.
   - `opts.until_action` lets a test replay up to the Nth action marker and
     assert intermediate state.
2. `tests/spec/replay_spec.lua`: one case per scenario —
   `t.make_notebook(...)` with the scenario's cell codes, `t.replay(...)`,
   then `t.snapshot("replay-<scenario>", t.render_state(bufnr))`. Where a
   scenario has meaningful intermediate states (edit_rerun), snapshot those
   too.
3. A **coverage guard** case: replay every committed transcript and assert no
   line hits the unknown-op path (`ws_handlers.dispatch` returning false for
   an op that appears in a transcript) and no handler-error warning fires.
   This catches "marimo added an op we silently drop" the moment transcripts
   are re-recorded.
4. Image rendering: kitty-graphics placement can't happen headless. The
   replay ctx should stub the terminal-emission edge of `image.lua` (the
   narrowest seam that actually writes escape codes) while keeping placement
   bookkeeping real, and the snapshot should include the *placement data*
   (which cell, which file/geometry) rather than pixels. Find the narrowest
   stub point; do not stub whole modules.

**Acceptance:**

- `make test` runs all replay cases green, headless, **without marimo
  installed**, in well under a second per scenario.
- Killing a real recent bug class proves the layer: pick one fixed bug from
  `ws_dispatch_spec.lua`'s history (e.g. the F2.6 registry-migration leak or
  the F1.2 stale-id run) and show the replay snapshot *would have caught it*
  (revert the fix locally, watch the snapshot diff, restore).
- A failing replay produces a snapshot diff a human can act on (names, not
  noise) — if the diff is unreadable, fix the serializer, not the test.

**Known risk / permitted deviation:** the async-drain helper is the likely
trouble spot (timers, debounces like the 300ms flush). If pumping the loop
generically is flaky, it is acceptable to expose a small test-only hook in
the plugin (like the existing `nb._flush_pending()` pattern) to flush
pending render work synchronously — precedent already exists in helpers.lua.

**Deviation taken:** the async-drain risk above didn't materialize — the only
`vim.schedule` in the replayed call chain is `output.lua`'s `handle_cell_op`
deferring its own `M.render` (verified: no debounce/timer sits between
`ws_handlers.dispatch` and a render for any op these transcripts exercise),
and a single `vim.wait(0)` reliably flushes an already-queued schedule
callback. `H.drain` still loops a few times under a wall-clock cap rather
than assuming exactly one pass is always enough, as cheap insurance against a
future handler adding a second level of scheduling — but the
`nb._flush_pending()`-style plugin hook was not needed.

Scenario cell codes are read from `tests/scenarios/*.py` via a small
purpose-built extractor (`H.scenario_codes` in tests/helpers.lua) rather than
via `python/bridge.py` or a hand-copied list — it only has to handle this
corpus's own 5 files (marimo's default 4-space indent, one flat body per
cell, ending in a bare `return`), and its output was checked byte-identical
against the committed transcripts' own `kernel-ready.codes` field.

Two ops present in every transcript had no registered handler at all:
`remove-ui-elements` (marimo's pre-rerun UI-teardown notice — already
subsumed by `output.render`'s own `widgets.clear_for_cell` /
`image.clear_for_cell` before it draws a cell's next output) and `datasets`
(table/column metadata feeding marimo's browser-only "Data Sources" panel,
which this plugin has no nvim-side equivalent of). Both are now registered
as explicit no-ops in `ws_handlers.lua`, with a comment explaining why —
this is exactly the class of finding the coverage guard exists to surface,
and leaving either unregistered would have made the guard fail on *every*
transcript rather than only on a genuinely new/unexpected op.

The image-rendering seam (build step 4) is `image.lua`'s `M._set_test_backend`:
a test-only override that makes `pick_backend()` return a fake `"test-stub"`
backend, so `render_path` runs its normal `register_placement`/
`migrate_keys`/`clear_for_cell` bookkeeping against a plain recorder function
instead of a real backend's draw call (image.nvim's `img:render()`, snacks'
`placement.new`) — neither of which is reachable from this headless test
env's `package.path` anyway. `t.render_state` grew an `== images ==` section
reading `image.lua`'s own placement registry (`M._placements_for_test`) so a
re-key that fails to migrate a placement's key shows up in the snapshot
directly, which is what the dedicated F2.6 regression case in
`replay_spec.lua` exercises.

Recording `rich_output.jsonl` (T1) turned out to have a real bug, found only
once T2 tried to actually decode and place its image: T1's `py_object_addr`
normalization rule (`0x%x+` → `<hex-addr>`, meant for a bare Python object
repr like `<Figure object at 0x7f...>`) was unanchored, and a ~220KB base64
PNG is long enough that the literal substring "0x" followed by hex-looking
base64 digits occurs by chance dozens of times inside the image itself —
silently corrupting it into invalid base64 on every recording. Fixed by
anchoring the rule to `"at 0x%x+"` (the literal text Python always emits
right before the address, which base64's alphabet can't produce on its own)
in `tests/record_transcripts.lua`, then re-recorded only `rich_output`
(the other 4 scenarios never matched `0x` at all, confirmed against the
previously-committed files) and re-verified T1's byte-identical-across-two-runs
bar still holds. This is why `replay-rich_output.txt`'s `== images ==`
section shows a real decoded placement rather than an
`[image — invalid base64]` fallback line.

---

## T3 — Gated end-to-end smoke tests (real kernel)

**Goal:** a handful of true E2E tests that catch "the transcripts no longer
match reality." Run before release or after touching `server.lua` /
`ws_client.py` — not on every edit.

**Build:**

1. `tests/spec/e2e_spec.lua`, gated exactly like `bridge_spec.lua`
   (self-skip without a marimo-equipped `NEO_MARIMO_TEST_PYTHON`).
2. Add `t.eventually(fn, timeout_ms, msg)` to helpers — poll `fn` via
   `vim.wait` until truthy or timeout. All E2E assertions go through it;
   never bare sleeps.
3. Scenarios (≈5, no more):
   - attach: start server, connect WS, `kernel-ready` arrives.
   - run: run one cell, output extmark eventually renders expected text.
   - edit + re-run: change code, save, re-run, output updates.
   - widget: set a widget value, dependent cell re-renders.
   - disconnect/reconnect: kill WS client job, resync path recovers.
4. Each E2E case tears down fully (server stop, buffer wipe) even on failure
   — wrap in pcall + cleanup, or a `t.with_server(...)` helper, so one
   failure doesn't cascade port conflicts into the next case (respect the
   existing port-conflict identity check in `server.lua`; don't work around
   it).
5. Makefile: `make test` keeps running them (they self-skip fast when
   ungated); `make test-e2e` = filter for just these when iterating.

**Acceptance:**

- With the test python configured: all five pass, repeatedly (run 3× in a
  row — flaky E2E is worse than no E2E; fix flakes with `eventually`
  conditions, longer quiescence, or by cutting the scenario).
- Without marimo: all five self-skip, suite green.

**Deviation taken:** none from the build steps — `tests/spec/e2e_spec.lua`
implements exactly the five scenarios listed, gated identically to
`bridge_spec.lua`, teardown via a `with_notebook(scenario, fn)` helper
(pcall + always-run cleanup) rather than a `t.with_server` wrapper, since the
scenarios need a real notebook/buffer/tempdir torn down alongside the server,
not just the server. `t.eventually` landed in `tests/helpers.lua` as
specified; every E2E assertion goes through it, no bare sleeps.

One genuine finding while writing the disconnect/reconnect case: the
server.lua `resync_ws` doc comment ("marimo replays kernel-ready … re-emits
every cell's output") describes the *kiosk self-heal after an id desync*
path (`output.handle_cell_op`'s own resync trigger). A plain reconnect to a
session marimo never dropped server-side — this case's actual scenario:
kill `ws_client.py`, call `resync_ws` — does **not** replay `kernel-ready`.
It sends a payload-less `"reconnected"` op instead, which `ws_handlers.lua`
had no handler for (dispatch silently returned `false`, same as any
unregistered op). Registered it as an explicit no-op in `ws_handlers.lua`
with a rationale comment, following the exact precedent T2 set for
`remove-ui-elements`/`datasets` — a real (if small) production-code
completion this test phase surfaced, not scope creep: it closes the same
"is this drop the future or a shrug" ambiguity flagged there. The E2E case
itself asserts against the observed `"reconnected"` behavior rather than the
comment's `kernel-ready` claim; the comment describes a different, real code
path and was left alone.

Recorded 3 consecutive `make test-e2e` runs against marimo 0.19.4
(`MyMainTestingPython`, per the Makefile default) — all 5 scenarios green
every time (15/15 case-runs). A run with `NEO_MARIMO_TEST_PYTHON` pointed at
a marimo-less interpreter (`/opt/homebrew/bin/python3`) self-skipped all
five (and `bridge_spec`/`server_spec`'s ws_client check alongside them),
suite green. Full `make test` green both with and without marimo configured.

---

## T4 — One-command UX, repro harness, docs

**Goal:** the entire pipeline is trivially usable. One command runs
everything; one command refreshes any generated artifact; one command drops
you into a live manual session that is the same every time.

**Build:**

1. Makefile final shape (all already exist by now except `demo`):
   - `make test` — everything (unit, replay, gated E2E/bridge which
     self-skip). **The one command.** `FILTER=` still works.
   - `make snapshots` — regenerate goldens.
   - `make transcripts` / `make fixtures` — regenerate recorded artifacts.
   - `make demo [SCENARIO=widgets]` — launch real nvim (not headless) with
     the scenario notebook copied to a temp dir (so edits don't dirty the
     repo), plugin on rtp from this working copy, kernel from
     `NEO_MARIMO_TEST_PYTHON`, attached and ready. This makes the remaining
     manual testing one keystroke and identical every time.
2. `docs/testing.md` — short, honest doc: the four layers (unit / replay /
   E2E / manual demo), which command does what, how to add a test for a new
   bug ("record or reuse a transcript → replay → snapshot"), and the golden
   rule: **every manually-found bug becomes a replay/snapshot case before
   its fix merges.** Link it from CLAUDE.md's dev-loop section (one line).
3. Wire the run-everything flow into the failure loop: when `make test`
   fails a snapshot, the output must already tell the user the exact command
   to accept the change (`make snapshots FILTER=<case>`), and FILTER must
   work for snapshot regeneration (it falls out of run.lua's existing filter
   if T0 implemented snapshots inside cases — verify).

**Acceptance:**

- A cold contributor (or agent) can read `docs/testing.md` top-to-bottom in
  two minutes and successfully: run the suite, break a snapshot, read the
  diff, accept it, and start a demo session.

**Deviation taken:** none from the build steps' intent, but two things worth
recording for whoever touches `tests/demo_init.lua` next:

- **`FILTER` must name the failing *case*, not the snapshot.** run.lua's
  filter is a plain substring match against `case.name`, and a snapshot's own
  name isn't always a substring of its case's name (e.g.
  `output_spec.lua`'s case `"output: tabs payload attaches virt_lines and
  registers widgets"` snapshots as `"output-tabs_with_table"` — neither string
  contains the other). Fixed by having run.lua stash the currently-executing
  case's name (`t._current_case`) before calling `case.fn`, and having
  `t.snapshot`'s failure messages build the accept command from that instead
  of the snapshot name.

  **Post-review correction:** the first version of this (`FILTER="<case
  name>"`, hand-rolled double-quoting) was a real command-injection bug, not
  just a cosmetic escaping gap — a review caught it and it's worse than
  "breaks on paste": `output_spec.lua`'s case name contains a literal `"`
  (breaks out of the wrapping quotes) and `snapshot_spec.lua` has one
  containing backticks, and **double quotes do not neutralize backticks in
  POSIX shell** — `` "`cmd`" `` still runs `cmd`. Worse, the root cause
  wasn't only the printed message: the Makefile recipes themselves spliced
  `$(FILTER)`'s expanded text straight into a double-quoted recipe line
  (`nvim -l tests/run.lua "$(FILTER)"`), so *any* value containing a backtick
  reaching `FILTER` — typed by hand or pasted from the (now-fixed) message —
  got executed by the recipe's own shell. Confirmed by demonstration:
  `make snapshots FILTER='probe `touch /tmp/pwned` end'` really did create
  `/tmp/pwned`.

  Fixed at both layers:
  1. **Makefile:** `FILTER` is no longer referenced as `$(FILTER)` inside any
     recipe's shell text. `export NEO_MARIMO_TEST_FILTER = $(FILTER)` instead
     places the value directly into each recipe's process environment
     (execve's envp), which a shell never re-parses for word-splitting,
     globbing, or command substitution — `tests/run.lua` and
     `tests/record_transcripts.lua` read `NEO_MARIMO_TEST_FILTER` (namespaced
     to avoid colliding with an unrelated ambient `$FILTER`) as a fallback
     when no positional CLI arg was given, so direct invocations
     (`nvim -l tests/run.lua html`) are untouched. Re-verified the backtick
     case is inert through this path: `make snapshots FILTER='probe
     `touch /tmp/pwned` end'` no longer creates the file.
  2. **`tests/helpers.lua`'s `accept_command`:** doubles any literal `$` in
     the value (GNU Make expands `$` inside a command-line-set variable's
     value every time it *computes* that value — this happens even for the
     export form above, so it's not a shell issue at all; confirmed
     empirically that an unescaped `$` silently eats characters, e.g. an
     embedded `$HOME` truncating to `OME`), then wraps the result with
     `vim.fn.shellescape` (single-quote based — this is what actually
     neutralizes backticks/`"`/spaces for the human's own shell, unlike the
     original hand-rolled double quotes).

  **Genuinely remaining limitation** (documented rather than solved with a
  heavier value-passing mechanism, since no committed case name hits it): a
  case name containing a literal `$` must be typed as `$$` by whoever pastes
  the printed command, because of the make-level expansion above — this is
  inherent to how GNU Make computes command-line-variable values and applies
  regardless of the export vs. `$(FILTER)`-in-text choice.

  Re-verified end-to-end after the fix, including against real hostile case
  names (not just synthetic ones): `make test FILTER='snapshot: missing
  golden without the update env fails and names `touch /tmp/PWNED2`'` (a
  deliberately-injected payload riding along the shape of
  `snapshot_spec.lua`'s real backtick-containing case name) selected zero
  cases and created no file; `make test FILTER='<that real case name,
  verbatim>'` correctly selected and passed exactly that one case. Separately,
  corrupted a committed golden (`output-tabs_with_table.txt`), confirmed
  `make test` fails with a diff + `.actual.txt` + the printed accept command,
  ran that command verbatim, confirmed it regenerated ONLY the one golden
  (`git status`/`git diff` showed no other file touched, byte-identical to
  the pre-corruption original), and that `make test` was green again
  afterward (279 cases, up from 277 — two new regression cases added to
  `snapshot_spec.lua` exercise `accept_command` directly: one with a
  self-contained hostile case name containing both a backtick and a `"`, one
  covering the `H._current_case == nil` fallback path).
- **`nvim -u FILE`'s automatic `'runtimepath'/plugin/**` scan runs BEFORE
  `FILE` itself executes**, not after — prepending this working copy onto
  `'runtimepath'` inside `tests/demo_init.lua` was too late for
  `plugin/neo-marimo.lua`'s autocmds/user commands (the real attach entry
  point) to be picked up by nvim's own automatic pass; verified empirically
  (the plugin's `NeoMarimo` augroup didn't exist after the prepend). Same
  reason lazy-loading plugin managers explicitly `:runtime` their managed
  plugins rather than relying on the automatic scan — their bootstrap IS the
  `-u`/init.lua execution, same boat this demo script is in. Fixed with an
  explicit `vim.cmd("runtime! plugin/neo-marimo.lua")` right after the
  `rtp:prepend`. Verified for real (not just reasoned about): `make demo`
  with `NVIM_ARGS='--headless -c "sleep 4" -c qa'` against all of
  `basic_run`/`widgets`/`error_cell` shows the real attach message
  (`Opened <scenario>.py (N cells)`) followed by a REAL kernel actually
  connecting (`Server ready. Connecting...` → `WebSocket connected.` →
  `Connected (nvim-only). Run cells with the run keymaps.`), and leaves no
  stray `marimo edit` process or bound port behind after nvim exits. An
  unknown `SCENARIO` fails cleanly with a notify + `return` rather than
  hanging. The genuinely-interactive path (does the notebook LOOK right in a
  real terminal, do keymaps like `<leader>mr`/`<leader>mv` feel right) was
  NOT exercised from this non-interactive environment — that part is on the
  next human (or agent with a real TTY) to eyeball once.

---

## T5 — tmux visual snapshots (optional; do last; cuttable)

**Goal:** 3–5 golden *screens* — what the terminal actually shows — for the
highest-value views only. This is the brittle layer; it exists to catch
"the box border/column math is visibly wrong," nothing more.

**Build:**

1. `tests/screen/` — a runner script: `tmux new-session -d` with a fixed
   `-x 100 -y 30` geometry, launch nvim with a scenario buffer pre-rendered
   (reuse the replay layer to reach the state — no kernel), `tmux send-keys`
   as needed, wait for stability, `tmux capture-pane -p` → compare to a
   golden text file via the same T0 snapshot mechanics.
2. Self-skips when tmux is absent. `make test-screen` target; **included** in
   `make test` only if it proves reliable — otherwise keep it a separate
   command and say so in docs/testing.md.
3. Keep it to: cell box + output below (the e414de6 gravity fix class),
   wrapped long output, widget glyph line, error styling, dataframe view.
4. Kitty image pixels are explicitly out of scope — placement data is
   asserted in T2; visual image truth stays a manual pre-release check.

**Acceptance:** stable across 3 consecutive runs on the dev machine; a
cosmetic intentional change is a one-command golden update. If stability
can't be reached in reasonable effort, **cut this phase** and record that
decision here — T0–T4 already deliver the core value.

**Deviation taken:** shipped, not cut — stable across 5 consecutive runs (one
creating the goldens, four re-verifying against them unchanged), well past
the 3-run bar. `tests/screen/init.lua` (the `-u` init for the nested real
nvim, modeled on `tests/demo_init.lua`) reaches the rendered state via
`t.make_notebook` + `t.replay` exactly as instructed — no python, no kernel.
`tests/screen/run.lua` owns the private-socket (`-L
neo-marimo-screen-<pid>`) tmux lifecycle, polls `capture-pane -p` until two
consecutive captures match (never a fixed sleep), and asserts through
`t.snapshot` itself (not a reimplementation) so the golden format,
`.actual.txt` dump, and `NEO_MARIMO_UPDATE_SNAPSHOTS=1` flow are exactly T0's
— only the wrong auto-generated "make snapshots FILTER=..." hint in
`t.snapshot`'s own failure message needed correcting (appended, not patched:
`t.snapshot` is shared code other specs depend on, not worth forking over one
string). Goldens live at `tests/snapshots/screen-*.txt`, same directory as
T0's own goldens, disambiguated by prefix rather than a separate directory —
one snapshot mechanism, one place to look.

**Not folded into `make test`** — a private-socket tmux session driving a
second real nvim process is a materially different risk profile than
headless replay even at 5/5 clean runs on one machine, and the whole point
of `make test` staying the one unconditionally-green command is not
gambling that bar on a nested-terminal layer. `make test-screen` (Makefile,
mirrors `make test-e2e`'s shape) runs it on demand; `docs/testing.md` has the
one-paragraph rationale the acceptance criteria asks for.

**Screen selection:** the 5 committed transcripts map onto the 5 named views,
but not 1:1 in the order they're listed — `widgets`/`error_cell` are exact
matches (widget glyph line; error styling), but `error_cell`'s traceback
turns out to ALSO be the best "wrapped long output" exemplar (its HTML lines
are genuinely hard-wrapped by `output.lua`'s `wrap_virt_line` pass — visible
in the golden as lines splitting mid-`<span>` tag), which real marimo error
output always looks like — forcing a 6th synthetic scenario just to see
"wrapped" without "styled" would test a state a user never actually sees on
its own. That freed a slot for a 5th screen with real, distinct regression
value that isn't one of the 4 named categories: `edit_rerun`'s mid-replay
state (`until_action = 2`, the same intermediate point T2's own
`edit_rerun-mid` snapshot targets) — the buffer shows edited code while the
output extmark still shows the stale value, a real visual bug class (stale
output surviving an edit) that's cheap to show since the transcript's
already committed. Final mapping: `basic_run` → cell box + output below,
`widgets` → widget glyph line, `error_cell` → error styling + wrapped long
output, `rich_output` → dataframe view (the image cell in the same scenario
has no pixels to show without a real backend, per build step 4 — its box is
just an empty `✓ ran` line, still useful coverage of a border straddling a
large source cell), `edit_rerun` (mid) → stale output after an edit.

**Genuine finding (Neovim, not neo-marimo):** the first attempt at each
screen was missing the TOP border of whichever cell landed on the window's
`topline` — not just the buffer's first cell; ANY cell, whenever a hard
`topline` jump (`gg`, `zt`, or a buffer's very first paint after
`nvim_win_set_buf`/`nvim_set_current_buf`) puts its `virt_lines_above` anchor
row at the top of the window. Verified two ways: (1) a minimal 2-extmark
repro isolating it from any neo-marimo code, and (2) independently, driving
the REAL `M.attach` flow (real parser, real buffer, real border code, no
test harness involved) against `basic_run.py` — a notebook's first cell's
top border is invisible the instant ANY real user opens ANY notebook, every
time, until something scrolls the window. It reliably reappears once the
view scrolls THROUGH that row incrementally (confirmed: `G` then repeated
Ctrl-Y — Neovim's incremental-scroll path recomputes `topfill`, the display
space `virt_lines_above` needs, correctly; a hard topline jump doesn't).
This is a Neovim/extmark rendering characteristic that predates and is
independent of this plugin's border code — out of scope to patch inside a
test-infrastructure phase, and risky to fix blind without its own review
pass (interaction with `WinResized`/`BufWinEnter`/the debounced
`redraw_outputs` path wasn't audited here). `tests/screen/init.lua`
reproduces the same "scroll through once" settle (`G` + repeated Ctrl-Y) so
the committed goldens show the fully-painted state a real user sees after
their first scroll, not a misleading first-paint artifact that would
otherwise mark every single screen "broken" at the exact thing this layer
means to check (border correctness) for a reason that has nothing to do with
border correctness. Flagged as a `TOCHANGE.md` Inbox item for the
maintainer to triage a real fix (e.g. forcing a redraw pass after
`buffer.render_all_borders`/`M.attach`) — not fixed here.

**Verification:** self-skip confirmed two ways — `NEO_MARIMO_TMUX_BIN=
/nonexistent/tmux make test-screen`-equivalent invocation exits 0 with a
skip notice, and independently with `tmux` genuinely absent from `PATH` (a
throwaway symlink-only directory containing just `nvim`), same clean exit 0.
`make test` (300 cases) stayed green throughout, with `git status` clean of
stray artifacts after every run (the screen layer's own goldens are the only
new tracked files this phase adds). `make test-screen FILTER=error` narrows
to one screen, confirming the same FILTER convention as the rest of the
suite works here too.

---

## T6 — CI (can run in parallel with T3–T5)

**Goal:** the suite runs on every push without the dev machine.

**Build:**

1. `.github/workflows/test.yml`:
   - Job 1 (always): install nvim ≥0.11 (stable), `make test` — unit +
     replay layers, no python needed. Fast, required.
   - Job 2 (marimo matrix): setup python, `pip install marimo==0.19.*` (and
     a `0.23.*` leg), set `NEO_MARIMO_TEST_PYTHON`, `make test` — ungates
     bridge + E2E. Allowed to be slower; still required once stable.
   - On snapshot failure, upload `tests/snapshots/*.actual.txt` as an
     artifact so diffs are inspectable from the CI page.
2. Style gates (stylua/luacheck) belong to release-plan R2 — if R2 has
   landed by the time this runs, add them as a third job; if not, leave a
   TODO comment in the workflow, don't pull R2 forward.

**Deviation taken:** the repo already had a stale pre-T6 `.github/workflows/test.yml`
(from an earlier commit, before this plan existed) — a single job matrixed
over nvim stable/nightly that always installed marimo 0.19 and never
self-skip-tested the no-python path. Replaced it wholesale rather than
layering T6 on top, since the old shape didn't separate the fast
always-green check from the marimo-gated one the acceptance criteria calls
for. Named the two jobs `unit` and `marimo` (rather than literally "Job 1"/
"Job 2") and dropped the old nightly-nvim leg — not part of this phase's
contract and it would have doubled the marimo matrix's runtime for no
acceptance-criteria benefit; can be added back as a separate concern later.
Each matrix leg (unit, and each marimo version) uploads its own
`snapshot-diffs-*` artifact on failure so a red 0.23-only leg doesn't get its
diff clobbered by a green 0.19 leg's artifact name.

Verified locally (cannot push from this worktree, so no live GitHub run):
`make test` green: 271 passed; `make test PYTHON=/nonexistent/python` green:
265 passed (6 bridge-round-trip cases self-skip, everything else still runs)
with a clean `git status` after (no snapshot self-test artifacts left behind
by either run); YAML parses cleanly (`ruby -ryaml`, ruby's json parser was
available where python's `yaml` module was not).

**Acceptance:** green run on GitHub for the current master; a PR with a
deliberately broken snapshot shows a red check with the actual-vs-golden
artifact attached.

---

## T7 — real-notebook corpus (drop-in third-party notebooks)

**Goal:** adding a real-world marimo notebook (from marimo's examples repo,
the gallery, or anyone's project) to the test suite is a **file drop, zero
wiring**. The suite auto-discovers it and exercises it at up to three levels.
Corpus notebooks serve two distinct purposes, and the design must keep them
separate: *regression* (notebooks using supported features must stay green
forever) and *exploration* (notebooks using unsupported/future features —
new widgets, new marimo constructs, unusual layouts — must produce a
readable gap report, not a wall of red).

Depends on T0 (snapshots) for level 2 and T1/T2 (recorder/replay) for
level 3. Can start any time after T2.

**Build:**

1. `tests/corpus/<name>.py` — drop a notebook file in, that's the whole
   workflow. A sidecar manifest `tests/corpus/manifest.lua` (or `.json`)
   holds one entry per notebook:
   - `source` — URL it came from (provenance; marimo's repo is Apache-2.0,
     note the license for anything copied from elsewhere).
   - `mode` — `"strict"` (regression: everything must pass) or
     `"exploratory"` (report gaps, never fail the suite).
   - `levels` — which levels to run (default: all that apply).
   A notebook missing from the manifest gets a generated default entry
   (`exploratory`, all levels) and a notice — the drop-in path must work
   before anyone edits a manifest.
2. **Level 1 — parse round-trip** (gated on `NEO_MARIMO_TEST_PYTHON`, like
   `bridge_spec.lua`): parse the notebook through `bridge.py`, regenerate,
   reparse; assert cell count/codes stable. Catches "someone structures
   their notebook a way our parser mangles" — the cheapest and broadest win
   from real-world files.
3. **Level 2 — kernel-free render snapshot** (no python needed): build the
   notebook via `t.make_notebook` from the parsed cell codes (parse output
   from level 1 is cached to a committed `.parsed.json` sidecar so level 2
   still runs on machines without marimo), snapshot `t.render_state` —
   cell boxes, boundaries, structure. Catches layout/tracking regressions
   against real notebook shapes (30-cell notebooks, huge cells, decorators,
   markdown-heavy files) that hand-written fixtures never cover.
4. **Level 3 — recorded transcript + replay** (optional per-notebook):
   `make transcripts CORPUS=<name>` records a run-all session via the T1
   recorder; replay + snapshot via T2. This is where **dependencies** bite:
   real notebooks import pandas/altair/etc.
   - If the notebook carries PEP 723 inline script metadata (marimo's
     sandbox convention), the recorder runs the kernel via
     `uv run --script`-style resolution so deps come from the notebook
     itself.
   - Otherwise, missing imports → skip level 3 with a notice (the
     `capture_fixtures.py` skip pattern), never an error. Levels 1–2 still
     run — a notebook is valuable even if we never execute it.
5. **Exploratory gap report:** in `exploratory` mode, failures and unknowns
   are collected, not thrown: unknown ops from replay (reuse T2's coverage
   guard machinery), widgets with no registered renderer, HTML the output
   renderer punts on, parse warnings. Emitted as a single readable summary
   block at the end of the run (`CORPUS GAPS: <notebook>: 2 unknown widgets
   (foo, bar), 1 unknown op (baz)`), and written to
   `tests/corpus/<name>.gaps.txt` (gitignored) for diffing. **This is the
   future-feature workflow**: drop in a notebook using the new thing →
   read the gap report → implement → flip the manifest entry to `strict`
   once green. Flipping to strict is the "done" signal for the feature.
6. `make corpus-add URL=<raw-github-url> [NAME=<name>]` — fetch a notebook
   (curl is already a plugin dependency), write it to `tests/corpus/`,
   append a default manifest entry with the source URL filled in. Seed the
   corpus with 3–5 notebooks from `marimo-team/marimo`'s `examples/`
   directory spanning: an intro/tutorial notebook, a widget-heavy one, a
   dataframe/plotting one, and one markdown/layout-heavy one.
7. Corpus specs live in `tests/spec/corpus_spec.lua`, auto-generating cases
   from the manifest so `make test` picks new notebooks up with no code
   change; `FILTER=corpus` (or a notebook's name) works via the existing
   run.lua filter.

**Acceptance:**

- Dropping a new `.py` into `tests/corpus/` and running `make test` runs
  levels 1–2 on it with zero other edits (level 1 self-skipping without
  marimo).
- The seeded strict notebooks are green in `make test`.
- An exploratory notebook containing an unsupported widget produces the gap
  summary and does **not** fail the suite.
- `make corpus-add` on a real marimo-examples URL yields a working corpus
  entry end-to-end.

**Known risk / permitted deviation:** transcript determinism (T1's
byte-identical bar) may be unreachable for arbitrary third-party notebooks
(random data, network fetches, timestamps). That bar applies only to the
curated T1 scenarios; corpus level-3 transcripts may instead be marked
`unstable` in the manifest, meaning they are re-recorded rather than
committed, or skipped in CI. Don't burn time chasing determinism for a
notebook that fetches live data — levels 1–2 already carry most of its
value.

**Implementation notes (2026-08):**

- All 4 seeded notebooks are **real fetches** from `marimo-team/marimo`
  (Apache-2.0) via `raw.githubusercontent.com` — network access was
  available in the implementing environment, so no hand-written substitute
  notebooks were needed: `marimo/_tutorials/intro.py` (intro/tutorial,
  strict), `examples/ui/code_editor.py` (widget-heavy, exploratory),
  `examples/ui/table.py` (dataframe/plotting, strict), and
  `examples/markdown/admonitions.py` (markdown/layout-heavy, exploratory).
- The widget-heavy pick went through one real revision: `mo.ui.run_button`
  was tried first on the assumption its `<marimo-run-button>` tag would be
  unsupported (tree_render.lua's `WIDGET_TAGS` only lists `"button"`), but a
  real recorded transcript showed marimo actually serves `run_button`
  through `mo.ui.button`'s own `<marimo-button>` custom element — already
  fully supported, so it silently proved nothing. Cross-checked against
  every `_name: Final[str] = "marimo-..."` constant in the installed
  marimo's `_plugins/ui/_impl/` (`grep -rn` beats guessing) before picking
  `mo.ui.code_editor` (`<marimo-code-editor>`, genuinely absent from both
  `WIDGET_TAGS` and `PLACEHOLDER_TAGS`), which does reach `render_unknown`
  and is what `tests/corpus/manifest.lua`'s entry documents.
- Level 2 (kernel-free) turns out structurally unable to exercise the
  widget/HTML gap-scan categories at all: `t.make_notebook` builds buffer +
  cell borders only, with no `cell-op` output ever dispatched (there's no
  kernel), so `Gaps:scan_render_state` only ever has parse-warning-shaped
  input to work with at level 2. The "unknown widget" / "HTML punt"
  categories are real only once level 3 has replayed an actual `cell-op`
  with rendered content — confirmed by chasing exactly this down when
  `code_editor`'s gap didn't show up until a transcript existed.
- All three `levels = {1,2,3}` notebooks' recordings (`intro_tutorial`,
  `dataframe_table`, `widgets_code_editor`) turned out byte-identical across
  3 consecutive `make transcripts CORPUS=<name>` runs — same bar T1 held its
  curated scenarios to, achieved without any extra normalization work since
  `tests/record_transcripts.lua`'s existing scrub rules (PYTHONHASHSEED pin,
  UUID/timestamp/port/hex-addr rules) already cover what these notebooks
  emit. Rather than leave the "Known risk" opt-out on the table, these three
  are committed with `git add -f` (the escape hatch the corpus
  `.gitignore` rule's own comment names) so a fresh clone's `make test`
  demonstrates the full three-level story — including the exploratory gap
  report — with no manual recording step. `markdown_admonitions` has no
  level-3 transcript (its manifest entry only requests levels 1–2 — pure
  presentation, not worth a kernel spawn).
- `tests/corpus_add.lua` (the `make corpus-add` implementation) is tested
  against `file://` URLs in `tests/spec/corpus_add_spec.lua`, per the task's
  explicit instruction to avoid a hard network dependency in the suite — it
  was also exercised once by hand against a real
  `raw.githubusercontent.com` URL to confirm the network path itself works
  (not committed; that was a manual check, reverted afterwards). Testability
  needed one small addition beyond what the plan specified:
  `tests/corpus.lua`'s `M.dir` now reads an optional
  `NEO_MARIMO_CORPUS_DIR` env override (unset in every normal `make test`/
  `make transcripts` invocation) so the spec can point a real, `os.exit()`-
  ing `nvim -l` subprocess at a throwaway directory instead of mutating this
  repo's actual `tests/corpus/manifest.lua`.
- `python/bridge.py` gained one new subcommand, `check-imports <filepath>`,
  used by the corpus level-3 recorder to skip a real kernel spawn (and the
  WS session it would produce) for a notebook whose dependencies the test
  python doesn't have — AST-based (walks each cell's `Import`/`ImportFrom`
  nodes, checks `importlib.util.find_spec`) rather than actually importing,
  since importing an arbitrary third-party notebook's dependencies here
  could run arbitrary top-level side effects.

---

## Suggested hand-off to implementer agents

- **Agent A:** T0, then T1 (sequential — same artifact conventions).
- **Agent B:** T2 (after T0+T1 land; the biggest single phase — give it the
  whole phase, nothing else).
- **Agent C:** T3 + T4 (after T2; they share the helpers and Makefile).
- **Agent D:** T6 any time after T0 (Job 1 only needs the base suite);
  T5 last, only if T0–T4 shipped and appetite remains.
- **Agent E:** T7 after T2 (needs snapshots + replay; parallel with C/D).

Each hand-off should include: this file, the phase section, and the
reminder that acceptance criteria are the contract while build steps are
negotiable. Run `lua-reviewer` on each phase's diff before merging it.
