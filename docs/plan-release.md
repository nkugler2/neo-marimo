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
> interrupt/restart).
> **Revised:** 2026-06-22, folding in the full codebase-analysis review
> (correctness blockers in the default config, contributor-onboarding gaps,
> code-quality gates, maintainability notes). This plan now covers everything
> between "works on my machine, tests are green" and "strangers can install,
> use, *contribute to*, and report bugs against it."
> **Preceded by:** [`plan-phases-7-15.md`](plan-phases-7-15.md) (feature
> parity) and [`plan-phases-9-12-detail.md`](plan-phases-9-12-detail.md)
> (rendering/UX/docs).

The guiding rule for this plan: **nothing here adds features.** Every item
is either a correctness blocker, legal/packaging table stakes, contributor
infrastructure, first-run polish, or feedback infrastructure. If a feature
gap surfaces during beta, it goes into `TOCHANGE.md` and waits its turn —
the release bar is "what exists works flawlessly," not "everything exists."

## Why two new goals this revision

The original plan optimised for **strangers can install and use it**. The
2026-06-22 analysis confirmed the code itself is strong (a cleanly-grouped
module map, four documented extension registries, defensive async I/O,
golden-fixture tests across marimo 0.19 + 0.23) — so the risk is not the
code, it's (a) a handful of **release blockers that make it broken on every
machine but the author's**, and (b) the absence of **contributor on-ramps**.
This revision adds:

