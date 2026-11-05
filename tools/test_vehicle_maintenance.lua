-- Run with luajit tools/test_vehicle_maintenance.lua; no live vehicle or save is needed.
package.path = 'lua/?.lua;' .. package.path

-- BeamNG supplies deepcopy globally; keep table copies independent in this offline harness.
function deepcopy(value)
  if type(value) ~= 'table' then return value end
  local copy = {}
  for key, item in pairs(value) do copy[key] = deepcopy(item) end
  return copy
end

local failures, count = 0, 0
local function test(name, body)
  count = count + 1
  local ok, err = pcall(body)
  if ok then print('PASS ' .. name) else
    failures = failures + 1
    print('FAIL ' .. name .. ': ' .. tostring(err))
  end
end
local function near(actual, expected)
  assert(type(actual) == 'number' and math.abs(actual - expected) < 1e-9,
    string.format('expected %.12g, got %s', expected, tostring(actual)))
end
local function freshEngine()
  package.loaded['vehicle/overhaul/maintenance/engine/wear'] = nil
  package.loaded['vehicle/overhaul/maintenance/engine'] = nil
  return require('vehicle/overhaul/maintenance/engine')
end
local function upvalue(fn, key)
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if name == key then return value end
    if not name then error('missing test fixture upvalue: ' .. key) end
  end
end
local function extensionFixture()
  local engine = freshEngine()
  local extension = dofile('lua/vehicle/extensions/overhaulMaintenance.lua')
  -- Seed the existing per-vehicle state without invoking engine physics/GE callbacks.
  local runtime = upvalue(extension.getEngineWearState, 'runtime')
  runtime.runtimeDisabled = false
  runtime.inventoryId = 42
  runtime.state = {categories = {engine = {maintenance = {engineOverhaul = 0.6}}}}
  runtime.runtimeState = {engine = {derived = {
    integrityValue = 0.45, headGasketBlown = true,
    pistonRingsDamaged = false, connectingRodBearingsDamaged = false,
  }}}
  return extension, runtime, engine
end

test('engine exports the maintenance drain used during vehicle loading', function()
  local engine = freshEngine()
  local drained = engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 0, {})
  near(drained.oilCondition, 1)
  near(drained.engineOverhaul, 1)
end)

test('wear converts the miles-based category API to metres', function()
  local engine = freshEngine()
  local drained = engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 515e6 / 1609.344, {})
  -- Halfway through the 30e6..1e9 metre ring window: 1 -> 0.4 gives 0.7.
  near(drained.engineOverhaul, 0.7)
end)

test('wear uses installed metres rather than class-adjusted category age', function()
  local engine = freshEngine()
  local drained = engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 10,
    {inventoryId = 42, odometerMetres = 515e6})
  near(drained.engineOverhaul, 0.7)
end)

test('engine overhaul resets the same inventory entry used by wear', function()
  local engine = freshEngine()
  local env = {inventoryId = 42, odometerMetres = 515e6}
  engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 515e6 / 1609.344, env)
  assert(engine.repairEngineParts(42) == true)
  local drained = engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 515e6 / 1609.344, env)
  near(drained.engineOverhaul, 1)
  local other = engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 515e6 / 1609.344,
    {inventoryId = 43, odometerMetres = 515e6})
  near(other.engineOverhaul, 0.7)
end)

test('distance since overhaul uses metre-based wear windows', function()
  local engine = freshEngine()
  engine.repairEngineParts(42)
  local drained = engine.drainMaintenance(engine.getDefaultMaintenance(), 515e6 / 1609.344, 0,
    {inventoryId = 42, odometerMetres = 0})
  near(drained.engineOverhaul, 0.7)
end)

test('enabled maintenance reports actual engine wear', function()
  local extension = extensionFixture()
  local state = extension.getEngineWearState()
  assert(state, 'enabled maintenance must return its wear state')
  near(state.integrityValue, 0.45)
  near(state.mechanicalCondition, 0.6)
  assert(state.headGasketBlown == true and state.pistonRingsDamaged == false)
end)

