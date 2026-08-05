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
