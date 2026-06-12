-- File watcher for external edits.
--
-- We watch the underlying .py path with libuv's fs_event so any change
-- made by marimo's browser editor (or another editor on the user's
-- machine) is reflected in the notebook view automatically.
--
-- Marimo's browser saves via atomic-write (write tmp, rename to target),
-- which on macOS fires a `rename` event and can invalidate the watch.
-- We rearm the watcher on every event so the watch survives the
-- rename-replace cycle.
--
-- Save loop guard: our own :w path also writes the file. We tag the
-- notebook with `nb._suppress_watcher = true` for ~750ms around our
-- writes (set by sync.write_to_file). If the watcher fires during that
-- window, we skip the reload — otherwise nvim would round-trip every
-- save through the bridge and clobber the cursor.

local utils = require("neo-marimo.utils")

local M = {}

-- filepath -> { handle = uv_fs_event, debounce = fn }
M._watchers = {}

local function rearm(handle, filepath, callback)
  pcall(function() handle:stop() end)
  local ok = pcall(function()
    handle:start(filepath, {}, callback)
  end)
  if not ok then
    -- The file might have momentarily disappeared mid-rename. Try once
    -- more after a short delay; if that fails too the user can :e to
    -- re-trigger attach() which restarts the watcher cleanly.
    vim.defer_fn(function()
      pcall(function() handle:start(filepath, {}, callback) end)
    end, 100)
  end
end

-- Start watching `filepath`. `on_change` is called on the main loop
-- (via vim.schedule) after a 300ms debounce so a burst of rename/create
-- events from an atomic save collapses into a single reload.
function M.start(filepath, on_change)
  if M._watchers[filepath] then
    M.stop(filepath)
  end

  local handle = vim.uv.new_fs_event()
  if not handle then
    utils.warn("watcher: could not allocate fs_event handle for " .. filepath)
    return false
  end

  local debounced = utils.debounce(function()
    -- The callback runs on the main loop already (debounce wraps with
    -- vim.schedule_wrap), so it's safe to call API functions here.
    if vim.uv.fs_stat(filepath) then
      on_change()
    end
  end, 300)

  local function cb(err, _fname, events)
    -- err == "ENOENT" briefly during a rename-replace save; just rearm.
    if not err and events and events.change then
      debounced()
    end
    -- rename always invalidates the inode-based watch — rearm so we
    -- keep seeing future events on the same path.
    if err or (events and events.rename) then
      vim.defer_fn(function()
        if M._watchers[filepath] then
          rearm(handle, filepath, cb)
          if not err then debounced() end
        end
      end, 50)
    end
  end

  local ok, start_err = pcall(function()
    handle:start(filepath, {}, cb)
  end)
  if not ok then
    pcall(function() handle:close() end)
    utils.warn("watcher: failed to start on " .. filepath .. ": " .. tostring(start_err))
    return false
  end

  M._watchers[filepath] = { handle = handle }
  return true
end

-- Stop watching `filepath`. Safe to call when no watcher is registered.
function M.stop(filepath)
  local w = M._watchers[filepath]
  if not w then return end
  pcall(function() w.handle:stop() end)
  pcall(function() w.handle:close() end)
  M._watchers[filepath] = nil
end

return M
