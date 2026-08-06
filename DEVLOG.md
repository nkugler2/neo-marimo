---
Up Note: "[[Devlog MOC]]"
type: devlog
tags: [devlog]
---

# Devlog — neo-marimo

Day-by-day journal of what changed, why, and what's next. Newest entry on top.
Git is the per-commit log of the code; this is the per-day log of the thinking.

## 2026-08-05 — T2 replay layer shipped; T0–T2 committed as three phase commits

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

### What to test
- `make test` — 271 passed with marimo configured, 265 without (gated specs
  self-skip); replay cases alone: `nvim -l tests/run.lua replay`.
- Break-a-snapshot loop: edit any scenario snapshot golden, watch the
  readable diff + `.actual.txt`, re-accept with `make snapshots`.

### Next steps
- T3–T7 are now unblocked and independent; per the plan's hand-off section,
  T3+T4 go to one implementer, T6 and T7 can run in parallel, T5 last (and
  cuttable). Nothing pushed yet — push when ready.
