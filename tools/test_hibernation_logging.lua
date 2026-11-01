local messages = {}
log = function(level, tag, message)
  messages[#messages + 1] = {level = level, tag = tag, message = message}
end

local hibernation = dofile('lua/ge/extensions/overhaul/career/garage/inventory/hibernation.lua').new({})
hibernation.wakeAll('save')

local found = false
for _, entry in ipairs(messages) do
  if entry.tag == 'inventory.hibernation' and entry.message:lower():find('save', 1, true)
    and entry.message:find('unhibernated 0 owned vehicles', 1, true) then
    found = true
  end
end
assert(found, 'save wakeAll must log even when there are no hibernated vehicles')

local function position(x)
  return {
    distance = function(_, other) return math.abs(x - other.x) end,
    squaredDistance = function(_, other) return (x - other.x) ^ 2 end,
    x = x,
  }
end

local player = {id = 1, active = true, pos = position(0), jbeam = 'pickup'}
local owned = {id = 2, active = true, pos = position(700), jbeam = 'covet'}
for _, vehicle in ipairs({player, owned}) do
  vehicle.getID = function(self) return self.id end
  vehicle.getPosition = function(self) return self.pos end
  vehicle.getVelocity = function() return {length = function() return 0 end} end
  vehicle.isPlayerControlled = function(self) return self == player end
  vehicle.setActive = function(self, active) self.active = active == 1 end
end

be = {
  getPlayerVehicleID = function() return 1 end,
  getObjectActive = function(_, id) return (id == 1 and player or owned).active end,
  getObjectOOBBIsInitialized = function() return false end,
}
getObjectByID = function(id) return id == 1 and player or id == 2 and owned or nil end
getAllVehicles = function() return {player, owned} end
overhaul_shell_settings = {getSetting = function() return true end}
overhaul_career_career = {isActive = function() return true end}

local instance = dofile('lua/ge/extensions/overhaul/career/garage/inventory/hibernation.lua').new({
  state = {inventorySetupDone = true},
  vehIdToInventoryId = {[1] = 10, [2] = 20},
  inventoryIdToVehId = {[10] = 1, [20] = 2},
  vehicles = {[10] = {}, [20] = {}},
  isPersonalInventoryId = function() return true end,
})
for _ = 1, 11 do instance.onUpdate(1, 1) end
assert(not owned.active, 'distant owned vehicle should hibernate')
messages = {}
instance.wakeAll('save')
assert(owned.active, 'save wake must reactivate the owned vehicle')
local logged = false
for _, entry in ipairs(messages) do
  if entry.tag == 'inventory.hibernation' and entry.message:find('unhibernated 1 owned vehicles', 1, true) then
    logged = true
  end
end
assert(logged, 'save wake must report the number of reactivated owned vehicles')

overhaul_career_saveSystem = {isSaveBusy = function() return true end}
for _ = 1, 12 do instance.onUpdate(1, 1) end
assert(owned.active, 'owned vehicles must stay awake while a save is in progress')
overhaul_career_saveSystem.isSaveBusy = function() return false end
for _ = 1, 12 do instance.onUpdate(1, 1) end
assert(not owned.active, 'hibernation should resume after the save finishes')
