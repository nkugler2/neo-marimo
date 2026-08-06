# neo-marimo development tasks

NVIM ?= nvim
PYTHON ?= ~/.pyenv/versions/3.12.10/envs/MyMainTestingPython/bin/python
# `make demo`'s default scenario (tests/scenarios/*.py). Override per-run:
# `make demo SCENARIO=widgets`.
SCENARIO ?= basic_run

# Where vim.pack loads the plugin from. `make dev-link` swaps the installed
# clone for a symlink to this working copy so edits go live on the next nvim
# restart — no commit/push/pull round trip. `make dev-unlink` restores the
# previous clone (preserved at $(PACK_DIR).pre-dev-link).
PACK_DIR ?= $(HOME)/.local/share/nvim/site/pack/core/opt/neo-marimo

.PHONY: test test-e2e snapshots fixtures transcripts corpus-add demo dev-link dev-unlink

# FILTER is the ergonomic, user-facing override (`make test FILTER=foo`).
# It is deliberately NOT referenced as `$(FILTER)`/`"$(FILTER)"` inside any
# recipe's shell command text below — splicing a make variable's expanded
# text into a recipe line and handing it to a shell is exploitable: a value
# containing a backtick (or `$(...)`) is executed as command substitution by
# the recipe's shell even inside double quotes (verified empirically: `make
# snapshots FILTER='probe `touch /tmp/pwned` end'` really did run `touch`).
# Real case names hit exactly this — see tests/helpers.lua's accept_command,
# which prints `make snapshots FILTER=...` for a failing snapshot's own
# t.case name, and snapshot_spec.lua has a case name containing backticks.
#
# Fix: `export ... = $(FILTER)` below computes FILTER's value and places it
# directly into each recipe's process environment (execve's envp) — which a
# shell never re-parses for word-splitting/globbing/command-substitution —
# instead of splicing it into recipe text. tests/run.lua and
# tests/record_transcripts.lua read it from there (NEO_MARIMO_TEST_FILTER,
# namespaced so it can't collide with an unrelated ambient $FILTER) as a
# fallback when no positional CLI arg was given, so direct invocations
# (`nvim -l tests/run.lua html`) are unaffected. One residual limitation,
# inherent to make's own command-line variable handling (not shell-related):
# make expands `$` inside a command-line-set variable's value whenever it
# computes that value (both the vulnerable $(FILTER)-in-text form above AND
# this export form) — a case name containing a literal `$` needs it typed as
# `$$` to survive; accept_command escapes it for exactly this reason. No
# current case name contains `$`; documented here rather than solved by a
# heavier passing mechanism (T4, docs/plan-testing.md).
export NEO_MARIMO_TEST_FILTER = $(FILTER)

# CORPUS/URL/NAME (the T7 corpus knobs below) are exported for the same
# reason as FILTER above — their Lua consumers already read os.getenv, so
# splicing `$(CORPUS)`/`$(URL)` into recipe text would reopen the exact
# backtick/command-substitution hole the export mechanism exists to close
# (URL especially: it's arbitrary user-supplied text by design).
CORPUS ?=
URL ?=
NAME ?=
export CORPUS
export URL
export NAME

# NEO_MARIMO_TEST_PYTHON gates the python-dependent specs (bridge round-trip,
# e2e); they self-skip when the interpreter is missing or has no marimo, so
# the rest of the suite runs anywhere (including CI before marimo is
# installed).
test:
	NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -l tests/run.lua

# Just the gated E2E smoke tests (T3, tests/spec/e2e_spec.lua) against a real
# marimo kernel — for iterating on them without re-running the whole suite.
# Self-skips the same way `make test` does if PYTHON has no marimo. Filters
# on the "e2e:" case-name prefix (run.lua's own FILTER is a case-name
# substring match, not a file-name match) — every case in e2e_spec.lua uses
# it and nothing else in the suite does. "e2e:" is a fixed literal (not user
# input), so passing it positionally here is fine.
test-e2e:
	NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -l tests/run.lua "e2e:"

# Regenerate snapshot goldens (tests/helpers.lua's t.snapshot, T0): same run
# as `make test`, but a missing/mismatched golden under tests/snapshots/ gets
# written instead of failing. Re-run twice with no other changes to sanity
# check determinism (the second run should be a no-op / `git diff` clean).
# FILTER: see the comment above `export NEO_MARIMO_TEST_FILTER` — this is the
# exact recipe shape a failing snapshot's own error message tells you to run.
snapshots:
	NEO_MARIMO_UPDATE_SNAPSHOTS=1 NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -l tests/run.lua

# Re-capture the marimo HTML fixture corpus (needs a marimo-equipped python).
fixtures:
	$(PYTHON) tests/capture_fixtures.py

