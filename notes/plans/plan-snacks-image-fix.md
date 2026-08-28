# Plan: Fix snacks.image backend swallowing image output

## Context

After installing snacks.nvim, chart/image output in neo-marimo cells stopped appearing entirely — not even the text fallback (file path + "install image.nvim or snacks.image for inline display") that showed before. The graph still renders in the marimo browser, confirming the data arrives fine.

The regression is in `lua/neo-marimo/image.lua`. Two bugs interact:

**Bug 1 — `pick_backend()` over-eager probe (line 94):**
```lua
local ok_snacks = pcall(function() return require("snacks").image end)
```
This succeeds as long as snacks is importable. It doesn't verify that `snacks.image.placement` (the specific API neo-marimo needs) exists or is enabled. So even if the user hasn't configured `image = { enabled = true }` in their snacks setup, `_backend_cache` is set to `"snacks.image"`.

**Bug 2 — `render_at()` returns `{}` on any non-error result (line 141–143):**
```lua
local ok_create, _ = pcall(snacks.image.placement.new, bufnr,
  { src = path, pos = { row + 1, 0 } })
if ok_create then return {} end
```
`pcall` returns `ok_create = true` whenever the call doesn't raise an error — including when `placement.new` runs but returns `nil` (no placement was created). Returning `{}` bypasses the fallback text, leaving the cell output area empty.

The previous "text about the graph" was the HTML-stripping fallback in `render_html()` (output.lua ~line 130–146), which fired because no backend was detected. Now snacks is falsely detected, the call silently fails, and `{}` is returned instead.

## Fix — `lua/neo-marimo/image.lua` only

### 1. Tighten `pick_backend()` probe

Replace the loose snacks probe with one that verifies the placement API is actually callable:

```lua
local ok_snacks = pcall(function()
  local s = require("snacks")
  assert(type(s.image) == "table" and
         type(s.image.placement) == "table" and
         type(s.image.placement.new) == "function")
end)
```

This prevents false-positive detection when snacks is installed but the image feature isn't enabled.

### 2. Check the placement return value before returning `{}`

Change the snacks render branch from:
```lua
local ok_create, _ = pcall(snacks.image.placement.new, bufnr,
  { src = path, pos = { row + 1, 0 } })
if ok_create then return {} end
```
to:
```lua
local ok_create, placement = pcall(snacks.image.placement.new, bufnr,
  { src = path, pos = { row + 1, 0 } })
if ok_create and placement ~= nil then return {} end
-- If snacks reported success but returned nothing, fall through to text fallback.
if not ok_create then
  vim.notify("[neo-marimo] snacks.image failed: " .. tostring(placement),
    vim.log.levels.WARN)
end
```

This ensures:
- A real placement object must come back before we suppress the fallback
- If the call errors, the error is surfaced so the user can debug it
- In all failure cases, the text fallback (file path lines) still shows

## Critical files

- `lua/neo-marimo/image.lua` — only file changed
  - `pick_backend()` (~line 85–102)
  - `M.render_at()` snacks branch (~line 138–145)

## Verification

1. With snacks installed but `image = {}` **not** in setup config: open a cell that produces a chart → should still see the three-line text fallback (image type + saved path + install hint).
2. With snacks installed and `image = { enabled = true }` in setup: chart should either render inline (if snacks placement works) or fall back to text with a `[neo-marimo] snacks.image failed: ...` warning in `:messages`.
3. In both cases: **no silent empty output**.
4. Run `:lua require("neo-marimo.image").reset_backend()` mid-session after changing snacks config — `pick_backend()` re-probes and picks up the new state.
