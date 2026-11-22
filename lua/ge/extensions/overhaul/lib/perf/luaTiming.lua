-- Lightweight, opt-out timing for selected GE Lua hooks. No debug hooks or VM-wide sampler.
local M = {}

function M.new(options)
  options = options or {}
  local clock = options.clock or os.clockhp or os.clock
  local writeLog = options.log or log
  local interval = options.interval or 10
  local enabled = true
  local stats = {}

  local function record(name, start, ...)
    local finished = clock()
    local elapsed = math.max(0, (finished - start) * 1000)
    local entry = stats[name]
    if not entry then
      entry = {window = start, calls = 0, total = 0, max = 0, slow = 0}
      stats[name] = entry
    end
    entry.calls = entry.calls + 1
    entry.total = entry.total + elapsed
    entry.max = math.max(entry.max, elapsed)
    if elapsed >= 16 then entry.slow = entry.slow + 1 end
    if finished - entry.window >= interval then
      writeLog('I', 'overhaul.luaTiming', string.format(
        '%s calls=%d avg_ms=%.3f max_ms=%.3f slow_16ms=%d window_s=%.1f',
        name, entry.calls, entry.total / entry.calls, entry.max, entry.slow, finished - entry.window))
      stats[name] = nil
    end
    return ...
  end

  local profiler = {}
  function profiler.wrap(name, fn)
    return function(...)
      if not enabled then return fn(...) end
      local start = clock()
      return record(name, start, fn(...))
    end
  end
  function profiler.setEnabled(value)
    enabled = value == true
    stats = {}
  end
  return profiler
end

local default = M.new()
M.wrap = default.wrap
M.setEnabled = default.setEnabled
return M