- **Phase R0** — the correctness blockers (the default config points at the
  author's home directory; personal paths leak into user-facing messages).
  These come first because today a fresh install is broken out of the box.
- **Phase R2 (code-quality gates)** and **Phase R3 (contributor onboarding)**
  — the new goal is "an open-source project people *want to work on*," and
  that needs a formatter/linter gate and a CONTRIBUTING guide *before* the
  first PR arrives.

## Phase map (roll out and test in order)

| Phase | Theme | Blocks release? | Rough size |
| --- | --- | --- | --- |
| R0 | Critical correctness blockers | **Yes** | ~30 min |
| R1 | Legal & repo hygiene | **Yes** | ~half a session |
| R2 | Code-quality gates (format/lint + CI) | **Yes** (do before PRs) | ~half a session |
| R3 | Contributor onboarding docs | **Yes** (for the contribute goal) | ~1 session |
| R4 | First-run experience | **Yes** | ~1 session |
| R5 | Versioning & releases | **Yes** | ~half a session |
| R6 | Private beta | Gate, not work | 1–2 weeks calendar |
| R7 | Announce | No | ~half a session + triage |

Each phase ends with a concrete **Verification** gate. Do not start the next
phase until the current one's verification passes — that's what makes this
safe to roll out incrementally.

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

## Phase R0 — Critical correctness blockers (~30 min)

> **New in this revision.** These are not hygiene — the plugin is genuinely
> broken for anyone but the author until they're fixed. Do these first; they
> unblock every later phase (you can't run a clean-machine install test in R4
> while the defaults point at a path that exists on no other machine).

### R0.1 Restore sane default `python_path` / `marimo_cmd`

`lua/neo-marimo/config.lua:10-11` currently ships the author's personal
interpreter paths as the **defaults**, with the correct generic defaults
commented out directly above them:

```lua
python_path = "/Users/noahkugler/.pyenv/versions/MarimoLatest/bin/python",
marimo_cmd  = "/Users/noahkugler/.pyenv/versions/MarimoLatest/bin/marimo",
```

Every user who installs the plugin and does *not* set `python_path` — which
the README explicitly says is optional — gets a plugin that execs a path
present on no machine but the author's. This also **contradicts the README**
(`README.md:110-114` documents `python_path = "python3"` as the default).

- [ ] Restore `python_path = "python3"` and `marimo_cmd = "marimo"` as the
      committed defaults; delete the personal-path lines and the now-stale
      "### This was the original value…" comments.
- [ ] **Author follow-up (do not skip):** because nvim loads this plugin
      straight from the dev repo (rtp `:prepend`), restoring the generic
      defaults will break the author's own setup unless the personal paths
      move into the author's *own* `require("neo-marimo").setup{ python_path
      = "…" }` in their dotfiles. Make that change in the dotfiles in the
      same sitting so local use keeps working.

### R0.2 Remove personal paths from user-facing and tooling defaults

The author's username leaks into output strangers will see, and into
dev-tooling defaults:

- [ ] `lua/neo-marimo/health.lua:57` — the `:checkhealth` "Example:" line
      hardcodes `/Users/noahkugler/.pyenv/.../bin/python`. Replace with a
      generic `'/path/to/venv/bin/python'`. (`:checkhealth` is the first
      thing a confused new user runs.)
- [ ] `Makefile:4` — `PYTHON ?= ~/.pyenv/.../MyMainTestingPython/bin/python`.
      Keep the `?=` override but genericise the fallback (e.g. `python3`) so
      `make test` works on a contributor's machine without editing the
      Makefile.
- [ ] `tests/capture_fixtures.py:10` — same personal path in the usage
      docstring; genericise.

### Verification — R0

- [ ] `git grep -n "noahkugler\|MarimoLatest\|MyMainTestingPython" -- lua/ python/ Makefile tests/` returns nothing.
- [ ] On a machine (or `NVIM_APPNAME` sandbox) where only `python3` + `marimo`
      are on PATH, opening a marimo `.py` with **no `setup()` call** attaches
      and parses cleanly.
- [ ] Author's own nvim still works after moving personal paths into dotfiles.

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

1. The "Integrated" list claims _"Database connections for SQL cells
   (Phase 10 in plan-phases-7-15.md)"_ is done. **It is not** — there is no
   `:MarimoSqlConnect`, no `cell.sql_engine` anywhere in the code. The
   shipped "Phase 10" was the _detail plan's_ phase 10 (widget UX). Move the
   DB item back to Open (or leave it to the feature roadmap).
2. Open item #1 says Phase 8 rich output is _"currently a NOT DONE item"_ —
   Phase 8 shipped 2026-06-05. Delete the item.

While there: add a one-line warning at the top of both plan docs noting the
numbering collision, so future bookkeeping doesn't repeat this.

### R1.4 History scrub check

`notebooks/` and `invest-data/` are gitignored now, but confirm nothing
personal was committed _before_ the ignore rules landed:

```sh
git log --all --diff-filter=A --name-only -- 'notebooks/*' 'invest-data/*'
```

If anything sensitive ever landed, decide between history rewrite (before
the repo gets traffic is the only cheap time) or accepting it. Also skim
`MYNOTES.md` — it ships with the repo (R3.2 folds it in and deletes it).

### R1.5 Gitignore local tooling artifacts

> **New in this revision.** `.understand-anything/` (including a
> `.trash-*/` subdir) and `.claude/` are currently untracked but sitting in
> the working tree; one stray `git add .` commits them.

- [ ] Add `.understand-anything/` and `.claude/` to `.gitignore` (keep
      `.claude/` ignored unless you deliberately want to share project
      settings — if so, commit only a curated `.claude/settings.json` and
      ignore the rest).
- [ ] Confirm no `__pycache__`, `.pyc`, or `.DS_Store` are tracked
      (`git ls-files | grep -E 'pyc$|__pycache__|DS_Store'` should be empty —
      currently clean; keep it that way).

### R1.6 Reconcile the tag scheme

> **New in this revision.** An existing tag `v0.1.0-marimo-0.19` is in the
> repo, but R5.1 plans a clean `v0.1.0`.

- [ ] Decide on one convention. Recommended: plain semver tags (`v0.1.0`),
      with the supported marimo range stated in the **release notes**, not
      baked into the tag. Delete or supersede `v0.1.0-marimo-0.19` so users
      don't pin to a confusing tag name.

**Verification:** fresh clone shows LICENSE; `git status` clean; TOCHANGE
contains no claim the code contradicts; `.understand-anything/` and
`.claude/` are ignored; `git tag` shows a coherent scheme.

---

## Phase R2 — Code-quality gates for contributors (~half a session)

> **New in this revision.** The new goal is "a project people want to *work
> on*." That needs an enforced, mechanical style so PRs are reviewable for
> *logic*, not whitespace — and it needs to land **before** the first
> outside PR, because the one-time "format the whole tree" commit is far
> cheaper before there are open branches to rebase. ~9,700 lines of Lua with
> no formatter config today.

### R2.1 Add a StyLua config and format the tree once

- [ ] Add `.stylua.toml` (pick a width/indent matching the current code —
      it's already 2-space indent; `column_width = 100` is a safe default).
- [ ] Run `stylua lua/ tests/` once and commit the result as a single,
      clearly-labelled `style: apply stylua` commit (so `git blame` damage is
      contained to one reviewable commit).

### R2.2 Add a Luacheck config

- [ ] Add `.luacheckrc` declaring `vim` as a read global and the test
      harness globals, ignoring the conventional noise. Fix anything real it
      surfaces (unused locals, shadowing, accidental globals).

### R2.3 Add a CI lint job

- [ ] Extend `.github/workflows/test.yml` with a `lint` job (or a step) that
      runs `stylua --check` and `luacheck`. Make it required alongside the
      test matrix. Keep `fail-fast: false` so a style failure still reports
      test results.

**Why it benefits contributors:** a contributor can run `make lint` (add the
target) locally, get the same verdict CI will give, and submit a PR that
needs no style back-and-forth. This is table stakes for telescope/lazy-class
plugins and reviewers will expect it.

**Verification:** `stylua --check lua/ tests/` and `luacheck lua/` both pass
locally and in CI; the CI badge/required-checks include lint.

---

## Phase R3 — Contributor onboarding docs (~1 session)

> **New in this revision.** You have excellent *architecture* docs but
> nothing that tells a would-be contributor **how to participate**. This is
> the single highest-leverage phase for the "people want to contribute" goal.

### R3.1 CONTRIBUTING.md

Pull together what's currently scattered across README, `MYNOTES.md`, and
tribal knowledge into one entry point:

- [ ] **Dev loop:** `make dev-link` / `make dev-unlink` (local edits go live
      on nvim restart, no commit/push), and the rtp-prepend dev install.
- [ ] **Running tests:** `make test`, the filter arg (`nvim -l tests/run.lua
      html`), and how the marimo-gated specs self-skip
      (`NEO_MARIMO_TEST_PYTHON` / the `PYTHON` make var).
- [ ] **The fixture system:** golden `_repr_html_()` captures under
      `tests/fixtures/<series>/`, when to run `make fixtures`, and that
      adopting a new marimo series means re-capture + update
      `health.lua`'s `TESTED_MARIMO_SERIES`.
- [ ] **The extension model:** the four registries
      (`register_output_renderer`, `register_widget_renderer`,
      `register_ws_handler`, `register_cell_detector`) with a pointer to the
      worked examples in `docs/architecture.md`. This is *the* contribution
      surface — make it obvious.
- [ ] **Style & PR expectations:** run `make lint` (R2), keep the "why"
      comments (see R3.4), one logical change per PR, add a regression test
      for bug fixes (`editing_spec.lua` for cell-tracking, the right
      `*_spec.lua` otherwise), CHANGELOG line under `## Unreleased`.
