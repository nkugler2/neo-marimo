-- neo-marimo tmux visual screen test: nvim -u init (T5, docs/plan-testing.md).
--
-- Launched by tests/screen/run.lua inside a private-socket tmux session, one
-- process per screen. Reaches the rendered state the SAME way T2's replay
-- spec layer does — t.make_notebook + t.replay against a committed WS
-- transcript (tests/transcripts/<version>/*.jsonl) — rather than re-deriving
-- marimo's kernel choreography a third time (T1's own deviation note
-- explains why that would duplicate already-battle-tested code): no python,
-- no kernel, deterministic in milliseconds. The one thing this layer adds
-- over T2 is that it's a REAL, non-headless nvim (`nvim -u`, not `nvim -l`)
-- inside a real tmux pane — what ends up on screen is whatever nvim's actual
-- TUI compositor draws, not a serialized extmark dump.
--
-- Env vars (set by tests/screen/run.lua, mirroring demo_init.lua's
-- NEO_MARIMO_DEMO_SCENARIO convention):
--   NEO_MARIMO_SCREEN_SCENARIO      -- tests/scenarios/<name>.py to build+replay
--   NEO_MARIMO_SCREEN_UNTIL_ACTION  -- optional: t.replay's opts.until_action,
--                                       for an intermediate state (e.g.
--                                       edit_rerun's "edited, not yet rerun").

local this = debug.getinfo(1, "S").source:sub(2)
-- This file lives at <root>/tests/screen/init.lua — three :h's to the root,
-- unlike tests/run.lua's two (it lives one level up, directly under tests/).
local root = vim.fn.fnamemodify(this, ":h:h:h")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

-- A bare `-u` config doesn't turn these on by itself; without them the
-- notebook's embedded python (inside cell borders) would show no syntax
-- highlighting. Moot for the default capture mode (tmux capture-pane -p
-- strips color/attributes for determinism — see run.lua), but kept so a
-- human can also run this by hand (NEO_MARIMO_SCREEN_KEEP_OPEN, see below)
-- and see a real session, not a monochrome one.
vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")

-- Declutter the capture down to buffer content: the statusline would
-- otherwise add deterministic-but-noisy text (buffer name, ruler position)
-- that has nothing to do with what this layer exists to catch (box border /
-- column math, T5's own stated goal) and just makes every golden harder to
-- read.
--
-- Residual risk, accepted deliberately: the replay path still echoes short
-- status messages ("[neo-marimo] WebSocket connected." — visible as every
-- golden's last line). If a future replay path ever emits a message long
-- enough to trigger hit-enter ("Press ENTER..."), the pane freezes on that
-- prompt, run.lua's wait_stable happily calls the frozen frame "stable",
-- and the failure shows up as a confusing snapshot mismatch rather than its
-- cause. If that happens: raise cmdheight here or suppress vim.notify in
-- this harness — don't chase the diff.
vim.o.laststatus = 0
vim.o.ruler = false

-- The plugin never sets g.mapleader itself (real user config does). Set to a
-- known value so a screen that DOES need a leader keymap (tests/screen/run.lua
-- can send-keys to trigger one — none of the currently-committed screens do,
-- but keymaps.setup below wires the real production keymaps regardless of
-- whether this run's screen happens to press one) has something predictable
-- to type, not nvim's unconfigured default ("\").
vim.g.mapleader = " "

require("neo-marimo").setup({})

local t = require("helpers")
t.root = root

local scenario = os.getenv("NEO_MARIMO_SCREEN_SCENARIO")
assert(scenario and scenario ~= "", "NEO_MARIMO_SCREEN_SCENARIO not set")

local until_action = tonumber(os.getenv("NEO_MARIMO_SCREEN_UNTIL_ACTION") or "")

local buffer = require("neo-marimo.buffer")

local nb, bufnr = t.make_notebook(t.scenario_codes(scenario))

-- Full production keymap set (t.make_notebook only wires the editing-keymap
-- subset, per its own doc comment) — a future screen that needs a real
-- leader keymap (e.g. <leader>mD, the dataframe side panel) can send-keys
-- for it (see run.lua), and this is the exact call site M.attach itself
-- makes right after switching the window to the notebook buffer.
require("neo-marimo.keymaps").setup(bufnr, nb)

-- buffer.create() (called inside t.make_notebook) renders cell borders
-- before this buffer is shown in any window (win_findbuf finds nothing yet),
-- so M.border_width falls back to a default instead of this session's real
-- 100-column pane — mirroring M.attach's own comment ("Borders rendered
-- inside buffer.create() used the fallback width because the buffer wasn't
-- in a window yet") and its fix: re-render now that nvim_set_current_buf
-- (inside t.make_notebook) has put the buffer in this window for real.
-- Output rendering doesn't need the same treatment: it only happens later,
-- during t.replay's dispatch below, by which point the buffer IS current.
buffer.apply_window_settings(vim.api.nvim_get_current_win())
buffer.render_all_borders(bufnr, nb)

t.replay(scenario, nb, bufnr, until_action and { until_action = until_action } or nil)

-- Deterministic starting scroll/cursor position — otherwise which part of a
-- taller notebook lands in the first 30 lines depends on wherever the
-- cursor happened to end up (make_notebook doesn't move it; replay doesn't
-- either), which would make the capture depend on the exact code path taken
-- to get here rather than the scenario content.
--
-- A plain `gg` (or nvim_win_set_cursor + nothing else) is NOT enough, and
-- this is a real T5 finding worth recording (docs/plan-testing.md): Neovim
-- does not reserve display space for an extmark's virt_lines_above when the
-- anchor row becomes the window's topline via a hard jump (gg/zt, or the
-- window's very first paint after nvim_win_set_buf) — verified with a
-- minimal extmark repro, and independently against a REAL M.attach flow
-- (parser + buffer + borders, no test harness involved): a notebook's first
-- cell's TOP border is invisible the instant a real user opens ANY notebook,
-- every time, until something scrolls the window. It reappears correctly
-- the moment the view scrolls THROUGH that row incrementally (verified:
-- `G` then repeated Ctrl-Y, which is exactly what the two lines below do)
-- rather than jumping straight to it — Neovim's incremental-scroll path
-- recomputes topfill (the extra display rows virt_lines_above need)
-- correctly; a hard topline jump doesn't. This is a Neovim/extmark
-- rendering characteristic, not something t.make_notebook, t.replay, or
-- neo-marimo's own border code got wrong, and out of scope to patch here
-- (T5 is test infrastructure) — flagged for the maintainer in TOCHANGE.md.
-- Reproducing the SAME "settle" scroll here (rather than special-casing
-- gg away) is what makes these screens show the fully-painted state a real
-- user sees after their first scroll, instead of a misleading, momentary
-- first-paint artifact that would otherwise show up as a "broken" top
-- border on every single screen in this suite.
vim.cmd("normal! G")
vim.cmd("normal! " .. string.rep("\25", 300)) -- Ctrl-Y (scroll up), far more than any scenario needs

-- Script ends here; nvim now sits idle at the interactive prompt showing the
-- replayed buffer, exactly what run.lua's tmux session needs for
-- send-keys/capture-pane. run.lua owns tearing this process down (killing
-- the tmux session); see its NEO_MARIMO_SCREEN_KEEP_OPEN for attaching to a
-- live session by hand instead.
