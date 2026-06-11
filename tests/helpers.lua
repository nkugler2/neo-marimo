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
