# neo-marimo development tasks

NVIM ?= nvim
PYTHON ?= ~/.pyenv/versions/3.12.10/envs/MyMainTestingPython/bin/python

# Where vim.pack loads the plugin from. `make dev-link` swaps the installed
# clone for a symlink to this working copy so edits go live on the next nvim
# restart — no commit/push/pull round trip. `make dev-unlink` restores the
# previous clone (preserved at $(PACK_DIR).pre-dev-link).
PACK_DIR ?= $(HOME)/.local/share/nvim/site/pack/core/opt/neo-marimo

.PHONY: test test-e2e snapshots fixtures transcripts corpus-add dev-link dev-unlink

# NEO_MARIMO_TEST_PYTHON gates the python-dependent specs (bridge round-trip,
# e2e); they self-skip when the interpreter is missing or has no marimo, so
# the rest of the suite runs anywhere (including CI before marimo is
# installed).
test:
	NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -l tests/run.lua $(FILTER)

# Just the gated E2E smoke tests (T3, tests/spec/e2e_spec.lua) against a real
# marimo kernel — for iterating on them without re-running the whole suite.
# Self-skips the same way `make test` does if PYTHON has no marimo. Filters
# on the "e2e:" case-name prefix (run.lua's own FILTER is a case-name
# substring match, not a file-name match) — every case in e2e_spec.lua uses
# it and nothing else in the suite does.
test-e2e:
	NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -l tests/run.lua "e2e:"

# Regenerate snapshot goldens (tests/helpers.lua's t.snapshot, T0): same run
# as `make test`, but a missing/mismatched golden under tests/snapshots/ gets
# written instead of failing. Re-run twice with no other changes to sanity
# check determinism (the second run should be a no-op / `git diff` clean).
snapshots:
	NEO_MARIMO_UPDATE_SNAPSHOTS=1 NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -l tests/run.lua $(FILTER)

# Re-capture the marimo HTML fixture corpus (needs a marimo-equipped python).
fixtures:
	$(PYTHON) tests/capture_fixtures.py

# Re-record the WS session transcripts (tests/scenarios/*.py -> real marimo
# kernel -> tests/transcripts/<major.minor>/*.jsonl, T1). Needs the same
# marimo-equipped python as `make fixtures`; a sibling `marimo` binary must
# exist next to it (see tests/record_transcripts.lua for why python_path and
# marimo_cmd have to come from the same env here). FILTER selects scenarios
# by name, e.g. `make transcripts FILTER=widgets`.
#
# CORPUS=<name> records a T7 corpus notebook (tests/corpus/<name>.py)
# instead: `make transcripts CORPUS=widgets_code_editor`. Output goes to
# tests/corpus/transcripts/<major.minor>/ (gitignored — corpus-level
# transcript determinism isn't guaranteed the way the curated FILTER=
# scenarios above are; see docs/plan-testing.md T7's "Known risk"
# paragraph), and a notebook whose imports this python doesn't have is
# skipped with a notice rather than erroring.
CORPUS ?=
transcripts:
	NEO_MARIMO_TEST_PYTHON=$(PYTHON) CORPUS=$(CORPUS) $(NVIM) -l tests/record_transcripts.lua $(FILTER)

# `make corpus-add URL=<raw-github-url> [NAME=<name>]` (T7): curl-fetches a
# notebook into tests/corpus/<name>.py and appends a default (exploratory)
# tests/corpus/manifest.lua entry with the source URL recorded — the
# drop-in-a-real-notebook workflow, from the command line. NAME defaults to
# the URL's own filename. URL may be any curl-understood scheme, including
# file:// (tests/spec/corpus_add_spec.lua exercises exactly that, so this
# target's own correctness is covered by `make test` without network access).
URL ?=
NAME ?=
corpus-add:
	URL=$(URL) NAME=$(NAME) $(NVIM) -l tests/corpus_add.lua

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
