-- F2.7: tmux kitty-graphics fossil cleanup — escape-sequence construction,
-- the clear_all/BufWipeout sweep path, the attach-time gating, and the
-- :MarimoImageRepaint wiring. Terminal pixels can't be asserted from a
-- headless test (there's no real terminal to paint into or read back from);
-- these specs only cover the pure/registry-level logic, per the plan.

local t = require("helpers")
local image = require("neo-marimo.image")

t.case("image: sweep sequence — bare kitty delete-all", function()
  t.eq(image._sweep_sequence(false), "\27_Ga=d,d=A\27\\")
end)

t.case("image: sweep sequence — tmux passthrough-wrapped", function()
  t.eq(image._sweep_sequence(true), "\27Ptmux;\27\27_Ga=d,d=A\27\27\\\27\\")
end)

t.case("image: clear_all closes every buffer's placements and empties the registry", function()
  local buf_a = vim.api.nvim_create_buf(false, true)
  local buf_b = vim.api.nvim_create_buf(false, true)

  local closed_a, closed_b = false, false
  image._register_for_test(buf_a, "cell-a", "/tmp/a.png", function() closed_a = true end)
  image._register_for_test(buf_b, "cell-b", "/tmp/b.png", function() closed_b = true end)

  image.clear_all()

  t.ok(closed_a, "buf_a placement closed")
  t.ok(closed_b, "buf_b placement closed")

  -- Registry is empty for both: a subsequent clear_for_cell has nothing to
  -- close (re-registering after clear_all proves the buffer key was wiped,
  -- not merely emptied).
  local closed_again = false
  image._register_for_test(buf_a, "cell-a", "/tmp/a.png", function() closed_again = true end)
  image.clear_for_cell(buf_a, "cell-a")
  t.ok(closed_again, "registry accepts a fresh registration after clear_all")
end)

t.case("image: sweep_terminal gating — outside tmux, force=false is a no-op", function()
  -- Force pick_backend() to see a backend so the *tmux* gate, not the
  -- backend gate, is what's under test here.
  package.loaded["image"] = {}
  image.reset_backend()

  local orig_tmux = vim.env.TMUX
  vim.env.TMUX = nil

  local orig_emit = image._emit
  local emitted = false
  image._emit = function() emitted = true end

  local ok = pcall(image.sweep_terminal, false)

  image._emit = orig_emit
  vim.env.TMUX = orig_tmux
  package.loaded["image"] = nil
  image.reset_backend()

  t.ok(ok, "sweep_terminal did not error")
  t.ok(not emitted, "no escape emitted outside tmux without force")
end)

t.case("image: sweep_terminal gating — no backend detected is always a no-op", function()
  -- Ensure pick_backend() sees neither image.nvim nor snacks in the
  -- headless test environment (the default state, but be explicit).
  image.reset_backend()

  local orig_tmux = vim.env.TMUX
  vim.env.TMUX = "1"  -- would otherwise pass the tmux gate

  local orig_emit = image._emit
  local emitted = false
  image._emit = function() emitted = true end

  image.sweep_terminal(true)  -- force=true still can't draw without a backend

  image._emit = orig_emit
  vim.env.TMUX = orig_tmux

  t.ok(not emitted, "no backend means nothing could have drawn — no emit")
end)

t.case("image: sweep_terminal — tmux set or force=true emits (with a backend)", function()
  package.loaded["image"] = {}
  image.reset_backend()

  local orig_emit = image._emit
  local seen = nil
  image._emit = function(seq) seen = seq end

  local orig_tmux = vim.env.TMUX
  vim.env.TMUX = nil
  image.sweep_terminal(true)  -- force, outside tmux → bare sequence

  image._emit = orig_emit
  vim.env.TMUX = orig_tmux
  package.loaded["image"] = nil
  image.reset_backend()

  t.eq(seen, image._sweep_sequence(false))
end)

t.case("image: :MarimoImageRepaint wiring — sweeps, clears registry, re-renders", function()
  local actions = require("neo-marimo.actions")
  local nb, bufnr = t.make_notebook({ "1 + 1" })

  local closed = false
  image._register_for_test(bufnr, nb.cells[1].id, "/tmp/plot.png", function() closed = true end)

  local orig_emit = image._emit
  local swept = false
  image._emit = function() swept = true end
  package.loaded["image"] = {}
  image.reset_backend()

  local ok = pcall(actions.repaint_images, bufnr, nb)

  image._emit = orig_emit
  package.loaded["image"] = nil
  image.reset_backend()

  t.ok(ok, "repaint_images ran without error (render_all with an empty registry)")
  t.ok(swept, "sweep_terminal(true) emitted regardless of $TMUX")
  t.ok(closed, "the notebook's registry placement was closed before re-render")
end)
