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
- **Buffer switching breaks the notebook view** — in a LazyVim config, the
  buffer-cycling keys `<S-h>`/`<S-l>` do nothing while a notebook buffer is
  focused, and switching away via `<leader>b<n>` and back leaves the rendered
  view gone (cells/output no longer drawn). Suspected cause: notebook buffers
  are special (unlisted/scratch-style) buffers, so LazyVim's listed-buffer
  navigation skips them, and rendering isn't re-applied when the buffer is
  hidden and shown again. Needs investigation into how attach/render reacts to
  buffer hide/show (`BufEnter`/`BufWinEnter`) and whether the buffer should be
  `buflisted`.
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

- **Keyboard-first navigation audit** — the plugin's whole premise is living by
  Neovim's keyboard-shortcut ethos. Review how the notebook is currently
  navigated and decide whether viewing, editing, and interacting with it can be
  done purely from the keyboard, then close the gaps. The two ideas below are
  concrete pieces of this.
- **"Show all widgets" keybind** — a keybind to surface every widget in the file
  at once (typically only 2–5, so showing all is fine; handle the
  many-widgets case later).
- **Center-on-output keybind** — a keybind to scroll/center a specific output
  (e.g. a graph) fully into view. Motivating pain: a random-walk graph is hard
  to get entirely in frame while editing widgets to watch it update — it
  currently requires adding a filler cell below the output just to see the whole
  thing, and framing is janky depending on cell count and spacing.
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

### Transport review — flagged, not worth acting on now

From the plan-refinement transport review; keep in mind but no action planned
unless one of these actually manifests.

- **`http_post_raw` status-line parse ambiguity** — the parse
  (`stdout:match("^(.*)\n(%d+)%s*$")`) could misparse a response body ending
  in a digits-only line; marimo's JSON responses make this near-impossible.
- **`SAVE_SUPPRESS_MS` vs marimo's polling fallback** — `SAVE_SUPPRESS_MS =
  1500` vs marimo's ~1s polling fallback; under heavy load a late echo could
  slip past the suppression window and round-trip a stale reload. Needs a
  slow-fs repro before touching.

### Watch (deleted diagnostics remain in git history / code comments)

- **HTTP 500 "Invalid session id"** — was a downstream symptom of the dead-WS
  bug (fixed 2026-06-17); revisit a reclaim+retry only if 500s reappear.
- **Cell-id desync** — believed fully fixed (F1.2 + resync self-heal). If a
  cell ever sticks at "queued" again, use `:MarimoWsDebug` and look for
  `cell-op:DROP` / `rekey:` traces before re-diagnosing from scratch.
