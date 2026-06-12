# neo-marimo development tasks

NVIM ?= nvim
PYTHON ?= ~/.pyenv/versions/3.12.10/envs/MyMainTestingPython/bin/python

# Where vim.pack loads the plugin from. `make dev-link` swaps the installed
# clone for a symlink to this working copy so edits go live on the next nvim
# restart — no commit/push/pull round trip. `make dev-unlink` restores the
# previous clone (preserved at $(PACK_DIR).pre-dev-link).
PACK_DIR ?= $(HOME)/.local/share/nvim/site/pack/core/opt/neo-marimo

.PHONY: test fixtures dev-link dev-unlink

# NEO_MARIMO_TEST_PYTHON gates the python-dependent specs (bridge round-trip);
# they self-skip when the interpreter is missing or has no marimo, so the rest
# of the suite runs anywhere (including CI before marimo is installed).
test:
	NEO_MARIMO_TEST_PYTHON=$(PYTHON) $(NVIM) -l tests/run.lua $(FILTER)

# Re-capture the marimo HTML fixture corpus (needs a marimo-equipped python).
fixtures:
	$(PYTHON) tests/capture_fixtures.py

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
