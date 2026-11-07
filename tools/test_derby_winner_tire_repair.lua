-- Run with luajit tools/test_derby_winner_tire_repair.lua (or lua5.4); no engine globals required.
-- Covers issue #539: the derby winner repair must clear persisted tyre flats before the car is reloaded.
package.path = 'lua/?.lua;lua/ge/extensions/?.lua;' .. package.path

local events = {}
local function record(name, detail)
  events[#events + 1] = name .. (detail and (':' .. tostring(detail)) or '')
end

local function indexOf(prefix)
  for i, entry in ipairs(events) do
    if entry == prefix or entry:sub(1, #prefix + 1) == prefix .. ':' then return i end
  end
  return nil
end

local function resetEvents() events = {} end

-- Engine/global stubs. Each test replaces what it needs. --------------------------------------------------
local derbySessionModule = require('overhaul/events/derby/derby/derbySession')

local function baseStubs(options)
  options = options or {}
  local inventoryId = options.inventoryId or 42
  local vehicleInfo = {id = inventoryId, partConditions = {}}
  local state = {
    activeWinnerRepairInsurance = true,
    activeEntryModeCfg = {persistDamage = true},
    playerInventoryId = inventoryId,
    playerDerbyVehicleId = nil,
    playerLoanerVehicleId = nil,
  }

  be = {getObjectByID = function() return nil end}
  ui_message = function() record('ui_message') end
  core_vehicleBridge = {
    requestValue = function() record('requestValue') end,
    executeAction = function() record('executeAction') end,
  }
  overhaul_career_career = {isActive = function() return true end}

  local vehicles = {[inventoryId] = vehicleInfo}
  local inventory = {
    getVehicles = function() return vehicles end,
    getVehicleIdFromInventoryId = function() return nil end,
    setVehicleDirty = function(id) record('setVehicleDirty', id) end,
    spawnVehicle = function(id) record('inventorySpawn', id) end,
  }
  overhaul_career_garage_inventory = inventory

  overhaul_career_repair_damageManager = {
    clearDamageState = function(id) record('clearDamageState', id) end,
    saveDamageState = function(id) record('saveDamageState', id) end,
  }

  if not options.noTireSystem then
    overhaul_career_maintenance_tireSystem = {
      clearFlatsForVehicle = function(id) record('clearFlats', id); return true end,
    }
  else
    overhaul_career_maintenance_tireSystem = nil
  end

  if not options.noInsurance then
    overhaul_career_repair_insurance = {
      startRepairInstant = function(vehInfo, callback, skipSound, prepareRepair)
        record('startRepairInstant', skipSound)
        if type(prepareRepair) == 'function' then
          -- Mirrors spawn.lua: capture the outgoing snapshot, then prepare, then spawn.
          record('capture')
          local ok, prepared = pcall(prepareRepair)
          assert(ok, 'prepareRepair threw: ' .. tostring(prepared))
          assert(prepared == true, 'prepareRepair must return true or the spawn is refused')
          record('spawn')
        end
        if callback then callback(vehInfo) end
        return function() end
      end,
    }
  else
    overhaul_career_repair_insurance = nil
  end

  local services = {
    derbyState = state,
    derbyUi = {},
    derbyDamageScoring = {},
    derbyAi = {},
    derbyRewards = {},
    _log = function() end,
    saveCareerProgress = function(what) record('saveCareerProgress', what) end,
  }
  return derbySessionModule.create(services), state, vehicleInfo, inventoryId
end

local failures, count = 0, 0
local function test(name, body)
  count = count + 1
  resetEvents()
  local ok, err = pcall(body)
  if ok then print('PASS ' .. name) else
    failures = failures + 1
    print('FAIL ' .. name .. ': ' .. tostring(err))
  end
end

test('winner repair clears flats, keeps skipSound and prepares before the spawn', function()
  local session, state = baseStubs()
  assert(session.repairWinningOwnCar() == true, 'repair should be queued')

  local start = indexOf('startRepairInstant')
  assert(start, 'startRepairInstant should be called')
  assert(events[start] == 'startRepairInstant:true', 'third argument must stay skipSound=true, got ' .. events[start])

  local clear, capture, spawn = indexOf('clearFlats'), indexOf('capture'), indexOf('spawn')
  assert(clear, 'clearFlatsForVehicle must be called')
  assert(capture and spawn, 'capture and spawn should be recorded')
  assert(clear < capture, 'flats must be cleared before the outgoing capture')
  assert(capture < spawn, 'capture must precede the spawn')
  -- One clear inside the prepare hook, after the capture and before the spawn.
  local afterCapture
  for i = capture + 1, #events do
    if events[i]:sub(1, 10) == 'clearFlats' then afterCapture = i end
  end
  assert(afterCapture and afterCapture < spawn, 'hook must clear flats between capture and spawn')

  for _, entry in ipairs(events) do
    if entry:sub(1, 10) == 'clearFlats' then
      assert(entry == 'clearFlats:42', 'clearFlats must receive the player inventory id, got ' .. entry)
    end
  end
  assert(indexOf('setVehicleDirty'), 'the inventory record should still be marked dirty')
  assert(state.playerInventoryId == 42, 'state must not be mutated')
end)

test('the prepare hook still clears the damage snapshot the capture just wrote', function()
  local session = baseStubs()
  session.repairWinningOwnCar()
  local capture = indexOf('capture')
  local clearDamageAfterCapture
  for i = capture + 1, #events do
    if events[i] == 'clearDamageState:42' then clearDamageAfterCapture = i end
  end
  assert(clearDamageAfterCapture, 'damage must be cleared inside the prepare hook, not only before the capture')
end)

test('fallback spawn path still clears flats before replacing the car', function()
  local session = baseStubs({noInsurance = true})
  assert(session.repairWinningOwnCar() == true)
  local clear, spawn = indexOf('clearFlats'), indexOf('inventorySpawn')
  assert(clear, 'clearFlatsForVehicle must be called on the fallback path')
  assert(spawn, 'the inventory spawn fallback should run')
  assert(clear < spawn, 'flats must be cleared before the fallback spawn')

  local afterCapture
  for i = 1, #events do
    if events[i] == 'clearDamageState:42' then afterCapture = i end
  end
  assert(afterCapture and afterCapture < spawn, 'damage should be cleared before the fallback spawn too')
end)

test('a missing tire system is tolerated', function()
  local session = baseStubs({noTireSystem = true})
  assert(session.repairWinningOwnCar() == true, 'repair must still be queued')
  assert(indexOf('spawn'), 'the repair should still spawn the vehicle')
end)

test('a throwing tire system is tolerated and does not skip the repair', function()
  local session = baseStubs()
  overhaul_career_maintenance_tireSystem.clearFlatsForVehicle = function()
    error('tire system blew up')
  end
  assert(session.repairWinningOwnCar() == true, 'repair must still be queued')
  assert(indexOf('spawn'), 'the repair should still spawn the vehicle')
end)

test('no inventory id means no repair and no tire work', function()
  local session, state = baseStubs()
  state.playerInventoryId = nil
  assert(session.repairWinningOwnCar() == false, 'repair should be refused')
  assert(indexOf('clearFlats') == nil, 'no tyre work without an inventory id')
end)

print(string.format('%d/%d passed', count - failures, count))
os.exit(failures == 0 and 0 or 1)