test('enabled maintenance allows an engine overhaul', function()
  local extension, _, engine = extensionFixture()
  engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 515e6 / 1609.344,
    {inventoryId = 42, odometerMetres = 515e6})
  assert(extension.repairEngineParts(42) == true, 'enabled repair must succeed')
  local drained = engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 515e6 / 1609.344,
    {inventoryId = 42, odometerMetres = 515e6})
  near(drained.engineOverhaul, 1)
end)

test('disabled maintenance does not report or repair wear', function()
  local extension, runtime = extensionFixture()
  runtime.runtimeDisabled = true
  assert(extension.getEngineWearState() == nil)
  assert(extension.repairEngineParts(42) == false)
end)

test('repair reports a rejected inventory identifier as failure', function()
  local extension = extensionFixture()
  assert(extension.repairEngineParts(nil) == false, 'a rejected repair must not be reported as successful')
end)

test('engine mechanical condition survives save normalization', function()
  local extension = extensionFixture()
  local config = upvalue(extension.getEngineWearState, 'config')
  local state = require('vehicle/overhaul/maintenance/manager/state').create({runtime = {}, config = config})
  local normalized = state.normalizeState({categories = {engine = {maintenance = {engineOverhaul = 0.6}}}})
  near(normalized.categories.engine.maintenance.engineOverhaul, 0.6)
end)

for _, fixture in ipairs({
  {integrity = 0.25, gasket = true, bearings = false},
  {integrity = 0.05, gasket = true, bearings = true},
}) do
  test('derived failure flags retain integrity thresholds at ' .. fixture.integrity, function()
    local engine = freshEngine()
    local env = {avgMiles = 0, integrityValue = fixture.integrity}
    local maintenance = engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 0, env)
    local derived = engine.buildDerived({maintenance = maintenance}, env)
    assert(derived.headGasketBlown == fixture.gasket, 'head gasket flag must reach the failure manager')
    assert(derived.connectingRodBearingsDamaged == fixture.bearings, 'bearing flag must reach the failure manager')
  end)
end

test('a manager tick supplies inventory identity and unadjusted installed distance', function()
  local extension, runtime, engine = extensionFixture()
  local config = upvalue(extension.getEngineWearState, 'config')
  local parts = upvalue(extension.updateGFX, 'parts')
  local helpers = upvalue(upvalue(parts.failures.updateState, 'beginMaintenanceTick'), 'helpers')
  -- Keep the real manager/environment/category pipeline; stub only live game observations.
  local conditions = {engine = {odometer = 515e6, integrityValue = 1}}
  partCondition = {getConditions = function() return conditions end}
  extensions = {}
  electrics = {values = {wheelspeed = 0}}
  runtime.state.profile = {class = 'heavyTruck'}
  runtime.state.lastSyncMileage = 515e6
  runtime.state.categories.engine.maintenance = engine.getDefaultMaintenance()
  runtime.categoryCache = {engine = {rootPartId = 'engine', partIds = {'engine'}}}
  runtime.hardwareByCategory = {engine = true}
  runtime.deviceContexts = {engine = {devices = {}}}
  runtime.runtimeState = {engine = {}}
  config.categoryOrder = {'engine'}
  helpers.getSerializedSignature = function() return '' end
  parts.classification.buildLiveVehicleProfile = function(profile) return profile end
  parts.environment.buildEnvironmentSnapshot = function() return {profile = runtime.state.profile} end
  parts.failures.updateState(0)
  near(runtime.state.categories.engine.maintenance.engineOverhaul, 0.7)
  conditions.engine.odometer = 515001609.344 -- One additional mile, within the speed/dt limit.
  electrics.values.wheelspeed = 100
  parts.failures.updateState(20)
  near(runtime.state.categories.engine.maintenance.engineOverhaul, 0.6999990045294845)
  assert(extension.repairEngineParts(42))
  parts.failures.updateState(0)
  near(runtime.state.categories.engine.maintenance.engineOverhaul, 1)
end)

assert(failures == 0, string.format('%d/%d maintenance tests failed', failures, count))
print(string.format('%d maintenance tests passed', count))
