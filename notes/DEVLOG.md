---
up: "[Home](HOME.md)"
type: devlog
tags: [devlog]
---

# Devlog — neo-marimo

Day-by-day journal of what changed, why, and what's next. Newest entry on top.
Git is the per-commit log of the code; this is the per-day log of the thinking.

## 2026-08-08 — T5 tmux screen snapshots shipped; hit-enter-prompt redraw fix

### Steps taken

1. Ran phase T5 of `docs/plan-testing.md`: `tests/screen/` (`init.lua` +
   `run.lua`) drives a real, non-headless nvim inside a private-socket tmux
   session per screen, reaching rendered state via T2's replay layer
   (`t.make_notebook` + `t.replay` against a committed transcript — no
   python/kernel involved), captured with `tmux capture-pane -p` after
   polling for two stable consecutive captures, and asserted through T0's
   `t.snapshot` against goldens under `tests/snapshots/screen-*.txt`.
   Self-skips cleanly without tmux (verified with PATH stripped of tmux and
   via a bogus `NEO_MARIMO_TMUX_BIN`). Wired up as `make test-screen`,
   deliberately kept out of `make test` (reasoning captured in
   `docs/testing.md`), and held stable across 5 consecutive runs.
2. Along the way, found (and documented, not fixed — out of scope for test
   infra) a real Neovim rendering quirk: a cell's top border is invisible on
   first paint whenever its border lands on the window's topline via a hard
   jump, until the view scrolls through it. Affects every notebook's first
   cell. Recorded in `docs/plan-testing.md`'s T5 section and `TOCHANGE.md`
   for a real fix later; `tests/screen/init.lua` works around it locally so
   the committed goldens show the real, settled state.
3. Separately, fixed a UX bug surfaced by manual `make demo` runs:
   `utils.info/warn/error` fire in synchronous back-to-back chains (attach →
   start → port-fallback in `server.lua`, attach → start_server in
   `tests/demo_init.lua`) with no screen draw between them, so the second
   message stacked on the first and Nvim blocked with "Press ENTER or type
   command to continue" before the notebook was usable. Fixed in
   `lua/neo-marimo/utils.lua` by redrawing before each echo so messages
   display individually instead of queuing.

### Decisions

- Kept `tests/screen/` out of the default `make test` run despite it being
  stable for 5 runs — tmux/non-headless nvim dependency makes it a poorer
  fit for CI than the rest of the suite; `make test-screen` is the explicit
  opt-in.
- Documented the first-cell top-border rendering quirk rather than fixing it
  now — real bug, but out of scope for test infrastructure work; routed to
  `TOCHANGE.md` for the maintainer to triage separately.

### What to test

- `make test-screen` — 5 screen snapshots (basic_run, edit_rerun_mid,
  error_cell, rich_output, widgets); self-skips without tmux.
- `make demo` — should now attach and become usable without any keypress to
  clear a stacked "Press ENTER" prompt.

### Next steps

- T5 was the last item flagged "cuttable" in the T3–T7 hand-off; testing
  plan phases T0–T7 are now all shipped. Nothing pushed yet — push when
  ready.

## 2026-08-05 — T0–T4, T6, T7 shipped: replay layer, e2e smoke, demo UX, corpus, CI

### Steps taken

1. Ran phase T2 of `docs/plan-testing.md` via an implementer agent:
   `t.replay()` in `tests/helpers.lua` feeds T1 transcripts through the real
   `server._decode_ws_line` → `ws_handlers.dispatch` path against a real
   `t.make_notebook` buffer — headless, no kernel, ~0.17s for all replay
   cases. `tests/spec/replay_spec.lua` snapshots all five scenarios (plus an
   edit_rerun intermediate state) and adds a coverage guard over every
   committed transcript.
2. The coverage guard immediately caught two silently-unhandled ops
   (`remove-ui-elements`, `datasets`) — now explicit documented no-ops in
   `ws_handlers.lua` so the no-handler path stays reserved for genuinely new
   ops.
