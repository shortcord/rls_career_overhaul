-- Retrieval ping wait: a vehicle that never answers must release the caller at the bound,
-- and a late reply must never complete the caller twice. Runs against stubbed engine globals.

local pendingJobs = {}

core_jobsystem = {
  create = function(callback) pendingJobs[#pendingJobs + 1] = coroutine.create(callback) end,
}

local function tick()
  local batch = pendingJobs
  pendingJobs = {}
  for _, job in ipairs(batch) do
    local ok, err = coroutine.resume(job, {sleep = function(_, _seconds) coroutine.yield() end})
    assert(ok, 'job coroutine errored: ' .. tostring(err))
    if coroutine.status(job) == 'suspended' then pendingJobs[#pendingJobs + 1] = job end
  end
end

local pingWait = dofile('lua/ge/extensions/overhaul/career/garage/inventory/pingWait.lua')

local completions, timeouts

-- A reply that arrives while waiting completes the caller once and cancels the timeout.
do
  completions, timeouts = 0, 0
  local reply
  pingWait.waitForReply({
    veh = 'veh',
    request = function(_veh, callback, kind)
      assert(kind == 'ping', 'the wait must request the ping kind')
      reply = callback
    end,
    interval = 0.05,
    timeout = 0.2,
    onCompletion = function(data) completions = completions + 1; assert(data ~= nil, 'the reply payload must be forwarded') end,
    onTimeout = function() timeouts = timeouts + 1 end,
  })
  tick()
  tick()
  reply({result = 'ok'})
  assert(completions == 1 and timeouts == 0, 'a mid-wait reply must complete the caller')
  for _ = 1, 6 do tick() end
  assert(timeouts == 0, 'a completed wait must never fire its timeout')
end

-- A vehicle that never answers releases the caller at the bound; a late reply is dropped.
do
  completions, timeouts = 0, 0
  local lateReply
  pingWait.waitForReply({
    veh = 'veh',
    request = function(_veh, callback) lateReply = callback end,
    interval = 0.05,
    timeout = 0.2,
    onCompletion = function() completions = completions + 1 end,
    onTimeout = function() timeouts = timeouts + 1 end,
  })
  for _ = 1, 4 do tick() end
  assert(timeouts == 0 and completions == 0, 'the timeout must not fire early')
  tick()
  assert(timeouts == 1 and completions == 0, 'a lost reply must release the caller at the timeout')
  lateReply({result = 'too late'})
  assert(completions == 0 and timeouts == 1, 'a reply after the timeout must not complete the caller twice')
end

-- An immediate reply needs no timeout and must not double-complete.
do
  completions, timeouts = 0, 0
  pingWait.waitForReply({
    veh = 'veh',
    request = function(_veh, callback) callback({result = 'ok'}) end,
    interval = 0.05,
    timeout = 0.2,
    onCompletion = function() completions = completions + 1 end,
    onTimeout = function() timeouts = timeouts + 1 end,
  })
  assert(completions == 1 and timeouts == 0, 'an immediate reply must complete the caller once')
  for _ = 1, 6 do tick() end
  assert(completions == 1 and timeouts == 0, 'an immediate reply must never fire its timeout')
end

-- An injected job runner is honoured instead of the global one.
do
  local injectedRan = 0
  pingWait.waitForReply({
    veh = 'veh',
    request = function() end,
    interval = 0.05,
    timeout = 0.1,
    onCompletion = function() end,
    onTimeout = function() end,
    createJob = function(callback)
      injectedRan = injectedRan + 1
      callback({sleep = function() end})
    end,
  })
  assert(injectedRan == 1, 'createJob must receive the wait job')
end

-- The retrieval UI must wake a hibernated vehicle, bound its ping wait, and release the
-- loading fade through a single guarded stop.
local function readSource(path)
  local file = assert(io.open(path, 'r'))
  local source = file:read('*a')
  file:close()
  return source
end

local uiSource = readSource('lua/ge/extensions/overhaul/career/garage/inventory/ui.lua')
assert(uiSource:find("require('overhaul/career/garage/inventory/pingWait')", 1, true),
  'ui.lua must require the ping wait helper')
assert(uiSource:find('pingWait.waitForReply', 1, true), 'ui.lua must bound the snapshot ping wait')

local snapshotStart = assert(uiSource:find('local function setPartConditionResetSnapshot', 1, true),
  'ui.lua must keep the snapshot helper')
local nextSection = assert(uiSource:find('Retrieval and API', snapshotStart, true), 'snapshot section end not found')
local snapshotChunk = uiSource:sub(snapshotStart, nextSection)
assert(snapshotChunk:find('wakeVehicle', 1, true),
  'the snapshot helper must wake a hibernated vehicle before pinging it')

local stopCount = 0
for _ in uiSource:gmatch('ui_fadeScreen%.stop%(') do stopCount = stopCount + 1 end
assert(stopCount == 1, 'every retrieval path must release the fade through one guarded stop')

print('retrieval ping wait tests passed')