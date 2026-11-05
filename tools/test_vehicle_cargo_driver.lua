-- Run from the repository root: luajit tools/test_vehicle_cargo_driver.lua
-- Engine-facing behavior is exercised with vehicle/GE mocks, not source checks.
local failures = 0
local function test(name, callback)
  local ok, err = pcall(callback)
  if ok then
    print('PASS: ' .. name)
  else
    failures = failures + 1
    print('FAIL: ' .. name .. ': ' .. tostring(err))
  end
end

local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function loadCargo(beam)
  deepcopy = copy
  nop = function() end
  log = nop
  checkTableDataTypes = function() return true end
  newTemporalSmoothing = function(rate, _, _, initial)
    return {
      state = initial or 0,
      [false] = rate,
      get = function(self, target) self.state = target; return target end,
    }
  end
  package.loaded['jbeam/expressionParser'] = {
    compileSafe = function(expr)
      local value = assert(tonumber(expr:match('^%$=(.+)$')), 'fixture requires a numeric expression')
      return function() return value end, {}
    end,
  }
  v = {data = {
    cargoStorage = {{cid = 0, groupId = 'cargo', partPath = 'body', cargoTypes = {'parcel'}, capacity = 10}},
    nodes = {},
    beams = {[7] = beam},
  }}
  beam.cid, beam.cargoGroup, beam.partPath = 7, 'cargo', 'body'
  local physical = {}
  obj = {
    setBoundedBeamSpringDampLimits = function(_, id, spring, damp)
      physical[id] = physical[id] or {}
      physical[id].spring, physical[id].damp = spring, damp
    end,
    setBoundedBeamShortBound = function(_, id, value)
      physical[id] = physical[id] or {}
      physical[id].short = value
    end,
    setBoundedBeamLongBound = function(_, id, value)
      physical[id] = physical[id] or {}
      physical[id].long = value
    end,
  }
  extensions = {hookUpdate = nop, gameplayInterface = {registerModule = nop}}
  local cargo = dofile('lua/vehicle/extensions/overhaulCargoContainers.lua')
  cargo.onExtensionLoaded()
  assert(cargo.setActive(true))
  local result = cargo.moduleActions.overhaulSetCargoContainers({{[0] = {containerId = 0, volume = 5, density = 2}}, 'updateExplicit'})
  assert(not result or not result.failReason)
  cargo.updateGFX(1)
  return cargo, physical
end

test('a beam with only a limit damping function participates in cargo updates', function()
  local cargo, physical = loadCargo({beamLimitDamp = 12, beamLimitDampFunction = '=42'})
  assert(physical[7] and physical[7].damp == 42, 'cargo must apply limit-only damping')
  cargo.setActive(false)
  assert(physical[7].damp == 12, 'deactivation must restore original limit damping')
end)

for _, lifecycle in ipairs({'deactivate', 'unload'}) do
  test(lifecycle .. ' restores cargo short and long bounds', function()
    local cargo, physical = loadCargo({
      beamShortBound = 0, beamLongBound = 1.5,
      beamShortBoundFunction = '=0.25', beamLongBoundFunction = '=0.75',
    })
    assert(physical[7].short == 0.25 and physical[7].long == 0.75, 'cargo must first change the bounds')
    if lifecycle == 'deactivate' then cargo.setActive(false) else cargo.onExtensionUnloaded() end
    assert(physical[7].short == 0, 'original short bound, including zero, must be restored')
    assert(physical[7].long == 1.5, 'original long bound must be restored')
  end)
end

-- Execute both queued VM hops so the route planner observes the public API's settings.
local function loadDriver()
  package.path = 'lua/?.lua;' .. package.path
  local routeArgs, queuedGE
  local target = {x = 1, y = 2, z = 3}
  obj = {
    getPosition = function() return 'vehicle position' end,
    getID = function() return 101 end,
    queueGameEngineLua = function(_, command) queuedGE = command end,
    queueLuaCommand = function(_, command) assert(loadstring(command))() end,
  }
  core_groundMarkers = {getTargetPos = function() return target end}
  getObjectByID = function(id) assert(id == '101'); return obj end
  serialize = function(value) assert(value == target); return '{x=1,y=2,z=3}' end
  mapmgr = {getPointToPointPath = function(position, destination, ...)
    assert(position == 'vehicle position' and destination.x == 1)
    routeArgs = {...}
    return {'start', 'finish'}
  end}
  ai = {
    setPath = function() end,
    driveUsingPathWithTraffic = function() ai.mode = 'manualTraffic' end,
    setMode = function(mode) ai.mode = mode end,
    setAvoidCars = function() end,
    setSpeedMode = function() end,
    driveInLane = function() end,
    setParameters = function() end,
    createPendingRoute = function() return true end,
  }
  overhaulDriver = dofile('lua/vehicle/extensions/overhaulDriver.lua')
  return overhaulDriver, function()
    assert(queuedGE, 'driver must request the marker target from GE')
    assert(loadstring(queuedGE))()
    return routeArgs
  end
end

local function assertRouting(actual, expected)
  for index, value in ipairs(expected) do
    assert(actual[index] == value, string.format('routing argument %d: expected %s, got %s', index, value, tostring(actual[index])))
  end
end

for _, method in ipairs({'driveToTarget', 'driveFastToTarget'}) do
  test(method .. ' forwards custom routing settings', function()
    local driver, finish = loadDriver()
    driver[method](0, 2, 3, 4, 0)
    assertRouting(finish(), {0, 2, 3, 4, 0})
  end)
end

test('normal and fast calls reset omitted routing settings to their own defaults', function()
  local driver, finish = loadDriver()
  driver.driveToTarget(0.5, 2, 3, 4, 5)
  finish()
  driver.driveFastToTarget()
  assertRouting(finish(), {0.1, 1, 1, 1, 1})
  driver.driveToTarget()
  assertRouting(finish(), {0, 10000, 1000, 100000, 1})
end)

assert(failures == 0, tostring(failures) .. ' vehicle cargo/driver tests failed')
print('vehicle cargo/driver tests passed')
