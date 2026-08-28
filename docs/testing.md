---
id: testing
aliases: []
tags: []
---

# Testing neo-marimo

Five layers, from fastest/broadest to slowest/narrowest. `make test` runs the
first two on every machine; the gated ones self-skip without a marimo-equipped
Python, and the optional visual layer self-skips without `tmux`. Full build
steps and rationale live in `docs/plan-testing.md` (phases T0–T6) — this page
is the "how do I actually use it" summary.

## The five layers

1. **Unit** (`tests/spec/*_spec.lua`) — plain assertions against real buffers
   and modules, headless, no python. Most of the suite.
2. **Replay** (`tests/spec/replay_spec.lua`) — feeds a committed WS session
   transcript (`tests/transcripts/<version>/*.jsonl`) through the real
   decode+dispatch+render pipeline against a real (kernel-free) buffer, then
   asserts the final render state against a golden snapshot
   (`tests/snapshots/*.txt`). Headless, no python, milliseconds per case —
   this is what replaces most manual re-checking of a fix.
3. **E2E** (`tests/spec/e2e_spec.lua`) — five smoke tests against a REAL
   marimo kernel (attach, run, edit+rerun, widget, disconnect/reconnect).
   Gated on `NEO_MARIMO_TEST_PYTHON`; self-skips cleanly without it. Run
   before a release or after touching `server.lua`/`ws_client.py`, not on
   every edit.
4. **Manual demo** (`make demo`) — a real, interactive nvim session, attached
   and running against a real kernel, for the residue that genuinely needs
   eyes on a terminal (visual layout, image placement, "does this feel
   right"). Identical every time: a scenario notebook is copied to a
   throwaway temp dir first, so nothing you do in a demo session touches the
   repo.
5. **Screen** (`make test-screen`, `tests/screen/`) — optional, cuttable
   (T5): a handful of golden _screens_ — what a real terminal actually shows
   for the highest-value views (cell box + output, a widget glyph line,
   error styling, a dataframe table, an edited-but-stale-output state) — for
   catching "the box border/column math is visibly wrong" specifically. A
   REAL (not headless) nvim inside a private-socket tmux session reaches its
   state through the same replay layer as #2, so still no python/kernel.
   **Deliberately NOT part of `make test`** — see the paragraph below for
   why, and run it separately (before a release, or after touching border/
   output-wrap rendering code). Self-skips cleanly without `tmux`.

## Commands

| Command                        | What it does                                                                                                                                                                                                                                                                   |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `make test`                    | Everything: unit + replay always, E2E/bridge round-trips gated (self-skip without `NEO_MARIMO_TEST_PYTHON`). **The one command.** `FILTER=<substr>` narrows by case name.                                                                                                      |
| `make test-e2e`                | Just the E2E layer, for iterating on it without the full suite.                                                                                                                                                                                                                |
| `make test-screen`             | The optional visual screen layer (#5 above), for iterating on it or checking it before a release. Self-skips without `tmux`. `FILTER=<substr>` narrows by screen name; `NEO_MARIMO_UPDATE_SNAPSHOTS=1 make test-screen` accepts new/changed goldens.                           |
| `make snapshots`               | Regenerate golden render-state snapshots (`tests/snapshots/*.txt`). Same run as `make test` with `NEO_MARIMO_UPDATE_SNAPSHOTS=1`. `FILTER=` scopes it to one case. Does **not** touch the screen layer's own goldens — use `make test-screen` with the same env var for those. |
| `make transcripts`             | Re-record WS session transcripts (`tests/transcripts/<version>/*.jsonl`) against a real kernel. Needs `NEO_MARIMO_TEST_PYTHON`; re-run after bumping supported marimo.                                                                                                         |
| `make fixtures`                | Re-capture the `_repr_html_()` HTML fixture corpus (`tests/fixtures/`). Needs `NEO_MARIMO_TEST_PYTHON`.                                                                                                                                                                        |
| `make demo [SCENARIO=widgets]` | Open a real nvim on a scenario notebook, attached and kernel-running. Default scenario is `basic_run`; see `tests/scenarios/*.py` for the others.                                                                                                                              |

### Why the screen layer stays out of `make test`

It passed its own bar (5 consecutive clean runs on the dev machine it was
built on, `docs/plan-testing.md`'s T5 section has the details) but it's still
a nested real terminal (tmux) driving a second real, non-headless nvim
process — a fundamentally more environment- and timing-sensitive thing to
assert on unconditionally than headless replay, and a flaky entry in the
one-command suite is worse than no entry at all (the same principle T3 and
T6 apply to gating on a real kernel/CI matrix). Run it deliberately with
`make test-screen` instead: before a release, or after touching border/
output-wrap rendering (`buffer.lua`'s border code, `output.lua`'s
`wrap_virt_line`) — the two things this layer actually exists to catch.
Two environment caveats if it ever moves beyond the dev machine: the goldens
assume a UTF-8 locale (box-drawing glyphs; a `LANG=C` container corrupts
captures in ways the diff won't obviously attribute to locale), and on a
very slow machine the settle-poll knobs are env-overridable
(`NEO_MARIMO_SCREEN_ATTEMPTS` / `NEO_MARIMO_SCREEN_INTERVAL_MS`) rather
than requiring a code edit.

`PYTHON=` overrides the interpreter for any of the above (`NEO_MARIMO_TEST_PYTHON`
under the hood); the Makefile default points at a marimo-equipped pyenv env.

## Breaking and fixing a snapshot

Edit anything that changes a rendered output, then `make test`. A mismatch
prints a unified diff, writes `tests/snapshots/<name>.actual.txt` (gitignored,
diff it with any tool), and — this is the part that closes the loop — prints
the exact command to accept the change:

```
run `make snapshots FILTER='<case name>'` to accept this change
```

Copy-paste that verbatim — the quoting is generated with `vim.fn.shellescape`
specifically so it's safe to paste as-is even when a case name contains
spaces, quotes, or backticks (case names are plain English test
descriptions, not sanitized input; a couple of real ones do). It regenerates
only that one golden, not the whole suite — `git diff` to review before
committing it.

## Adding a test for a new bug

The golden rule: **every manually-found bug becomes a replay/snapshot case
before its fix merges.** In practice:

1. **Reuse a transcript if one already exercises the right WS ops**, or
   record a new scenario (`tests/scenarios/<name>.py` + a script in
   `tests/record_transcripts.lua`, then `make transcripts`) if the bug needs
   messages no existing transcript has.
2. **Replay it** in `tests/spec/replay_spec.lua` against a real notebook
   built from the scenario's cell codes.
3. **Snapshot the render state** (`t.snapshot(name, t.render_state(bufnr))`).
   Revert your fix locally and confirm the snapshot diff actually shows the
   bug — a snapshot that would pass either way isn't proving anything.
4. Land the fix; the snapshot is now the regression test.

For a bug that isn't about WS/render state at all (cell tracking, offsets,
editing), a plain unit case in the matching `*_spec.lua`
(`editing_spec.lua` for cell-tracking bugs) is usually a better fit than a
snapshot — use judgment, not a hammer.

Coming: a drop-in corpus of real-world notebooks (`docs/plan-testing.md`, T7)
for exercising the parser/renderer against notebook shapes hand-written
fixtures don't cover.