- [ ] **Debugging:** `:MarimoWsDebug`, `:MarimoCheck`, `:MarimoInspectOutput`,
      `:MarimoServerList`.

### R3.2 Reorganize `docs/` for newcomers, not just the author

Today `docs/` mixes a live roadmap, four overlapping phased plans with a
known phase-number collision, forensic bug writeups, and personal scratch.
An outside contributor can't tell what's current.

- [ ] Create a clean forward-looking `ROADMAP.md` (or `docs/roadmap.md`) that
      states what's planned next, derived from `plan-phases-7-15.md`'s
      remaining phases — without the historical implementation detail.
- [ ] Move the completed phased plans (`plan-phases-1-3`, `4-6`,
      `7-15`, `9-12-detail`) and `log-phase-4-issues.md` under
      `docs/history/` and add a one-line README there: "historical
      implementation logs; the live roadmap is ROADMAP.md."
- [ ] Fold the still-useful half of `MYNOTES.md` (the WS-debug workflow, the
      vim.pack update note) into CONTRIBUTING / the README dev section, then
      **delete `MYNOTES.md`** so personal scratch doesn't ship.
- [ ] Keep `TOCHANGE.md` as the backlog, but ensure it's reconciled (R1.3).

### R3.3 Issue + PR templates

> Pulls R4.2 (original) forward and adds a PR template, since both are
> contributor-onboarding surfaces.

- [ ] `.github/ISSUE_TEMPLATE/bug_report.md` asking for: nvim version, marimo
      version, terminal, `:checkhealth neo-marimo` output, and — for
      sync/cell bugs — `:MarimoCheck` output and a `:MarimoWsDebug` log
      snippet. The debugging commands already exist; the template teaches
      reporters to use them, turning "it broke" into a fixable report.
- [ ] `.github/ISSUE_TEMPLATE/feature_request.md` (brief).
- [ ] `.github/PULL_REQUEST_TEMPLATE.md` — checkboxes for `make lint` /
      `make test` green, CHANGELOG line added, regression test for bug fixes.

### R3.4 Maintainer notes (protect what's good)

The codebase's standout asset is its dense "why" comments (the 1009
MESSAGE_TOO_BIG fix in `ws_client.py`, the chunked-stdout reassembly and
port-conflict identity check in `server.lua`, the single-EDIT-slot browser
handoff). Capture two rules in CONTRIBUTING so a future cleanup doesn't
erode them:

