---
id: plan-release
aliases: []
tags:
  - roadmap
  - planning
---

# neo-marimo — Plan: Public Release

> **Written:** 2026-06-12, after the hardening pass (dev-link workflow, CI,
> editing-core integration tests, WS error containment, kernel
> interrupt/restart). This plan covers everything between "works on my
> machine, tests are green" and "strangers can install, use, and report
> bugs against it."
> **Preceded by:** [`plan-phases-7-15.md`](plan-phases-7-15.md) (feature
> parity) and [`plan-phases-9-12-detail.md`](plan-phases-9-12-detail.md)
> (rendering/UX/docs).

The guiding rule for this plan: **nothing here adds features.** Every item
is either legal/packaging table stakes, first-run polish, or feedback
infrastructure. If a feature gap surfaces during beta, it goes into
`TOCHANGE.md` and waits its turn — the release bar is "what exists works
flawlessly," not "everything exists."

## Preconditions (verify before starting R1)

- [ ] CI green on both nvim stable and nightly (`.github/workflows/test.yml`).
- [ ] `make test` green locally (144+ specs, including the marimo-gated
      bridge round-trips).
- [ ] At least one full week of daily personal use with **zero new entries**
      added to `TOCHANGE.md`. This is the soak-test exit criterion — if paper
      cuts are still appearing for the author, they'll appear for strangers
      on day one.
- [ ] Manual verification of `:MarimoInterrupt` / `:MarimoRestart` against a
      live kernel (a `while True: pass` cell, then a restart + re-run).

---

## Phase R1 — Legal & repo hygiene (~half a session)

### R1.1 LICENSE

The repo has no license, which legally means **nobody can use, copy, or
modify it** regardless of it being public. MIT is the overwhelming nvim
plugin convention (lazy.nvim, telescope, etc.) and the right default here.
Add `LICENSE` with the MIT text and the copyright line.

### R1.2 Commit the pending doc reorganization

The plan-doc renames (`plan.md` → `plan-phases-1-3.md` etc.) are sitting
uncommitted in the working tree. Commit them as their own `docs:` commit.

### R1.3 Reconcile TOCHANGE.md with reality

Two known drifts, both caused by the phase-number collision between
`plan-phases-7-15.md` and `plan-phases-9-12-detail.md` (both have phases
9–12 meaning different things):

1. The "Integrated" list claims *"Database connections for SQL cells
   (Phase 10 in plan-phases-7-15.md)"* is done. **It is not** — there is no
   `:MarimoSqlConnect`, no `cell.sql_engine` anywhere in the code. The
   shipped "Phase 10" was the *detail plan's* phase 10 (widget UX). Move the
   DB item back to Open (or leave it to the feature roadmap).
2. Open item #1 says Phase 8 rich output is *"currently a NOT DONE item"* —
   Phase 8 shipped 2026-06-05. Delete the item.

While there: add a one-line warning at the top of both plan docs noting the
numbering collision, so future bookkeeping doesn't repeat this.

### R1.4 History scrub check

`notebooks/` and `invest-data/` are gitignored now, but confirm nothing
personal was committed *before* the ignore rules landed:

```sh
git log --all --diff-filter=A --name-only -- 'notebooks/*' 'invest-data/*'
```

If anything sensitive ever landed, decide between history rewrite (before
the repo gets traffic is the only cheap time) or accepting it. Also skim
`MYNOTES.md` — it ships with the repo; keep it or fold the useful parts
into `docs/` and delete it.

**Verification:** fresh clone shows LICENSE; `git status` clean; TOCHANGE
contains no claim the code contradicts.

---

## Phase R2 — First-run experience (~1 session)

A stranger's first 10 minutes decide whether they file helpful bugs or
silently uninstall. Everything here targets that window.

### R2.1 Committed example notebook

The verification corpus (`notebooks/notebook.py`) is gitignored, so a fresh
clone has nothing to open. Add `examples/demo.py` — a sanitized notebook
exercising the renderer's breadth: `mo.md` headings/lists/code, a slider +
dependent cell, a small DataFrame, an hstack/tabs layout, a matplotlib
plot. This doubles as the manual smoke-test script for future releases.

### R2.2 README screenshot / GIF

The README has a placeholder comment (flagged in the detail plan's Phase
12). Capture the notebook view rendering `examples/demo.py` — one still
screenshot minimum; a short GIF of run-cell → output appearing is the
high-impact version. Plugin adoption correlates embarrassingly strongly
with having a picture.

### R2.3 Clean-machine install walkthrough

