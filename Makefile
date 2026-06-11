# neo-marimo development tasks

NVIM ?= nvim
PYTHON ?= ~/.pyenv/versions/3.12.10/envs/MyMainTestingPython/bin/python

.PHONY: test fixtures

test:
	$(NVIM) -l tests/run.lua $(FILTER)

# Re-capture the marimo HTML fixture corpus (needs a marimo-equipped python).
fixtures:
	$(PYTHON) tests/capture_fixtures.py
