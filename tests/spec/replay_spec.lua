-- T2: replay spec layer. Feeds a recorded WS transcript (T1,
-- tests/transcripts/<version>/*.jsonl) through the real decode+dispatch+
-- render pipeline against a real (kernel-free) buffer, drains the resulting
-- vim.schedule'd render work, and snapshots the final buffer/extmark state.
-- No server, no kernel, no python — see docs/plan-testing.md T2.

local t = require("helpers")
local image = require("neo-marimo.image")
local ws_handlers = require("neo-marimo.ws_handlers")

-- Every replay in this file draws through the same fake "backend" (see
-- image.lua's _set_test_backend doc comment): real placement bookkeeping,
-- no attempt at an actual terminal escape sequence — kitty graphics can't
-- emit headless, and the two real backends (image.nvim, snacks.image)
-- aren't on this test env's package.path anyway. Scoped to each case
-- (installed/cleared immediately around the body) rather than left on for
-- the whole suite, so this can't change how an unrelated spec's own image
-- assertions behave.
local function with_image_stub(fn)
  image._set_test_backend(function() return true end)
  local ok, err = pcall(fn)
  image._set_test_backend(nil)
  if not ok then error(err, 0) end
end

-- ── one case per scenario transcript ─────────────────────────────────────

local SCENARIOS = { "basic_run", "widgets", "error_cell", "rich_output" }

for _, name in ipairs(SCENARIOS) do
  t.case("replay: " .. name .. " matches its golden render state", function()
    with_image_stub(function()
      local nb, bufnr = t.make_notebook(t.scenario_codes(name))
      t.replay(name, nb, bufnr)
      t.snapshot("replay-" .. name, t.render_state(bufnr))
    end)
  end)
end

-- edit_rerun carries a meaningful intermediate state (docs/plan-testing.md
-- T2): the code is edited and saved (update-cell-ids/update-cell-codes have
-- landed) but the rerun hasn't happened yet, so the buffer shows the new
-- source while the output extmark still shows the stale value. Caught via
-- `until_action`, which stops replay right after the 2nd `__action__` marker
-- ("edit-and-save") and before the 3rd ("run-cell") — see the transcript
-- itself, tests/transcripts/0.19/edit_rerun.jsonl.
t.case("replay: edit_rerun reaches an 'edited, not yet rerun' intermediate state", function()
  with_image_stub(function()
    local nb, bufnr = t.make_notebook(t.scenario_codes("edit_rerun"))
    t.replay("edit_rerun", nb, bufnr, { until_action = 2 })
    t.snapshot("replay-edit_rerun-mid", t.render_state(bufnr))
  end)
end)

t.case("replay: edit_rerun matches its golden final render state", function()
  with_image_stub(function()
    local nb, bufnr = t.make_notebook(t.scenario_codes("edit_rerun"))
    t.replay("edit_rerun", nb, bufnr)
    t.snapshot("replay-edit_rerun", t.render_state(bufnr))
  end)
end)

-- ── coverage guard ────────────────────────────────────────────────────────
--
-- Replays every committed transcript and asserts no line hits the
-- unknown-op path: ws_handlers.dispatch returns false both when an op has no
-- registered handler at all AND when its handler threw (contained by
-- dispatch's own pcall, plan-refinement F4.1) — the two are told apart here
-- by whether M._handler_errors[op] actually advanced. This is what catches
-- "marimo added an op we silently drop" the moment transcripts are
-- re-recorded against a newer marimo (docs/plan-testing.md T2).
t.case("replay: coverage guard — every transcript's ops are handled cleanly", function()
  with_image_stub(function()
    for _, name in ipairs(t.transcript_names()) do
      local nb, bufnr = t.make_notebook(t.scenario_codes(name))
      local errors_before = vim.deepcopy(ws_handlers._handler_errors)
      local unknown_ops = {}

      t.replay(name, nb, bufnr, {
        on_dispatch = function(op, _payload, ok)
          if not ok then
            local threw = (ws_handlers._handler_errors[op] or 0) > (errors_before[op] or 0)
            if not threw then
              table.insert(unknown_ops, op)
            end
          end
        end,
      })

      t.eq(unknown_ops, {}, name .. ": op(s) with no registered handler")
      for op, count in pairs(ws_handlers._handler_errors) do
        t.eq(count, errors_before[op] or 0, name .. ": handler for '" .. op .. "' threw during replay")
      end
    end
  end)
end)

-- ── regression: prove the layer would catch a real fixed bug ───────────────
--
-- F2.6 (docs/plan-refinement.md): rekey_by_position/rekey_by_code overwrite
-- cell.id in place; without migrating image.lua's and widgets.lua's
-- cell-id-keyed registries, the old key is orphaned (never closed) and the
-- new key finds nothing to clear, so the next render draws a second,
-- stale-painting placement on top of the fresh one. ws_dispatch_spec.lua
-- already covers this with direct assertions; this case shows the T2
-- render-state snapshot would catch the same regression through the
-- replay/snapshot machinery — the placement's key visibly follows the cell
-- across a re-key, or it doesn't.
t.case("replay: image + widget registries survive a re-key without leaking (F2.6)", function()
  with_image_stub(function()
    local widgets = require("neo-marimo.widgets")
    local nb, bufnr = t.make_notebook({ "import marimo as mo", "s = mo.ui.slider(0, 10)\ns" })
    local old_id = nb.cells[2].id

    -- Stand in for what a real cell-op render would have left behind: an
    -- image placement and a registered widget, both keyed by the cell's
    -- pre-rekey id.
    image.render_at(bufnr, 0, "image/png", "\137PNG\r\n", old_id)
    widgets.register_widget(bufnr, old_id, { name = "slider", object_id = old_id .. "-0", value = 1 })

    local before = t.render_state(bufnr)
    t.match(before, "%[" .. vim.pesc(old_id) .. "%]", "sanity: placement starts keyed by the pre-rekey id")

    -- A reload assigning fresh server ids — the exact shape update-cell-ids
    -- carries (docs/plan-testing.md's key seams: server._decode_ws_line +
    -- ws_handlers.dispatch, the same call this replay layer drives).
    ws_handlers.dispatch("update-cell-ids", { cell_ids = { "K1", "NEW2" } }, { nb = nb, bufnr = bufnr })

    local after = t.render_state(bufnr)
    t.no_match(after, "%[" .. vim.pesc(old_id) .. "%]", "the old key must not still show a placement")
    t.match(after, "%[NEW2%]", "the placement followed the cell to its new id")
    t.eq(#widgets.list_for_cell(bufnr, "NEW2"), 1, "widget registry followed the id flip too")
  end)
end)