3. T2 exposed a real T1 bug: the unanchored `0x%x+` scrub rule in
   `tests/record_transcripts.lua` was corrupting the ~220KB base64 PNG inside
   `rich_output.jsonl` (random "0x"+hex runs inside the image data). Anchored
   to `"at 0x%x+"`, re-recorded that one transcript, re-verified
   byte-identical determinism. Only replay could have caught this — early
   validation of the whole layer.
4. Acceptance proof: reverted the F2.6 registry-migration fix locally; the
   replay snapshot failed with a readable "old key still shows a placement"
   diff; restored. Image rendering handled via a narrow `image.lua` test seam
   (`_set_test_backend`) — placement bookkeeping stays real, only the
   terminal draw call is stubbed.
5. lua-reviewer pass on the full diff: no blockers/should-fixes; applied its
   two comment-only nits inline (lexicographic version-sort caveat on
   `H.transcript_dir`, cancelled-run caveat on the `remove-ui-elements`
   no-op).
6. Committed T0–T2 as three phase-aligned commits on master (`7aa4855` T0
   snapshot engine, `53a9040` T1 recorder + transcripts, `9c716dd` T2 replay
   layer), hand-splitting the three mixed files (`tests/helpers.lua`,
   `Makefile`, `docs/plan-testing.md`) into intermediate states. Verified
   each commit passes `make test` in isolation via a temp worktree.
7. Created `DEVLOG.md` itself (`a34cc05`) via the `log-today` skill, to start
   keeping a per-day thinking log alongside git's per-commit log.
8. Shipped T6 (`8650a81`): replaced the stale pre-T6 single-job GitHub
   Actions workflow with two jobs — `unit` (nvim stable, no python, proves
   the no-marimo self-skip path stays green) and `marimo` (matrix over
   0.19._/0.23._, ungates the bridge round-trip specs). Both upload
   `tests/snapshots/*.actual.txt` on failure for CI-side diffing. Style
   gates left as a TODO comment pending R2's `.stylua.toml`/`.luacheckrc`.
9. Shipped T3 (`e780873`): `tests/spec/e2e_spec.lua` adds 5 scenarios
   (attach, run, edit+rerun, widget, disconnect/reconnect) driving
   `server.lua`'s real start/connect/run/stop machinery against an actual
   marimo kernel, gated like `bridge_spec.lua` so `make test` self-skips
   cleanly without a marimo-equipped `NEO_MARIMO_TEST_PYTHON`. Added
   `t.eventually` (poll-until, no bare sleeps) to `tests/helpers.lua` and
   `make test-e2e`. The disconnect/reconnect case surfaced that a plain WS
   reconnect sends a payload-less `"reconnected"` op rather than replaying
   kernel-ready — registered as an explicit `ws_handlers` no-op.
10. Shipped T7 (`35d9200`, prep started earlier the same day at `d51ba4c`
    adding the T7 section to `docs/plan-testing.md`): `tests/corpus/` holds
    drop-in third-party marimo notebooks, auto-discovered via
    `tests/corpus/manifest.lua`, exercised at up to three levels — parse
    round-trip through `bridge.py` (gated on `NEO_MARIMO_TEST_PYTHON`),
    kernel-free render snapshot from a committed `.parsed.json` sidecar, and
    transcript replay via the T1 recorder. "Strict" notebooks assert on
    every level; "exploratory" notebooks collect gaps (unknown
    widgets/HTML/ops/parse-warnings) into a single CORPUS GAPS summary
    instead of failing the suite. Seeded with 4 real notebooks from
    marimo-team/marimo (Apache-2.0). `make corpus-add URL=... [NAME=...]`
    fetches and appends a manifest entry; `python/bridge.py` gained a
    `check-imports` subcommand so the level-3 recorder can skip a notebook
    with unmet dependencies instead of letting a kernel spawn fail loudly.
    Post-review fixes: malformed manifest entries (bad `levels`/`mode`
    shapes) now degrade one notebook instead of aborting the whole suite at
    spec-load time; `corpus_add.lua` rejects a `NAME` that isn't a valid
    bare Lua identifier before touching the filesystem or manifest, closing
    both an invalid-Lua-splice path and a path-traversal write
    (`NAME=../evil`); the "exploratory never fails the suite" contract now
    also holds when a sidecar is missing and there's no python to regenerate
    it. Regression cases added to `corpus_spec.lua` and
    `corpus_add_spec.lua`.
