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

I should be able to hit a keybind and see all widgets in the file. Often there
are only 2-5 widgets, so it is ok to see all of them. If there are a lot of
widgets, we can solve that problem later.

One example of an issue that I have is that I have a graph of random walks
that I want to be able to edit widgets and see the graph change. However,
it is hard to get the graph to actually be perfectly in the view. I often need
to add a cell below the outputted graph just to see the whole graph. And it is
janky with the number of cells and how far they are to see the graph in frame.
Maybe we can add a keybind to center on a graph or specific output?

Both ideas above have me thinking of something. The whole point of Neovim is to
use keyboard shortcuts, and the whole point of this plugin is to live by that.
So I want to look over what I have in this repo, and see if the way that I
design this plugin to be navigated lives by that keybind ethos. Does it make
sense to view, edit, and interact with this notebook purely with keyboard
shortcuts?

---

## Open

### Bugs / needs investigation

- **Markdown output appeared later/out of order (no repro)** — seen once in the
  week-one notebook, which is gone. The most plausible cause (stale output
  anchors) was fixed in refinement phase F2; re-observe in daily use and only
  investigate if it happens again on the current code.
- **"External editing" warning** — fires at unclear times; need to note the
  exact circumstances next time it appears before anything can be fixed.
- **Image placement doesn't reposition on a `gcc`-style edit of a cell's last
  line** — repro: a cell whose last line is an image-producing expression
  (e.g. `fig`); comment that line out. The rendered graph correctly
  disappears, but the image's on-screen glyph briefly shows up shifted into
  the next (empty) cell instead of just vanishing with it. Suspected cause:
  unlike the `ns_output`/`ns_border` extmarks (gravity-fixed in
  plan-refinement's F2.1 inversion), `image.lua` hands image.nvim/snacks a
  raw row number (`image.lua` `render_path`, `y = row + 1`) with no gravity
  control of our own, and `render_path`'s same-path fast path
  (`if existing and existing.path == path then return {} end`,
  `image.lua:311-315`) skips repositioning entirely when the cached image
  content hasn't changed yet — which is exactly the window between a local
  edit and marimo's reactive rerun confirming new output. Needs a repro with
  `:MarimoWsDebug` logging on to confirm before fixing.
- **Image never re-renders after being cleared, until server restart** — same
  repro as above, one step further: uncomment the `fig` line and rerun (cell
  or whole notebook) — the graph never comes back, and the run
  status/icon next to `fig` doesn't reappear either, even though the fix
  should just be a normal re-render. Only a full `:MarimoRestart` recovers
  it. Unclear yet whether this is neo-marimo losing track of the image
  placement key (e.g. a re-key collision in `ws_handlers.lua`) or the marimo
  kernel itself getting wedged by whatever gets synced while the cell body is
  comment-only. Needs a `:MarimoWsDebug` log across the full repro
  (comment → uncomment → rerun → still broken) before attempting a fix —
  don't guess-patch `image.lua` without it.

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
