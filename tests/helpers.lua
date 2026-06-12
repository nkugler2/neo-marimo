-- Shared helpers for the neo-marimo test suite. Loaded by tests/run.lua;
-- spec files require it as `local t = require("helpers")` and register cases
-- with `t.case(name, fn)`.

local H = {}

H.cases = {}

-- Repo root (tests/ lives directly under it). Set by run.lua before specs load.
H.root = nil

function H.case(name, fn)
  table.insert(H.cases, { name = name, fn = fn })
end

-- ── assertions ────────────────────────────────────────────────────────────

local function fail(msg)
  error(msg, 3)
end

function H.ok(cond, msg)
  if not cond then fail(msg or "expected truthy value") end
end

function H.eq(got, want, msg)
  if not vim.deep_equal(got, want) then
    fail((msg and msg .. ": " or "")
      .. "expected " .. vim.inspect(want)
      .. "\n     got " .. vim.inspect(got))
  end
end

function H.match(s, pat, msg)
  if type(s) ~= "string" or not s:find(pat) then
    fail((msg and msg .. ": " or "")
      .. "expected match for " .. vim.inspect(pat)
      .. " in " .. vim.inspect(type(s) == "string" and s:sub(1, 200) or s))
  end
end

function H.no_match(s, pat, msg)
  if type(s) == "string" and s:find(pat) then
    fail((msg and msg .. ": " or "")
      .. "expected NO match for " .. vim.inspect(pat)
      .. " in " .. vim.inspect(s:sub(1, 200)))
  end
end

-- ── fixtures ──────────────────────────────────────────────────────────────

-- Newest fixture version directory under tests/fixtures (sorted descending,
-- so "0.20" beats "0.19" once captured).
function H.fixture_dir()
  local dirs = vim.fn.glob(H.root .. "/tests/fixtures/*", false, true)
  table.sort(dirs, function(a, b) return a > b end)
  assert(dirs[1], "no fixture directories — run tests/capture_fixtures.py")
  return dirs[1]
end

function H.fixture(name)
  local path = H.fixture_dir() .. "/" .. name .. ".html"
  local f = assert(io.open(path, "r"), "missing fixture: " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

function H.fixture_names()
  local out = {}
  for _, p in ipairs(vim.fn.glob(H.fixture_dir() .. "/*.html", false, true)) do
    table.insert(out, vim.fn.fnamemodify(p, ":t:r"))
  end
  table.sort(out)
  return out
end

-- ── live notebook harness ─────────────────────────────────────────────────

local _nb_counter = 0

-- Build a live notebook from a list of cell code strings: real state table,
-- real marimo:// buffer, real change tracking — the same buffer.create +
-- buffer.attach_change_tracking paths production uses, minus the python
-- parser / server / watcher / LSP. The buffer is made current so cursor and
-- normal-mode commands target it.
--
-- Tests drive edits exactly like a user (nvim_buf_set_lines, :normal!,
-- :undo) and call nb._flush_pending() where a keymap action would — the
-- synchronous stand-in for the 300ms debounce.
function H.make_notebook(codes)
  local config = require("neo-marimo.config")
  if not config.options.python_path then
    config.setup({})
  end

  local notebook = require("neo-marimo.notebook")
  local buffer = require("neo-marimo.buffer")

  _nb_counter = _nb_counter + 1
  local filepath = "/tmp/neo-marimo-test-" .. _nb_counter .. ".py"

  local data = { cells = {} }
  for _, code in ipairs(codes) do
    table.insert(data.cells, { name = "_", code = code })
  end

  local nb = notebook.new(filepath, data)
  local bufnr = buffer.create(nb, nil)
  buffer.attach_change_tracking(bufnr, nb)
  vim.api.nvim_set_current_buf(bufnr)
  return nb, bufnr
end

-- Close the current undo block. In a headless script there is no user input
-- loop, so consecutive buffer edits all merge into a single undo block and
-- one `:undo` would revert everything since attach. Interactive editing gets
-- a new block per command; tests call this where that boundary would fall
-- (right before the edit they intend to undo).
function H.undo_break()
  vim.cmd("let &undolevels = &undolevels")
end

-- Assert the notebook's offsets form a contiguous cover of the buffer and
-- every cell's code matches its buffer slice — the same invariants the
-- save validator enforces. Call after every mutation in editing tests.
function H.assert_consistent(nb, bufnr, msg)
  local notebook = require("neo-marimo.notebook")
  local ok, errors = notebook.validate_offsets(nb, bufnr)
  if not ok then
    fail((msg or "notebook drifted") .. ": " .. table.concat(errors, "; "))
  end
  for i, cell in ipairs(nb.cells) do
    local slice = vim.api.nvim_buf_get_lines(bufnr, cell.start_row, cell.end_row + 1, false)
    local slice_text = table.concat(slice, "\n")
    if slice_text ~= (cell.code or "") then
      fail((msg or "notebook drifted") .. string.format(
        ": cell[%d] code %s disagrees with buffer rows %d-%d %s",
        i, vim.inspect(cell.code), cell.start_row, cell.end_row,
        vim.inspect(slice_text)))
    end
  end
end

-- ── virt_lines helpers ────────────────────────────────────────────────────

-- Flatten virt_line chunk lists into plain strings, one per line — what the
-- user would see, minus highlights. Most render assertions go through this.
function H.flat_lines(virt_lines)
  local out = {}
  for _, chunks in ipairs(virt_lines or {}) do
    local s = ""
    for _, ch in ipairs(chunks) do s = s .. ch[1] end
    table.insert(out, s)
  end
  return out
end

function H.joined(virt_lines)
  return table.concat(H.flat_lines(virt_lines), "\n")
end

return H
