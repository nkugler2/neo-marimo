---
id: TOCHANGE
aliases: []
tags: []
---

# TOCHANGE — Backlog

This file lists **future work only**. How it works:

1. **Capture:** drop new thoughts under **Inbox** below — rough is fine, one or
   two sentences.
2. **Triage (AI):** an AI session moves Inbox items into **Open**, grouping and
   clarifying them (and deduping against what's already there).
3. **Done = deleted:** when an item ships, it is **removed from this file
   entirely**. The record of what happened lives in git history, the plan docs
   (`docs/plan-*.md`), and DEVLOG.md — never here. If you're looking for
   something that used to be in this file, check `docs/plan-refinement.md`
   (which closed most of the 2026-06 backlog) or `git log -p TOCHANGE.md`.

To promote an Open item into formal planned work, copy it into the relevant
plan doc (`docs/plan-release.md` for the current release push,
`docs/plan-phases-7-15.md` for features) and flesh it out there.

---

## Inbox

<!-- New thoughts go here. AI: triage these into Open, then clear this list. -->

---

## Open

### Bugs / needs investigation

- **Markdown output appeared later/out of order (no repro)** — seen once in the
  week-one notebook, which is gone. The most plausible cause (stale output
  anchors) was fixed in refinement phase F2; re-observe in daily use and only
  investigate if it happens again on the current code.
- **"External editing" warning** — fires at unclear times; need to note the
  exact circumstances next time it appears before anything can be fixed.

### Features / ideas (post-release — pre-release rule is "no new features")

- **Collapse cells** — fold cells (especially markdown) so only the output
  shows, approaching the cleanliness of the marimo browser editor. This is
  part of full feature parity.
- **Wider numpy/dataframe output** — a 10x10 array wraps to 2 lines per row
  even on a wide screen. Diagnosed in `docs/plan-refinement.md` (Deferred): the
  kernel embeds line breaks at numpy's default `linewidth=75`; nvim can't
  rejoin them. The real fix is a feature: push a window-width
  `np.set_printoptions(linewidth=…)` hint into the kernel. Related nit:
  `output_text_width` uses the first window showing the buffer, so width is
  wrong with two splits.

### Blocked upstream (revisit only if marimo changes)

- **nvim→browser widget glyph doesn't move** — when a slider changes in nvim,
  the browser recomputes values but its thumb stays put (and vice-versa was
  fixed on our side). marimo's frontend doesn't reposition widgets from
  `variable-values` broadcasts; needs an upstream change or RTC.

### Watch (deleted diagnostics remain in git history / code comments)

- **HTTP 500 "Invalid session id"** — was a downstream symptom of the dead-WS
  bug (fixed 2026-06-17); revisit a reclaim+retry only if 500s reappear.
- **Cell-id desync** — believed fully fixed (F1.2 + resync self-heal). If a
  cell ever sticks at "queued" again, use `:MarimoWsDebug` and look for
  `cell-op:DROP` / `rekey:` traces before re-diagnosing from scratch.
