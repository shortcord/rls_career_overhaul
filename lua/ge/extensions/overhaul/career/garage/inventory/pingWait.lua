-- Bounded, single-shot wait for a core_vehicleBridge reply from a vehicle.
-- The bridge registers the callback with no timeout, so a vehicle that never answers
-- (one queued while hibernated, deleted mid-request or still loading) would strand the
-- caller. Whatever happens, the completion fires once; a later reply is dropped.

local M = {}

function M.waitForReply(options)
  assert(type(options) == 'table' and type(options.request) == 'function', 'waitForReply: request function required')
  assert(type(options.onCompletion) == 'function', 'waitForReply: onCompletion required')
  local request = options.request
  local veh = options.veh
  local kind = options.kind or 'ping'
  local interval = math.max(options.interval or 0.05, 0.01)
  local timeout = math.max(options.timeout or 2, 0)
  local createJob = options.createJob or (core_jobsystem and core_jobsystem.create)
  assert(createJob, 'waitForReply: no job system available to bound the wait')

  local completed = false
  local function complete(data)
    if completed then return end
    completed = true
    options.onCompletion(data)
  end

  request(veh, complete, kind)
  if completed then return end

  local onTimeout = options.onTimeout
  if not onTimeout then
    -- No timeout handler: the completion itself is the release path.
    function onTimeout() complete() end
  end
  createJob(function(job)
    local waited = 0
    while waited < timeout do
      if completed then return end
      job.sleep(interval)
      waited = waited + interval
    end
    if completed then return end
    completed = true
    onTimeout()
  end)
end

return M