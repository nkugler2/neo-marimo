-- neo-marimo tmux visual screen snapshots (T5, docs/plan-testing.md).
-- Optional, cuttable layer: 3-5 golden *screens* — what a real terminal
-- actually shows for the highest-value views — layered on top of T0's text
-- snapshot mechanics and T2's kernel-free replay layer.
--
--   make test-screen              # run every screen
--   make test-screen FILTER=error # narrow by screen name (same convention
--                                  # as `make test FILTER=`, see the Makefile)
--   NEO_MARIMO_UPDATE_SNAPSHOTS=1 make test-screen   # accept new goldens
--
-- Self-skips cleanly (exit 0) if tmux isn't on PATH — this is deliberately
-- NOT wired into tests/spec/*_spec.lua / `make test`'s glob (see the
-- Makefile's test-screen target comment for why): a nested real terminal
-- + tmux + a second real nvim process is a fundamentally more timing- and
-- environment-sensitive thing to assert on than headless replay, and this
-- phase's own acceptance bar is "prove 3 consecutive stable runs, or cut
-- it" — not "fold into the one-command suite unconditionally".
--
-- Each screen: reach a rendered state via tests/screen/init.lua (t.replay
-- against a committed transcript, kernel-free — see that file), inside a
-- tmux session on a PRIVATE socket (`-L`) so this never touches a real user
-- tmux session, poll `capture-pane -p` until two consecutive captures match
-- (never a fixed sleep — real nvim's own startup/redraw timing varies run to
-- run), then assert the captured text via the exact same t.snapshot t.case
-- specs use (tests/helpers.lua, T0) — same golden-diff-actual.txt-accept-env-var
-- flow, just fed text that came from a terminal instead of a serializer.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":h:h:h")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local t = require("helpers")
t.root = root

-- ── self-skip ────────────────────────────────────────────────────────────
--
-- NEO_MARIMO_TMUX_BIN lets a caller point at a specific tmux (this machine
-- keeps tmux 3.6b at /opt/homebrew/bin/tmux; plain "tmux" resolves the same
-- way as long as PATH already contains it, which is the common case) and
-- doubles as the "pretend tmux is absent" knob the T5 acceptance criteria
-- asks for (verify self-skip with PATH stripped of tmux, or this pointed at
-- a nonexistent path).
local tmux_bin = os.getenv("NEO_MARIMO_TMUX_BIN")
if not tmux_bin or tmux_bin == "" then tmux_bin = "tmux" end

if vim.fn.executable(tmux_bin) ~= 1 then
  io.write("[screen] tmux not found (looked for '" .. tmux_bin .. "') — skipping visual screen snapshots.\n")
  os.exit(0)
end

local nvim_bin = os.getenv("NEO_MARIMO_SCREEN_NVIM")
if not nvim_bin or nvim_bin == "" then nvim_bin = "nvim" end
if vim.fn.executable(nvim_bin) ~= 1 then
  io.write("[screen] '" .. nvim_bin .. "' is not executable — skipping visual screen snapshots.\n")
  os.exit(0)
end

-- Same filter convention as tests/run.lua: positional CLI arg wins, else
-- NEO_MARIMO_TEST_FILTER (the Makefile's export, not `$(FILTER)` spliced
-- into recipe text — see its comment for why that split matters for a value
-- containing shell metacharacters).
local filter = _G.arg and _G.arg[1] or nil
if not filter or filter == "" then
  local env_filter = os.getenv("NEO_MARIMO_TEST_FILTER")
  if env_filter and env_filter ~= "" then filter = env_filter end
end

local update = os.getenv("NEO_MARIMO_UPDATE_SNAPSHOTS") == "1"
-- Leaves the tmux session alive (skips kill-session) after a failing
-- capture, and prints the exact `tmux -L <socket> attach -t <session>`
-- command so a human can look at the same live session run.lua just drove
-- — the "debug a flaky/broken screen by hand" escape hatch.
local keep_open_on_failure = os.getenv("NEO_MARIMO_SCREEN_KEEP_OPEN") == "1"

-- ── screen definitions ───────────────────────────────────────────────────
--
-- One tmux socket, shared across every screen in this run (new session per
-- screen, killed right after that screen's capture) — cheaper than spinning
-- up a whole tmux server per screen, and `kill-server` in the top-level
-- cleanup below still guarantees nothing outlives this process even if a
-- screen errors partway through.
--
-- Mapping onto the 5 "highest-value views" T5 names (cell box + output
-- below / wrapped long output / widget glyph line / error styling /
-- dataframe view), using the 5 existing T1 transcripts:
--   basic_run   -> cell box + output below (the plain case; e414de6 gravity
--                  fix class)
--   widgets     -> widget glyph line (slider track)
--   error_cell  -> error styling AND wrapped long output in the same shot —
--                  a real marimo traceback IS both at once (long HTML lines
--                  hard-wrapped by output.lua's own wrap_virt_line pass,
--                  see replay-error_cell.txt), so forcing a 6th synthetic
--                  scenario just to isolate "wrapped" from "styled" would
--                  test something a user never actually sees on its own.
--   rich_output -> dataframe view (the boxed ASCII table; the image cell in
--                  the same scenario has no pixels to show without a real
--                  backend — out of scope per T5 build step 4 — so its box
--                  is just an empty ✓-ran line, which is still useful
--                  coverage of a box straddling a huge wrapped source cell).
--   edit_rerun  -> bonus 5th screen: the buffer showing edited code next to
--                  a not-yet-rerun (stale) output value, via until_action.
--                  Not one of the 4 named categories, but a real, distinct,
--                  cheap-to-reach visual state worth a golden — and every
--                  scenario transcript is already committed, so it costs
--                  nothing to include.
local SCREENS = {
  { name = "basic_run", scenario = "basic_run" },
  { name = "widgets", scenario = "widgets" },
  { name = "error_cell", scenario = "error_cell" },
  { name = "rich_output", scenario = "rich_output" },
  { name = "edit_rerun_mid", scenario = "edit_rerun", until_action = 2 },
}

-- ── tmux driving ─────────────────────────────────────────────────────────

local function tmux(socket, ...)
  return vim.system({ tmux_bin, "-L", socket, ... }, { text = true }):wait()
end

local function capture(socket, session)
  local res = tmux(socket, "capture-pane", "-p", "-t", session)
  if res.code ~= 0 then return nil, (res.stderr or "capture-pane failed") end
  return res.stdout
end

-- Poll capture-pane until THREE consecutive captures are byte-identical, or
-- give up after max_attempts. This is what makes the golden deterministic
-- without a guessed fixed sleep: a real nvim's startup + first-paint timing
-- genuinely varies run to run under load, but the FINAL painted frame
-- doesn't — and any future screen that DOES send-keys mid-flight (e.g. to
-- trigger a leader keymap) needs this same settle-before-capture treatment
-- for whatever redraw that interaction triggers.
--
-- Three matches, not two: polling starts right after `new-session -d`
-- returns, and on a loaded machine an intermediate frame (or an empty pane
-- before nvim's first paint) can plausibly survive one 150ms gap unchanged;
-- surviving two is much less likely. A false "stable" here degrades to an
-- ordinary snapshot mismatch, not silent corruption — the extra match is
-- cheap flake insurance, not correctness. Both knobs are env-overridable
-- for slower machines (no code edit needed to debug a timing failure).
local function wait_stable(socket, session, max_attempts, interval_ms)
  max_attempts = max_attempts
    or tonumber(os.getenv("NEO_MARIMO_SCREEN_ATTEMPTS")) or 40 -- ~40 * 150ms = 6s cap
  interval_ms = interval_ms
    or tonumber(os.getenv("NEO_MARIMO_SCREEN_INTERVAL_MS")) or 150
  local prev
  local matches = 0
  for _ = 1, max_attempts do
    local cur, err = capture(socket, session)
    if not cur then return nil, err end
    matches = (prev == cur) and matches + 1 or 0
    if matches >= 2 then return cur end
    prev = cur
    vim.uv.sleep(interval_ms)
  end
  return nil, "pane output never stabilized after " .. max_attempts .. " attempts"
end

-- ── main ─────────────────────────────────────────────────────────────────

local socket = "neo-marimo-screen-" .. vim.uv.os_getpid()
-- Defensive: an interrupted previous run could have left this exact socket
-- behind (same pid is only reused after a full pid-space wraparound, but
-- cheap to guard anyway). Ignore errors — "no server on this socket" is the
-- expected/common case.
tmux(socket, "kill-server")

local init_path = root .. "/tests/screen/init.lua"

local pass, fail = 0, 0
local failures = {}

local any_kept_open = false

for _, screen in ipairs(SCREENS) do
  if not filter or screen.name:find(filter, 1, true) then
    local session = "s-" .. screen.name
    local env = {
      NEO_MARIMO_SCREEN_SCENARIO = screen.scenario,
      NEO_MARIMO_SCREEN_UNTIL_ACTION = screen.until_action and tostring(screen.until_action) or "",
    }

    -- `-n` (no swapfile prompt path — buffer.create already disables
    -- swapfile, this is belt-and-braces) `-i NONE` (skip shada: marks/
    -- command-history from a real user session must never leak into a
    -- deterministic capture) `-u init_path` (see tests/screen/init.lua).
    local new_res = vim.system({
      tmux_bin, "-L", socket, "new-session", "-d", "-x", "100", "-y", "30", "-s", session,
      nvim_bin, "-n", "-i", "NONE", "-u", init_path,
    }, { text = true, env = env }):wait()

    local text, err
    if new_res.code ~= 0 then
      err = "tmux new-session failed: " .. (new_res.stderr or "")
    else
      text, err = wait_stable(socket, session)
    end

    local screen_failed = false
    if text then
      -- t.snapshot's own accept-command message says `make snapshots
      -- FILTER=...`, which is WRONG here (that recipe runs tests/run.lua,
      -- not this file) — t.snapshot is still the right compare/write/diff
      -- engine (same golden format, same NEO_MARIMO_UPDATE_SNAPSHOTS=1
      -- flow, same .actual.txt), so it's reused as-is and the wrong hint in
      -- its failure message is corrected below rather than forking the
      -- whole snapshot engine over one string.
      local ok, snap_err = pcall(t.snapshot, "screen-" .. screen.name, text)
      if ok then
        pass = pass + 1
        io.write(".")
      else
        screen_failed = true
        fail = fail + 1
        io.write("F")
        table.insert(failures, {
          name = screen.name,
          err = tostring(snap_err) ..
            "\n  (to accept: NEO_MARIMO_UPDATE_SNAPSHOTS=1 make test-screen FILTER=" .. screen.name .. ")",
        })
      end
    else
      screen_failed = true
      fail = fail + 1
      io.write("F")
      table.insert(failures, { name = screen.name, err = err or "unknown capture failure" })
    end

    if screen_failed and keep_open_on_failure then
      any_kept_open = true
      io.write("\n  [screen] leaving tmux session alive for inspection: " ..
        tmux_bin .. " -L " .. socket .. " attach -t " .. session .. "\n")
    else
      tmux(socket, "kill-session", "-t", session)
    end
  end
end

-- Always tear the whole private-socket server down, even on failure/error
-- above — this is a private `-L` socket used by nothing else, so a leaked
-- server here is pure waste, not a shared-session hazard — UNLESS a session
-- was deliberately kept alive above for a human to attach to, in which case
-- killing the server would kill that session out from under them.
if not any_kept_open then
  tmux(socket, "kill-server")
end

io.write("\n\n")
for _, f in ipairs(failures) do
  io.write("FAIL: " .. f.name .. "\n" .. f.err .. "\n\n")
end

io.write(string.format("%d passed, %d failed\n", pass, fail))
if update and fail == 0 then
  io.write("(NEO_MARIMO_UPDATE_SNAPSHOTS=1: goldens created/updated under tests/snapshots/screen-*.txt)\n")
end
os.exit(fail == 0 and 0 or 1)
