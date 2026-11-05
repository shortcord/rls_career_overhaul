-- Run with luajit tools/test_engine_overhaul_service.lua (no game required).
package.path = 'lua/ge/extensions/?.lua;lua/?.lua;' .. package.path

function deepcopy(value)
  if type(value) ~= 'table' then return value end
  local copy = {}
  for key, item in pairs(value) do copy[key] = deepcopy(item) end
  return copy
end
local commands = require('overhaul/lib/vehicles/vehicleCommands')
serialize = commands.luaLiteral
log = function() end
local function upvalue(fn, key)
  for i = 1, 100 do
    local name, value = debug.getupvalue(fn, i)
    if name == key then return value end
  end
  error('missing fixture upvalue ' .. key)
end
local function near(actual, expected)
  assert(math.abs(actual - expected) < 1e-9, 'expected ' .. expected .. ', got ' .. actual)
end

local function fixture(spawned)
  package.loaded['vehicle/overhaul/maintenance/engine/wear'] = nil
  package.loaded['vehicle/overhaul/maintenance/engine'] = nil
  local engine = require('vehicle/overhaul/maintenance/engine')
  local extension = dofile('lua/vehicle/extensions/overhaulMaintenance.lua')
  local runtime = upvalue(extension.getEngineWearState, 'runtime')
  runtime.runtimeDisabled = false
  runtime.inventoryId = 42
  runtime.state = {categories = {engine = {maintenance = {engineOverhaul = 0.7}}}}
  local env = {inventoryId = 42, odometerMetres = 515e6}
  local function wear(id)
    return engine.drainMaintenance(engine.getDefaultMaintenance(), 0, 0,
      {inventoryId = id or 42, odometerMetres = env.odometerMetres}).engineOverhaul
  end
  near(wear(), 0.7)
  near(wear(43), 0.7)
  local data = {id = 42, maintenanceState = {categories = {engine = {
    maintenance = {engineOverhaul = 0.7, oilCondition = 0.5},
  }}}, maintenanceComputerState = {revealed = {}, jobs = {}}}
  local business = deepcopy(data)
  local queue, syncWear = {}, {}
  local vehicle = {getID = function() return 100 end,
    queueLuaCommand = function(_, command) queue[#queue + 1] = command end}
  local live = spawned ~= false
  getObjectByID = function(id) if id == 100 and live then return vehicle end end
  overhaulMaintenance = nil -- GE must never depend on a vehicle-VM global.
  overhaul_career_career = nil
  overhaul_career_garage_inventory = {
    getVehicle = function(id) if id == 42 then return data end end,
    getVehicleIdFromInventoryId = function(id) if live and id == 42 then return 100 end end,
    getInventoryIdFromVehicleId = function() return 42 end,
    setVehicleDirty = function() end,
  }
  overhaul_career_business_manager = {isPurchasedBusiness = function() return true end}
  overhaul_career_saveSystem = {saveCurrent = function() end}
  overhaul_career_economy_payment = {canPay = function() return true end, pay = function() return true end}
  overhaul_vehicles_maintenanceBridge = dofile('lua/ge/extensions/overhaul/vehicles/maintenanceBridge.lua')
  local definitions = {
    engineOverhaul = {name = 'engineOverhaul', label = 'Engine', actionLabel = 'Overhaul'},
    oilCondition = {name = 'oilCondition', label = 'Oil', actionLabel = 'Replace'},
  }
  local parts = {closeMenu = function() end, quotes = {
    getTrackedPartData = function() return {}, nil, false end,
    categoryHardwareIsInstalled = function() return true end,
    calculateTrackedPartsValue = function() return 0 end,
    calculateServicePrice = function() return 0 end,
  }}
  local inputs = {state = {}, parts = parts, config = {
    categoryOrder = {'engine'}, categoryDefinitions = {engine = {items = {definitions.engineOverhaul, definitions.oilCondition}}},
    getItemDefinition = function(category, item) if category == 'engine' then return definitions[item] end end,
  }, getVehicleData = function() return data end, getBusinessVehicleData = function() return business end,
    normalizeVehicleMaintenanceState = function(v) return v.maintenanceState, false end,
    ensureMaintenanceComputerState = function(v) return v.maintenanceComputerState, false end,
    roundPercent = function(value) return math.floor(value * 100 + 0.5) end,
    isMaintenanceEnabled = function() return true end, deepCopy = deepcopy,
    persistVehicleMutation = function() end, markVehicleDirty = function() end,
  }
  parts.services = dofile('lua/ge/extensions/overhaul/career/maintenance/maintenanceComputer/services.lua').new(inputs)
  parts.cart = dofile('lua/ge/extensions/overhaul/career/maintenance/maintenanceComputer/cart.lua').new(inputs)
  -- Execute the real GE-generated commands in a separate vehicle namespace. Only runtime
  -- initialization is a game boundary double; repair invokes the real extension and wear model.
  local vehicleVM = {extensions = {load = function() end}, overhaulMaintenance = {
    repairEngineParts = extension.repairEngineParts,
    initFromSave = function(snapshot, id)
      assert(id == 42)
      syncWear[#syncWear + 1] = wear()
      runtime.state = snapshot
    end,
  }}
  local function drain()
    for _, command in ipairs(queue) do
      local chunk = assert(loadstring(command))
      setfenv(chunk, vehicleVM)
      chunk()
    end
    queue = {}
  end
  return {parts = parts, data = data, business = business, wear = wear, drain = drain, syncWear = syncWear}
end

local failures = 0
local function test(name, body)
  local ok, err = pcall(body)
  if ok then print('PASS ' .. name) else failures = failures + 1; print('FAIL ' .. name .. ': ' .. tostring(err)) end
end
local function assertReset(f)
  f.drain()
  near(f.wear(), 1)
  near(f.wear(43), 0.7)
  assert(#f.syncWear > 0, 'service must synchronize the runtime')
  near(f.syncWear[1], 1) -- catches a repair queued after initFromSave.
end
test('single service resets actual wear before runtime sync', function()
  local f = fixture()
  assert(f.parts.services.startService(42, 'engine', 'engineOverhaul').ok)
  assertReset(f)
end)
test('cart overhaul resets actual wear before runtime sync', function()
  local f = fixture()
  assert(f.parts.cart.checkoutCart(42, {services = {{category = 'engine', item = 'engineOverhaul'}}}).ok)
  assertReset(f)
end)
test('paid legacy overhaul resets actual wear before runtime sync once', function()
  local f = fixture()
  f.data.maintenanceComputerState.jobs.old = {kind = 'service', category = 'engine', item = 'engineOverhaul'}
  f.parts.services.prepareVehicleState(42)
  assertReset(f)
  assert(next(f.data.maintenanceComputerState.jobs) == nil)
end)
test('off-spawn service updates saved maintenance without targeting another runtime', function()
  local f = fixture(false)
  assert(f.parts.services.startService(42, 'engine', 'engineOverhaul').ok)
  f.drain()
  near(f.data.maintenanceState.categories.engine.maintenance.engineOverhaul, 1)
  assert(#f.syncWear == 0)
  near(f.wear(), 0.7)
end)
test('oil service leaves mechanical wear untouched', function()
  local f = fixture()
  assert(f.parts.services.startService(42, 'engine', 'oilCondition').ok)
  f.drain()
  near(f.wear(), 0.7)
end)
test('legacy overhaul check reveals condition without repairing wear', function()
  local f = fixture()
  f.data.maintenanceComputerState.jobs.old = {kind = 'check', category = 'engine', item = 'engineOverhaul'}
  f.parts.services.prepareVehicleState(42)
  f.drain()
  near(f.wear(), 0.7)
  assert(f.data.maintenanceComputerState.revealed.engine.engineOverhaul.roundedPercent == 70)
end)
test('failed payment never queues a wear repair', function()
  local f = fixture()
  f.parts.quotes.calculateServicePrice = function() return 100 end
  overhaul_career_economy_payment.canPay = function() return false end
  assert(not f.parts.services.startService(42, 'engine', 'engineOverhaul').ok)
  f.drain()
  near(f.wear(), 0.7)
  near(f.data.maintenanceState.categories.engine.maintenance.engineOverhaul, 0.7)
end)
test('failed tire checkout does not repair an uncommitted cart overhaul', function()
  local f = fixture()
  overhaul_career_maintenance_tireSystem = {
    buildUiData = function() return {available = true, inspected = true, quoteRevision = 'q',
      axles = {{id = 'front', subtotal = 0}}} end,
    checkout = function() return {ok = false, message = 'fit failed'} end,
  }
  assert(not f.parts.cart.checkoutCart(42, {services = {{category = 'engine', item = 'engineOverhaul'}},
    tireAxleIds = {'front'}, quoteRevision = 'q'}).ok)
  f.drain()
  near(f.wear(), 0.7)
  near(f.data.maintenanceState.categories.engine.maintenance.engineOverhaul, 0.7)
end)
test('business ids never route to a personal inventory vehicle', function()
  local f = fixture()
  assert(f.parts.services.startServiceForBusinessVehicle(42, 'engine', 'engineOverhaul', 'taxi', 'fleet').ok)
  f.drain()
  near(f.wear(), 0.7)
  near(f.business.maintenanceState.categories.engine.maintenance.engineOverhaul, 1)
  near(f.data.maintenanceState.categories.engine.maintenance.engineOverhaul, 0.7)
end)
test('business legacy overhaul cannot repair a colliding personal inventory id', function()
  local f = fixture()
  f.business.maintenanceComputerState.jobs.old = {kind = 'service', category = 'engine', item = 'engineOverhaul'}
  f.parts.services.prepareBusinessVehicleState('fleet', 42)
  f.drain()
  near(f.wear(), 0.7)
  near(f.business.maintenanceState.categories.engine.maintenance.engineOverhaul, 1)
end)
assert(failures == 0, tostring(failures) .. ' engine overhaul service tests failed')