- [ ] "Don't strip rationale comments — they encode hard-won bugs."
- [ ] "The plugin is intentionally single-instance: module-level state
      (`server._servers`, `init._attached`, `output._render_ctx`) is by
      design, not a bug to 'fix' into reentrancy."

**Verification:** a contributor who has never seen the repo can, using only
CONTRIBUTING.md, dev-link the plugin, run the tests, run the linters, and
find where to add a new output renderer — without asking you anything.

---

## Phase R4 — First-run experience (~1 session)

A stranger's first 10 minutes decide whether they file helpful bugs or
silently uninstall. Everything here targets that window.

### R4.1 Committed example notebook

The verification corpus (`notebooks/notebook.py`) is gitignored, so a fresh
clone has nothing to open. Add `examples/demo.py` — a sanitized notebook
exercising the renderer's breadth: `mo.md` headings/lists/code, a slider +
dependent cell, a small DataFrame, an hstack/tabs layout, a matplotlib
plot. This doubles as the manual smoke-test script for future releases.

### R4.2 README screenshot / GIF

The README has a placeholder comment at `README.md:8` (flagged in the detail
plan's Phase 12). Capture the notebook view rendering `examples/demo.py` —
one still screenshot minimum; a short GIF of run-cell → output appearing is
the high-impact version. Plugin adoption correlates embarrassingly strongly
with having a picture.

### R4.3 Clean-machine install walkthrough

Test the README install instructions in an isolated config (e.g.
`NVIM_APPNAME=nvim-test` with a minimal init.lua), for both lazy.nvim and
vim.pack paths:

1. Install plugin, no `setup()` call → open a marimo `.py` → does
   auto-attach work or fail with a clear message? (This now genuinely
   exercises the R0 default-config fix.)
2. `python_path` pointing at a marimo-less python → is the error actionable
   (it should name the config key and show an example)?
3. `:checkhealth neo-marimo` → every WARN/ERROR line tells the user what to
   _do_, not just what's wrong (and shows the generic example, not a
   personal path — verify R0.2).

Fix whatever this surfaces; it always surfaces something.

### R4.4 State the support matrix plainly (and make the sources agree)

> Augmented this revision: the support claims currently **disagree across
> four files** and must be reconciled to one truth.

The drift today:

- `README.md:48, 310` say "Tested against the marimo **0.19** series" /
  "(currently the 0.19 series)".
- `health.lua:9` actually tests **both 0.19 and 0.23**
  (`TESTED_MARIMO_SERIES = { ["0.19"] = true, ["0.23"] = true }`).
- `tests/fixtures/` has committed corpora for **both** 0.19 and 0.23.
- CI (`test.yml:38`) pins marimo to `0.19.*` only.

Resolve to one stated truth:

- [ ] Update README to say the supported/tested series are **0.19 and 0.23**
      (which matches `health.lua` and the fixtures).
- [ ] Add a `0.23.*` leg to the CI marimo install matrix so the bridge specs
      actually run against both supported series — otherwise "supported" is
      only fixture-deep.
- [ ] Add the terminal/image story: which emulators get inline images
      (kitty/ghostty/wezterm + image.nvim or snacks.image) and what everyone
      else gets (text placeholders — the plugin still works).
- [ ] Re-confirm nvim **0.11+** and `curl` on PATH.

**Verification:** a fresh `NVIM_APPNAME` config goes from zero to running
`examples/demo.py` cells using only the README; the marimo support claim is
identical in README, `health.lua`, and CI.

---

## Phase R5 — Versioning & releases (~half a session)

### R5.1 Tag v0.1.0

Users pin plugin versions (lazy.nvim `version =`, vim.pack tags). Tag the
release commit `v0.1.0` — semver-ish with 0.x signalling "API may still
move." The four registries documented in `docs/architecture.md` are the
public API; treat changes to them as breaking from here on. (See R1.6: use a
plain `v0.1.0`, not a marimo-suffixed tag.)

### R5.2 CHANGELOG.md

Keep-a-changelog format, one `## v0.1.0` section summarizing the feature
set at release (cells, sync, LSP, rich output, widgets, execution control).
From now on, user-visible changes get a line under `## Unreleased` in the
same commit that makes them. (The R3.3 PR template enforces this.)

### R5.3 Release procedure note

Five lines in CONTRIBUTING (or the README dev section): tests + lint green on
CI → update CHANGELOG → tag → push tag. Boring on purpose; it just has to be
written down so future-you doesn't improvise it.

