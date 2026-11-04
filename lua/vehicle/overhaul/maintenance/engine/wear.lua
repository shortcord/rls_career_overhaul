-- Engine component condition model based on advenginetune's combustionEngineThermalsAdvanced.lua.
-- Mirrors its setPartConditionThermals(): per-component CONDITION fractions (higher = fresher) computed
-- from distance since last service + current integrity, then stored so repairs persist until recompute.
local max = math.max
local min = math.min
local M = {}

local windows = {
  pistonWear = {startM = 30e6, endM = 2e9, minValue = 0.7},
  pistonRingWear = {startM = 30e6, endM = 1e9, minValue = 0.4},
  cylinderWallWear = {startM = 30e6, endM = 1e9, minValue = 0.6},
  oilPumpCondition = {startM = 30e6, endM = 1e9, minValue = 0.1},
  oilFilterCondition = {startM = 30e6, endM = 1e9, minValue = 0.15},
}

-- Integrity windows: condition falls to the minimum as installed integrity falls away.
local integrityWindows = {
  oilCondition = {minValue = 0.2},
  oilFilterCondition = {minValue = 0.15},
}

-- Hard-failure thresholds on installed integrity, identical to advenginetune's setPartConditionThermals.
local failureThresholds = {
  headGasketBlown = 0.3,
  pistonRingsDamaged = 0.2,
  connectingRodBearingsDamaged = 0.1,
}

-- Linearly interpolate freshValue -> wornFloor as value moves from startM to endM, clamped at both ends.
local function linearScale(value, startM, endM, freshValue, wornFloor)
  if startM == endM then return wornFloor end
  local t = min(max((value - startM) / (endM - startM), 0), 1)
  return freshValue + ((wornFloor - freshValue) * t)
end

local function clamp(value, low, high)
  if type(value) ~= "number" then return low end
  if value < low then return low end
  if value > high then return high end
  return value
end

-- Per-vehicle wear state. Scoped by inventory id so multiple career vehicles don't share/corrupt each other's
-- service history; a vehicle with no prior context seeds from its installed odometer, but once a repair has
-- been performed for it the restored baseline survives even if a tick runs before re-seeding.
local wearStateByInventoryId = {}

local function getWearState(inventoryId)
  if not wearStateByInventoryId[inventoryId] then
    -- `seeded` is set true by the first degrade call so a pre-used vehicle starts appropriately worn
    -- rather than fresh. `hadRepair` suppresses that seeding after a service, mirroring advenginetune's
    -- repairEngineParts which restores condition rather than letting absolute odometer dominate.
    wearStateByInventoryId[inventoryId] = {
      wearDistanceMetres = 0,
      seeded = false,
      hadRepair = false,
      pistonWear = 1, pistonRingWear = 1, cylinderWallWear = 1,
      oilPumpCondition = 1, oilFilterCondition = 1,
    }
  end
  return wearStateByInventoryId[inventoryId]
end

-- Degrades stored component conditions by mileage delta since last update. Returns the natural wear each
-- would reach at its current condition — i.e. how much further it degrades this tick.
M.degrade = function(input)
  input = input or {}
  local inventoryId = tonumber(input.inventoryId)
  if not inventoryId then inventoryId = 1 end
  local state = getWearState(inventoryId)

  local odometerDelta = max(tonumber(input.odometerDeltaMetres) or 0, 0)
  local integrityValue = clamp(tonumber(input.integrityValue) or 1, 0, 1)

  -- Seed from installed odometer so a pre-used vehicle starts appropriately worn rather than fresh.
  if not state.seeded then
    if not state.hadRepair and tonumber(input.odometerMetres) > state.wearDistanceMetres then
      state.wearDistanceMetres = tonumber(input.odometerMetres)
    end
    state.seeded = true
  end
  -- Charge the accumulated wear distance by this tick's mileage delta.
  state.wearDistanceMetres = min(state.wearDistanceMetres + odometerDelta, windows.pistonWear.endM)

  local pistonWear = linearScale(state.wearDistanceMetres, windows.pistonWear.startM,
      windows.pistonWear.endM, 1, windows.pistonWear.minValue) * integrityValue
  local pistonRingWear = linearScale(state.wearDistanceMetres, windows.pistonRingWear.startM,
      windows.pistonRingWear.endM, 1, windows.pistonRingWear.minValue) * integrityValue
  local cylinderWallWear = linearScale(state.wearDistanceMetres, windows.cylinderWallWear.startM,
      windows.cylinderWallWear.endM, 1, windows.cylinderWallWear.minValue) * integrityValue

  -- advenginetune's setPartConditionThermals: condition is stored (persists until recompute or repair).
  state.pistonWear = pistonWear
  state.pistonRingWear = pistonRingWear
  state.cylinderWallWear = cylinderWallWear

  -- Oil condition follows advenginetune's integrity window.
  state.oilCondition = linearScale(integrityValue, 1, 0, 1, integrityWindows.oilCondition.minValue)
  state.oilFilterCondition = linearScale(integrityValue, 1, 0,
      1, integrityWindows.oilFilterCondition.minValue)

  -- advenginetune's hard-failure thresholds on installed integrity; these now apply to every vehicle.
  local pistonRingsDamaged = integrityValue < failureThresholds.pistonRingsDamaged
  local headGasketBlown = integrityValue < failureThresholds.headGasketBlown
  local connectingRodBearingsDamaged = integrityValue < failureThresholds.connectingRodBearingsDamaged

  return {
    integrityValue = integrityValue,
    pistonWear = state.pistonWear,
    pistonRingWear = state.pistonRingWear,
    cylinderWallWear = state.cylinderWallWear,
    oilCondition = state.oilCondition,
    oilFilterCondition = state.oilFilterCondition,
    headGasketBlown = headGasketBlown,
    pistonRingsDamaged = pistonRingsDamaged,
    connectingRodBearingsDamaged = connectingRodBearingsDamaged,
  }
end

-- advenginetune's repairEngineParts hook: resets piston, ring and cylinder-wall wear plus oil pump/filter.
-- This is the career-facing service that restores mechanical condition to full. Marking freshRepairPending
-- ensures a service performed before any degradation tick isn't undone by re-seeding from installed odometer.
M.repairEngineParts = function(input)
  input = input or {}
  local inventoryId = tonumber(input.inventoryId) or nil
  if not inventoryId then return M.repairEngineParts({inventoryId = 1}) end
  local state = getWearState(inventoryId)
  -- Mark that a service has been performed so installed odometer never re-seeds this vehicle's baseline.
  state.hadRepair = true
  state.wearDistanceMetres = 0
  state.pistonWear = 1
  state.pistonRingWear = 1
  state.cylinderWallWear = 1
  state.oilPumpCondition = 1
  state.oilFilterCondition = 1
end

-- advenginetune's repairPistonRings hook: resets ring and cylinder-wall wear.
M.repairPistonRings = function(input)
  input = input or {}
  local inventoryId = tonumber(input.inventoryId) or nil
  if not inventoryId then return M.repairPistonRings({inventoryId = 1}) end
  getWearState(inventoryId).wearDistanceMetres = 0
  getWearState(inventoryId).pistonRingWear = 1
  getWearState(inventoryId).cylinderWallWear = 1
end

-- Hard-failure thresholds on installed integrity, identical to advenginetune's setPartConditionThermals.
M.failureThresholds = failureThresholds

return M
