-- neo-marimo one-command manual demo session (T4, docs/plan-testing.md).
--
--   make demo [SCENARIO=widgets]
--
-- Launches a REAL (not headless) nvim, using this file as its ENTIRE user
-- config (`nvim -u tests/demo_init.lua`) rather than the caller's real
-- init.lua — so the session doesn't depend on `make dev-link` having swapped
-- the installed pack/opt clone, and doesn't pick up unrelated personal
-- plugins/settings that would make "identical every time" a lie. It:
--   1. prepends this working copy onto 'runtimepath', so plugin/neo-marimo.lua
--      (the real auto-attach entry point) loads from source, not an install;
--   2. points config.python_path/marimo_cmd at NEO_MARIMO_TEST_PYTHON instead
--      of config.lua's own default (the maintainer's personal pyenv env);
--   3. copies SCENARIO's notebook (tests/scenarios/*.py) to a throwaway temp
--      dir — same discipline as tests/spec/e2e_spec.lua's copy_scenario and
--      tests/record_transcripts.lua's — so demo edits never dirty the repo;
--   4. opens it (triggering the plugin's real BufReadPost auto-attach) and
--      starts the kernel nvim-only (no browser tab), so the session that
--      greets you is already attached AND running, not an empty notebook
--      waiting for <leader>ms.
--
-- NVIM_ARGS (Makefile) lets this be driven non-interactively for smoke
-- testing, e.g. `make demo NVIM_ARGS='+qa'`.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h")

-- Same rtp-prepend idea tests/run.lua uses for package.path in the headless
-- suite, just via 'runtimepath' here — plugin/neo-marimo.lua's autocmds/user
-- commands (unlike the plain lua/ modules helpers.lua `require`s directly)
-- only get wired up by nvim's normal plugin-loading walk of rtp.
--
-- Nvim's own automatic scan of 'runtimepath'/plugin/**/*.{vim,lua} runs
-- BEFORE a `-u FILE` is executed (verified empirically: prepending root here
-- and stopping did not create plugin/neo-marimo.lua's `NeoMarimo` augroup —
-- the automatic pass had already happened with the old rtp). This is the
-- same reason lazy-loading plugin managers (lazy.nvim, packer) explicitly
-- `:runtime` their managed plugins instead of relying on the automatic scan
-- — their own bootstrap IS the `-u`/init.lua execution, so they're in the
-- same boat this demo script is. `runtime!` (with `!`) sources from every
-- matching rtp entry, matching what the automatic scan itself would have done.
vim.opt.rtp:prepend(root)
vim.cmd("runtime! plugin/neo-marimo.lua")

-- A bare `-u` config doesn't turn these on by itself; without them the demo
-- notebook (a `python` filetype buffer, even though the notebook view itself
-- lives in a synthetic `marimo://` buffer) would show no syntax highlighting.
vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")

local function fail(msg)
  vim.notify("neo-marimo demo: " .. msg, vim.log.levels.ERROR)
end

-- Same env var and sibling-`marimo`-binary derivation as
-- tests/record_transcripts.lua / tests/spec/e2e_spec.lua — see either for
-- why python_path and marimo_cmd must come from the SAME env (config.lua's
-- own marimo_cmd default points at a different personal install and would
-- silently spawn a mismatched kernel).
local raw_python = os.getenv("NEO_MARIMO_TEST_PYTHON")
if not raw_python or raw_python == "" then
  fail("NEO_MARIMO_TEST_PYTHON is not set (see the Makefile's PYTHON default / `make demo`).")
  return
end
local python = vim.fn.expand(raw_python)
if vim.fn.executable(python) ~= 1 then
  fail("NEO_MARIMO_TEST_PYTHON (" .. python .. ") is not executable.")
  return
end
local marimo_cmd = vim.fn.fnamemodify(python, ":h") .. "/marimo"
if vim.fn.executable(marimo_cmd) ~= 1 then
  fail("no `marimo` executable next to " .. python .. " (looked for " .. marimo_cmd .. ").")
  return
end

require("neo-marimo").setup({ python_path = python, marimo_cmd = marimo_cmd })

local scenario = os.getenv("NEO_MARIMO_DEMO_SCENARIO")
if not scenario or scenario == "" then scenario = "basic_run" end
local src_path = root .. "/tests/scenarios/" .. scenario .. ".py"
if vim.fn.filereadable(src_path) ~= 1 then
  fail("unknown scenario '" .. scenario .. "' (no " .. src_path .. ")")
  return
end

local tmp_dir = vim.fn.tempname() .. "-demo"
vim.fn.mkdir(tmp_dir, "p")
local tmp_path = tmp_dir .. "/" .. scenario .. ".py"
vim.fn.writefile(vim.fn.readfile(src_path), tmp_path)

vim.cmd.edit(tmp_path)

-- plugin/neo-marimo.lua's BufReadPost callback defers the actual attach one
-- tick via vim.schedule (so filetype detection runs first) — poll instead of
-- assuming one schedule pass is enough, the same reasoning tests/helpers.lua's
-- H.drain gives, bounded so a bad python_path/parse failure degrades to a
-- plain, still-usable .py buffer instead of hanging nvim's startup.
local marimo = require("neo-marimo")
local attached = vim.wait(5000, function()
  return marimo.current_notebook() ~= nil
end, 20)

if not attached then
  fail("auto-attach did not complete for " .. tmp_path
    .. " — check :messages (parser errors show there), or try :MarimoAttach.")
  return
end

-- "attached and ready": start the kernel nvim-only (no browser tab — the
-- <leader>ms keymap's own action). server.start_headless's own instantiate
-- call defaults autoRun to true, so every cell runs without a further
-- explicit run_all — the session that greets you already shows real output.
local nb = marimo.current_notebook()
require("neo-marimo.actions").start_server(nb)