**Verification:** `git tag` shows v0.1.0; installing by tag works.

---

## Phase R6 — Private beta (1–2 weeks calendar time, low effort)

### R6.1 Recruit 1–3 beta users

Ideal profile: uses nvim daily, uses (or wants to use) marimo, is not you.
The marimo Discord and r/neovim lurkers are realistic sources; even one
person on a different terminal/OS/python setup will find a class of bugs
the author structurally cannot (path assumptions, missing nerd fonts,
non-ghostty terminals, conda instead of pyenv). The R0 fixes are what make
this possible at all — before them, every beta user is dead on arrival.

### R6.2 Feedback cycle

Beta bugs get the established treatment: reproduce → regression test (in
`editing_spec.lua` if it's a cell-tracking bug) → small fix commit →
CHANGELOG line. The issue template (R3.3) turns "it broke" into a fixable
report. Resist feature requests during beta; log them in TOCHANGE.md.

**Exit criterion:** every beta-reported bug fixed or consciously
wont-fixed, and one beta user confirms a full real work session with no
issues.

---

## Phase R7 — Announce (~half a session, then ongoing triage)

### R7.1 Channels, in order

1. **marimo community** (Discord / GitHub discussions) — the highest-signal
   audience; people who already want exactly this.
2. **r/neovim** — standard plugin-announcement post: screenshot/GIF first,
   short feature list, link.
3. **awesome-neovim** PR and dotfyle listing for long-tail discovery.

### R7.2 Post-launch posture

- Triage new issues within a few days (a dead-looking repo kills adoption
  faster than bugs do); fixing them can batch weekly.
- Hold the line from the top of this doc: stability reports outrank feature
  requests. The feature roadmap stays `plan-phases-7-15.md` / `ROADMAP.md`
  (phases 9 remainder, 10, 11, 13, 15) and resumes only once the release is
  quiet.

**Verification:** the announcement post is live, the first outside issue
arrives with usable diagnostics, and responding to it doesn't require any
process invented on the spot.

---

## Definition of done

- [ ] **R0:** default config is `python3`/`marimo`; no personal path in any
      tracked file or user-facing message; clean-machine attach works with no
      `setup()`; author's dotfiles updated so local use still works.
- [ ] **R1:** LICENSE in repo, visible on GitHub; `git status` clean;
      TOCHANGE/plan docs contain no claims the code contradicts;
      `.understand-anything/` + `.claude/` ignored; coherent tag scheme.
- [ ] my note: may have to do `make dev-unlink` to unlink my dev environment
- [ ] **R2:** `.stylua.toml` + `.luacheckrc` committed; tree formatted; CI
      lint job required and green.
- [ ] **R3:** CONTRIBUTING.md exists and is end-to-end usable by a newcomer;
      `docs/` reorganized (ROADMAP + history); `MYNOTES.md` folded in and
      deleted; issue + PR templates in place.
- [ ] **R4:** `examples/demo.py` committed; README has a real screenshot;
      clean-machine install verified for lazy.nvim and vim.pack; marimo
      support claim consistent across README / health.lua / CI.
- [ ] **R5:** v0.1.0 tagged; CHANGELOG.md exists; release procedure written.
- [ ] **R6:** ≥1 beta user completed a real work session without filing
      anything.
- [ ] **R7:** Announcement posted.

---

## Appendix A — Deferred maintainability notes (NOT release-blocking)

Captured from the 2026-06-22 analysis so they aren't lost, but explicitly
**out of scope for v0.1.0** — churn for its own sake adds risk and destroys
`git blame`. Revisit only when the relevant module next needs changes.

- **`server.lua` is 1,028 lines** and cleanly contains four separable
  concerns: process lifecycle (start/stop/kill), the HTTP client
  (`http_get`/`http_post*`), WS connection management
  (connect/release/reclaim/resync), and introspection
  (`list_servers`/`kill_all`). If it grows further, split into
  `server/process.lua`, `server/http.lua`, `server/ws.lua` to lower the
  barrier for someone touching just one concern. The dense comments mitigate
  the size today.
- **Other large modules** (`lsp.lua` 728, `output.lua` 696, `widgets.lua`
  629, `dataframe.lua` 593; 22 of 46 files flagged "complex" by the
  understand-anything analysis) are coherent and well-commented. No action
  now; watch them if a contributor reports difficulty navigating one.
- **Per-parse subprocess cost:** `python/bridge.py` spawns a fresh Python
  per parse/generate. Fine for correctness and current scale; only revisit
  if profiling on large notebooks shows it as a real cost.
