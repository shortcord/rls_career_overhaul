-- Issue #544: a pristine fresh-spawn capture must not replace the stored part conditions while a
-- saved damage restore is still pending. Runs bindings.lua against stubbed engine globals.

-- bindings pulls in the real fuelConditions library, which upstream 2.8.1 started using.
package.path = 'lua/ge/extensions/?.lua;' .. package.path

local logs, hooks, inventoryPushes, sanitized = {}, {}, {}, {}

log = function(level, tag, message)
  logs[#logs + 1] = {level = level, tag = tag, message = message}
end

local function logged(level, pattern)
  for _, entry in ipairs(logs) do
    if entry.level == level and entry.message:find(pattern, 1, true) then return entry end
  end
  return nil
end

extensions = {
  hook = function(name, ...) hooks[#hooks + 1] = {name = name, args = {...}} end,
}

local function hookCount(name)
  local count = 0
  for _, entry in ipairs(hooks) do
    if entry.name == name then count = count + 1 end
  end
  return count
end

-- Vehicle objects and the bridge ------------------------------------------------------------------

local objects = {}
local requests = {}

getObjectByID = function(vehId) return objects[vehId] end

core_vehicleBridge = {
  requestValue = function(veh, callback, name)
    requests[#requests + 1] = {vehId = veh.id, callback = callback, name = name}
  end,
}

local function answer(last, state)
  requests[last].callback({result = state})
end

local function lastStateRequest()
  for index = #requests, 1, -1 do
    if requests[index].name == 'getOverhaulInventoryVehicleState' then return index end
  end
end

local jobs = {}

core_jobsystem = {
  create = function(callback) jobs[#jobs + 1] = callback end,
}

local function runJobs()
  local running = jobs
  jobs = {}
  for _, callback in ipairs(running) do callback({sleep = function() end}) end
end

overhaul_career_parts_partInventory = {
  updatePartConditionsInInventory = function(inventoryId)
    inventoryPushes[#inventoryPushes + 1] = inventoryId
  end,
}

local saveSystem = {deferred = {}}
function saveSystem.deferSaveWork(fn) saveSystem.deferred[#saveSystem.deferred + 1] = fn end
overhaul_career_saveSystem = saveSystem

local bindings = dofile('lua/ge/extensions/overhaul/career/garage/inventory/bindings.lua')

-- Fixture -----------------------------------------------------------------------------------------

local DAMAGED = {['/pickup/bed'] = {damage = 0.97}, ['/pickup/frame'] = {damage = 0.99}}
local PRISTINE = {['/pickup/bed'] = {damage = 0}, ['/pickup/frame'] = {damage = 0}}
local RESTORED = {['/pickup/bed'] = {damage = 0.97}, ['/pickup/frame'] = {damage = 0.98}}
local INVENTORY_ID = 12
local VEH_ID = 5001

local state = {pending = true, transient = false, listed = false}
local M = {
  isDamageRestorePending = function() return state.pending end,
  isTransientBuild = function() return state.transient end,
}

local function newFixture()
  logs, hooks, inventoryPushes, sanitized = {}, {}, {}, {}
  objects, requests, jobs = {}, {}, {}
  saveSystem.deferred = {}
  state.pending, state.transient, state.listed = true, false, false
  objects[VEH_ID] = {id = VEH_ID}
  objects[VEH_ID].getID = function(self) return self.id end

  local vehicles = {[INVENTORY_ID] = {partConditions = DAMAGED, model = 'pickup'}}
  local inventoryIdToVehId = {[INVENTORY_ID] = VEH_ID}
  local batch = {deferred = {}}
  function batch:isLive() return true end

  local owner = bindings.new({
    state = {currentVehicle = INVENTORY_ID},
    M = M,
    vehicles = vehicles,
    inventoryIdToVehId = inventoryIdToVehId,
    vehIdToInventoryId = {[VEH_ID] = INVENTORY_ID},
    pendingMaintenanceSeedInventoryIds = {},
    maintenanceComputerConfig = {
      buildInitialSnapshotForMileage = function() return {seeded = true} end,
    },
    sanitizeMaintenancePartConditionsForVehicle = function(_, conditions)
      sanitized[#sanitized + 1] = conditions
      return conditions
    end,
  })
  owner.bindInputs({
    bumpGeneration = function() end,
    spawnReadiness = {removed = function() end},
    isPersonalInventoryId = function() return true end,
    isVehicleListedForAuction = function() return state.listed end,
    partConditionBatches = batch,
  })
  return owner, vehicles
end

-- Captures the live pristine shape the way a fresh spawn answers before damage is restored.
local function pristineCapture(owner)
  local done = false
  owner.updatePartConditions(VEH_ID, INVENTORY_ID, function() done = true end)
  answer(#requests, {format = 'overhaul_inventory_state_v1', partConditions = PRISTINE,
    mechanismState = {actuatorPos = 0}})
  return done
end

-- Tests -------------------------------------------------------------------------------------------

local function testPendingRestoreKeepsStoredConditions()
  local owner, vehicles = newFixture()
  local done = pristineCapture(owner)
  assert(done, 'the batch must finish even when its capture is discarded')
  assert(vehicles[INVENTORY_ID].partConditions == DAMAGED,
    'a pristine capture during a pending restore must not replace the stored damage')
  assert(vehicles[INVENTORY_ID].mechanismState == nil,
    'a halfway actuator pose must still be discarded while the restore is pending')
  assert(#inventoryPushes == 0, 'a discarded capture must not push to part inventory, got ' .. #inventoryPushes)
  assert(hookCount('onOverhaulVehiclePartConditionsChanged') == 0,
    'a discarded capture must not report changed conditions')
  assert(#sanitized == 0, 'a discarded capture must not be sanitized')
  assert(vehicles[INVENTORY_ID].maintenanceState == nil, 'a discarded capture must not seed maintenance')
  assert(#jobs == 1, 'a discarded capture must schedule one resync, got ' .. #jobs)
end

local function testRestoreCompletionCapturesRestoredConditions()
  local owner, vehicles = newFixture()
  pristineCapture(owner)
  state.pending = false
  runJobs()
  local index = lastStateRequest()
  assert(index, 'the resync must request the live conditions once the restore completes')
  answer(index, {format = 'overhaul_inventory_state_v1', partConditions = RESTORED, mechanismState = {actuatorPos = 1}})
  assert(vehicles[INVENTORY_ID].partConditions == RESTORED, 'the resync must capture the restored conditions')
  assert(vehicles[INVENTORY_ID].partConditions['/pickup/frame'].damage == 0.98,
    'the resync must capture the restored values, not the pristine ones')
  assert(vehicles[INVENTORY_ID].mechanismState ~= nil, 'the resync must also capture the settled pose')
  assert(#inventoryPushes == 1, 'the resync must push the restored conditions once, got ' .. #inventoryPushes)
  assert(hookCount('onOverhaulVehiclePartConditionsChanged') == 1, 'the resync must report the changed conditions')
  assert(#jobs == 0, 'the resync must not leave a second waiter behind')
end

local function testPendingRestoreIsNotCapturedByTheResync()
  local owner, vehicles = newFixture()
  pristineCapture(owner)
  runJobs()
  assert(#requests == 1, 'a still pending restore must not be captured, got ' .. #requests)
  assert(vehicles[INVENTORY_ID].partConditions == DAMAGED, 'a still pending restore must keep the stored damage')
  assert(#jobs == 0, 'the waiter must finish after its bounded wait')
  assert(logged('W', 'did not finish'), 'a restore that never completes must be logged')
end

local function testRepeatedSkipsShareOneWaiter()
  local owner = newFixture()
  pristineCapture(owner)
  pristineCapture(owner)
  owner.getPartConditionsCallback(PRISTINE, INVENTORY_ID)
  assert(#jobs == 1, 'every skipped capture must share one resync waiter, got ' .. #jobs)
end

local function testCaptureAfterGivingUpStillSyncs()
  local owner, vehicles = newFixture()
  pristineCapture(owner)
  runJobs()
  assert(logged('W', 'did not finish'), 'the give-up warning must be logged')
  state.pending = false
  pristineCapture(owner)
  assert(vehicles[INVENTORY_ID].partConditions == PRISTINE,
    'a capture after the restore must sync again instead of staying skipped')
end

local function testRemovedVehicleDropsTheWaiter()
  local owner, vehicles = newFixture()
  pristineCapture(owner)
  vehicles[INVENTORY_ID] = nil
  runJobs()
  assert(#requests == 1, 'a removed vehicle must not be asked for conditions again, got ' .. #requests)
  assert(not logged('E', 'Couldnt find vehicle object'), 'a removed vehicle must not log a missing object')
  assert(not logged('W', 'did not finish'), 'a removed vehicle must not warn about its restore')
end

local function testUndamagedCaptureStillSyncs()
  local owner, vehicles = newFixture()
  state.pending = false
  pristineCapture(owner)
  assert(vehicles[INVENTORY_ID].partConditions == PRISTINE, 'a normal capture must still replace the record')
  assert(#inventoryPushes == 1, 'a normal capture must still push to part inventory')
  assert(#jobs == 0, 'a normal capture must not schedule a resync')
end

testPendingRestoreKeepsStoredConditions()
testRestoreCompletionCapturesRestoredConditions()
testPendingRestoreIsNotCapturedByTheResync()
testRepeatedSkipsShareOneWaiter()
testCaptureAfterGivingUpStillSyncs()
testRemovedVehicleDropsTheWaiter()
testUndamagedCaptureStillSyncs()
print('part conditions restore guard: ok')