# Re-record the WS session transcripts (tests/scenarios/*.py -> real marimo
# kernel -> tests/transcripts/<major.minor>/*.jsonl, T1). Needs the same
# marimo-equipped python as `make fixtures`; a sibling `marimo` binary must
# exist next to it (see tests/record_transcripts.lua for why python_path and
# marimo_cmd have to come from the same env here). FILTER selects scenarios
# by name, e.g. `make transcripts FILTER=widgets` (space-separated for more
# than one, e.g. `FILTER="widgets basic_run"` — see the export comment above
# for why this isn't passed as a positional recipe argument).
#
# CORPUS=<name> records a T7 corpus notebook (tests/corpus/<name>.py)
# instead: `make transcripts CORPUS=widgets_code_editor`. Output goes to
# tests/corpus/transcripts/<major.minor>/ (gitignored — corpus-level
# transcript determinism isn't guaranteed the way the curated FILTER=
# scenarios above are; see docs/plan-testing.md T7's "Known risk"
# paragraph), and a notebook whose imports this python doesn't have is
# skipped with a notice rather than erroring. CORPUS reaches the script via
# the export block above, like FILTER.
transcripts:
	NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -l tests/record_transcripts.lua

# `make corpus-add URL=<raw-github-url> [NAME=<name>]` (T7): curl-fetches a
# notebook into tests/corpus/<name>.py and appends a default (exploratory)
# tests/corpus/manifest.lua entry with the source URL recorded — the
# drop-in-a-real-notebook workflow, from the command line. NAME defaults to
# the URL's own filename. URL may be any curl-understood scheme, including
# file:// (tests/spec/corpus_add_spec.lua exercises exactly that, so this
# target's own correctness is covered by `make test` without network access).
# URL/NAME reach the script via the export block above, like FILTER.
corpus-add:
	$(NVIM) -l tests/corpus_add.lua

# One-command manual-testing session (T4): a REAL (not headless) nvim,
# attached and ready against SCENARIO's notebook (tests/scenarios/*.py,
# default basic_run), identical every run. Deliberately does NOT depend on
# `make dev-link` — tests/demo_init.lua is a minimal `-u` config (not the
# caller's real init.lua) that prepends this working copy onto 'runtimepath'
# itself, the same rtp-prepend idea tests/run.lua uses for headless specs,
# so the demo never touches (or requires) the installed pack/opt clone.
# The scenario file is copied to a throwaway temp dir first (inside
# demo_init.lua, mirroring tests/spec/e2e_spec.lua's copy_scenario) so demo
# edits never dirty the repo. Kernel comes from NEO_MARIMO_TEST_PYTHON (same
# default as `make test`/`make transcripts`) via config.setup, not the
# maintainer's personal config.lua default.
# SCENARIO is exported (not `$(SCENARIO)` spliced into the recipe) for the
# same reason as `export NEO_MARIMO_TEST_FILTER` above — tests/demo_init.lua
# already only reads it via os.getenv, so this was a Makefile-only change.
# NVIM_ARGS IS spliced positionally (it's nvim flags, e.g. `+qa`, meant to be
# parsed as shell-quoted words by design — an escape hatch for driving this
# non-interactively, e.g. `make demo NVIM_ARGS='+qa'` to smoke-test the
# launch path and exit); it is the one place in this Makefile where that's
# the intended behavior rather than a footgun, since it's local developer
# input, not a value that flows through any printed/copy-pasted message.
export NEO_MARIMO_DEMO_SCENARIO = $(SCENARIO)
demo:
	NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -u tests/demo_init.lua $(NVIM_ARGS)

dev-link:
	@if [ -e "$(PACK_DIR)" ] && [ ! -L "$(PACK_DIR)" ]; then \
		mv "$(PACK_DIR)" "$(PACK_DIR).pre-dev-link"; \
		echo "moved existing install to $(PACK_DIR).pre-dev-link"; \
	fi
	@mkdir -p "$$(dirname "$(PACK_DIR)")"
	@ln -sfn "$(CURDIR)" "$(PACK_DIR)"
	@echo "linked $(PACK_DIR) -> $(CURDIR)"
	@echo "restart nvim to pick up changes; 'make dev-unlink' to undo"

dev-unlink:
	@if [ -L "$(PACK_DIR)" ]; then rm "$(PACK_DIR)"; fi
	@if [ -e "$(PACK_DIR).pre-dev-link" ]; then \
		mv "$(PACK_DIR).pre-dev-link" "$(PACK_DIR)"; \
		echo "restored previous install at $(PACK_DIR)"; \
	else \
		echo "no saved install to restore — re-clone with:"; \
		echo "  git clone https://github.com/nkugler2/neo-marimo \"$(PACK_DIR)\""; \
	fi