Test the README install instructions in an isolated config (e.g.
`NVIM_APPNAME=nvim-test` with a minimal init.lua), for both lazy.nvim and
vim.pack paths:

1. Install plugin, no `setup()` call → open a marimo `.py` → does
   auto-attach work or fail with a clear message?
2. `python_path` pointing at a marimo-less python → is the error actionable
   (it should name the config key and show an example)?
3. `:checkhealth neo-marimo` → every WARN/ERROR line tells the user what to
   *do*, not just what's wrong.

Fix whatever this surfaces; it always surfaces something.

### R2.4 State the support matrix plainly

README already names nvim 0.11+ / marimo 0.19 / curl; double-check those
statements match `health.lua`'s tested-series table and add: which terminal
emulators get inline images (kitty/ghostty + image.nvim or snacks.image)
and what everyone else gets (text placeholders — the plugin still works).

**Verification:** a fresh `NVIM_APPNAME` config goes from zero to running
`examples/demo.py` cells using only the README.

---

## Phase R3 — Versioning & releases (~half a session)

### R3.1 Tag v0.1.0

Users pin plugin versions (lazy.nvim `version =`, vim.pack tags). Tag the
release commit `v0.1.0` — semver-ish with 0.x signalling "API may still
move." The four registries documented in `docs/architecture.md` are the
public API; treat changes to them as breaking from here on.

### R3.2 CHANGELOG.md

Keep-a-changelog format, one `## v0.1.0` section summarizing the feature
set at release (cells, sync, LSP, rich output, widgets, execution control).
From now on, user-visible changes get a line under `## Unreleased` in the
same commit that makes them.

### R3.3 Release procedure note

Five lines in the README dev section or CONTRIBUTING: tests green on CI →
update CHANGELOG → tag → push tag. Boring on purpose; it just has to be
written down so future-you doesn't improvise it.

**Verification:** `git tag` shows v0.1.0; installing by tag works.

---

## Phase R4 — Private beta (1–2 weeks calendar time, low effort)

### R4.1 Recruit 1–3 beta users

Ideal profile: uses nvim daily, uses (or wants to use) marimo, is not you.
The marimo Discord and r/neovim lurkers are realistic sources; even one
person on a different terminal/OS/python setup will find a class of bugs
the author structurally cannot (path assumptions, missing nerd fonts,
non-ghostty terminals, conda instead of pyenv).

### R4.2 Issue template with diagnostics

`.github/ISSUE_TEMPLATE/bug_report.md` asking for: nvim version, marimo
version, terminal, `:checkhealth neo-marimo` output, and — for sync/cell
bugs — `:MarimoCheck` output and a `:MarimoWsDebug` log snippet. The
debugging commands already exist; the template just teaches reporters to
use them, turning "it broke" reports into fixable ones.

### R4.3 Feedback cycle

Beta bugs get the established treatment: reproduce → regression test (in
`editing_spec.lua` if it's a cell-tracking bug) → small fix commit →
CHANGELOG line. Resist feature requests during beta; log them in
TOCHANGE.md.

**Exit criterion:** every beta-reported bug fixed or consciously
wont-fixed, and one beta user confirms a full real work session with no
issues.

---

## Phase R5 — Announce (~half a session, then ongoing triage)

### R5.1 Channels, in order

1. **marimo community** (Discord / GitHub discussions) — the highest-signal
   audience; people who already want exactly this.
2. **r/neovim** — standard plugin-announcement post: screenshot/GIF first,
   short feature list, link.
3. **awesome-neovim** PR and dotfyle listing for long-tail discovery.

### R5.2 Post-launch posture

- Triage new issues within a few days (a dead-looking repo kills adoption
  faster than bugs do); fixing them can batch weekly.
- Hold the line from the top of this doc: stability reports outrank feature
  requests. The feature roadmap stays `plan-phases-7-15.md` (phases 9
  remainder, 10, 11, 13, 15) and resumes only once the release is quiet.

**Verification:** the announcement post is live, the first outside issue
arrives with usable diagnostics, and responding to it doesn't require any
process invented on the spot.

---

## Definition of done

- [ ] LICENSE in repo, visible on GitHub.
- [ ] TOCHANGE/plan docs contain no claims the code contradicts.
- [ ] `examples/demo.py` committed; README has a real screenshot.
- [ ] Clean-machine install verified for lazy.nvim and vim.pack.
- [ ] v0.1.0 tagged; CHANGELOG.md exists.
- [ ] Issue template with diagnostics in place.
- [ ] ≥1 beta user completed a real work session without filing anything.
- [ ] Announcement posted.