11. Shipped T4 (`de43bd8`): `make demo [SCENARIO=widgets]`
    (`tests/demo_init.lua`) drops into a real, non-headless nvim loaded
    straight from the working copy via a minimal `-u` config, kernel from
    `NEO_MARIMO_TEST_PYTHON`, always attached and running. Added
    `docs/testing.md`, linked from `CLAUDE.md`'s dev loop. Fixed
    `t.snapshot`'s failure message to print a `make snapshots
FILTER='<case>'` command that actually re-selects the failing case.
    Review fix: the first version of the FILTER accept-command had a real
    command-injection bug, not just a cosmetic escaping gap — real case
    names contain backticks and embedded double quotes, which survived
    double-quoting alone; worse, the root cause reached into the Makefile
    recipes themselves, which spliced `$(FILTER)`'s expanded text into a
    double-quoted recipe line, so any backtick in FILTER got executed by the
    recipe's own shell (demonstrated live with a `touch`-via-backtick
    payload). Fixed at both layers: FILTER and demo's SCENARIO now pass
    through `export NEO_MARIMO_TEST_FILTER`/`NEO_MARIMO_DEMO_SCENARIO`
    (process environment, not shell-spliced text), and `accept_command` now
    doubles literal `$` before wrapping with `vim.fn.shellescape`. Two new
    regression cases in `snapshot_spec.lua` exercise `accept_command`
    directly against a hostile case name and the `H._current_case == nil`
    fallback path. Re-verified end-to-end against real hostile case names
    and a corrupted golden.

### Decisions

- Registered `remove-ui-elements`/`datasets` as explicit no-ops rather than
  leaving them unhandled: keeps the coverage guard's "dispatch returned
  false" signal meaning "an op nobody has looked at yet", not "known noise".
- Folded the anchored scrub fix into the T1 commit (not T2) so the recorder
  and its committed transcripts are consistent at every point in history;
  the discovery story lives in the plan's T2 deviation note.
- Stubbed only `pick_backend()`'s return in `image.lua` instead of the whole
  module, so `register_placement`/`migrate_keys`/`clear_for_cell` run for
  real headless — that's what let the F2.6 regression case work at all.
- Registered `"reconnected"` as an explicit `ws_handlers` no-op (T3) for the
  same coverage-guard reason as `remove-ui-elements`/`datasets` in T2.
- Corpus notebooks (T7) are tiered strict-vs-exploratory rather than
  all-or-nothing: lets real third-party notebooks with known gaps stay in
  the corpus as a live gap report instead of either failing the suite or
  being excluded entirely.
- FILTER/SCENARIO (T4) are passed via exported env vars rather than spliced
  into shell/Make text, after finding the splice path was a real, live
  command-injection bug rather than a cosmetic escaping concern.

### What to test

- `make test` — 271 passed with marimo configured, 265 without (gated specs
  self-skip); replay cases alone: `nvim -l tests/run.lua replay`.
- Break-a-snapshot loop: edit any scenario snapshot golden, watch the
  readable diff + `.actual.txt`, re-accept with `make snapshots`.
- `make test-e2e` — 5 real-kernel scenarios (T3); self-skips without
  `NEO_MARIMO_TEST_PYTHON`.
- `make demo [SCENARIO=widgets]` (T4) — real attached kernel session for
  manual checks.
- Corpus suite (T7) — `nvim -l tests/run.lua corpus`; `make corpus-add
URL=...` to add a new third-party notebook.
- CI (T6) — GitHub Actions `unit` + `marimo` matrix jobs on push.

### Next steps

- Only T5 (tmux visual screen snapshots) remained after today, flagged
  cuttable in the plan's hand-off section — shipped 2026-08-08 (see next
  entry). Nothing pushed yet — push when ready.
