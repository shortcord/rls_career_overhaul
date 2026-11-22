-- #536: a taxi ride must not end a marketplace sale.
-- Runs the real tether and inspectVehicle modules against stubbed engine globals (luajit or lua5.4),
-- from the repository root: lua5.4 tools/test_536_taxi_sale_tether.lua

-- inspectVehicle pulls real libraries (freeze, ...); capabilities stays stubbed via package.loaded.
package.path = 'lua/ge/extensions/?.lua;' .. package.path

local inspectPath = 'lua/ge/extensions/overhaul/career/market/inspectVehicle.lua'
local tetherPath = 'lua/ge/extensions/overhaul/career/maintenance/tether.lua'

local failures = 0
local function check(ok, label)
  if ok then
    print('ok   ' .. label)
  else
    failures = failures + 1
    print('FAIL ' .. label)
  end
end

-- Vectors -----------------------------------------------------------------------------------------

local Vec = {}
Vec.__index = Vec
local function vec3(x, y, z)
  return setmetatable({x = x or 0, y = y or 0, z = z or 0}, Vec)
end
function Vec:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
function Vec:distance(other) return (self - other):length() end
function Vec:setSub2(a, b) self.x, self.y, self.z = a.x - b.x, a.y - b.y, a.z - b.z end
Vec.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end

-- World -------------------------------------------------------------------------------------------

local function newWorld(opts)
  opts = opts or {}
  local world = {
    messages = {},
    flagged = {},
    pathLength = opts.pathLength or 5000,
    taxiRide = false,
    objects = {},
    deleteCalls = {},
  }

  local function makeVehicle(id, x)
    local veh = {id = id, pos = vec3(x, 0, 0)}
    function veh:getID() return self.id end
    function veh:getPosition() return self.pos end
    function veh:queueLuaCommand() end
    function veh:delete() world.deleteCalls[#world.deleteCalls + 1] = self.id end
    return veh
  end

  local carId = 100
  local car = makeVehicle(carId, 0)
  world.objects[carId] = car
  local player = makeVehicle(1, 0)
  world.player = player

  local parkingSpot = makeVehicle(0, 0) -- just a position holder
  parkingSpot.name = 'spot1'
  parkingSpot.pos = vec3(0, 0, 0)
  parkingSpot.hasAnyVehicles = function() return false end
  parkingSpot.moveResetVehicleTo = function() end

  local listing = {
    shopId = 'shop1', key = 'base', model_key = 'covet', sellerId = 'private',
    sellerName = 'Seller', parkingSpotName = 'spot1',
    Brand = 'Ibishu', Name = 'Covet', Value = 5000, wearMileage = 1000,
  }

  -- Engine doubles ---------------------------------------------------------------------------------

  getPlayerVehicle = function() return world.player end
  getObjectByID = function(id) return world.objects[id] end
  scenetree = {findObjectById = function(id) return world.objects[id] end}
  log = function() end
  _tr = function(text) return text end
  ui_message = function(text) world.messages[#world.messages + 1] = text end
  castRayStatic = function() return 999 end
  rawset(_G, 'vec3', vec3) -- the modules read the engine's global vector constructor

  core_vehicleBridge = {executeAction = function() end, requestValue = function() end}
  gameplay_rawPois = {clear = function() end}
  extensions = {hookUpdate = function() end}

  -- engine globals the maintenance modules rely on
  nop = function() end
  tableFindKey = function(list, value)
    for i, entry in ipairs(list) do
      if entry == value then return i end
    end
    return nil
  end
  arrayReverse = function(list)
    local out = {}
    for i = #list, 1, -1 do out[#out + 1] = list[i] end
    return out
  end

  local lastPathTarget
  core_groundMarkers = {
    setPath = function(pos) lastPathTarget = pos return {token = true} end,
    getTargetPos = function() return lastPathTarget end,
    getPathLength = function() return world.pathLength end,
    clearOwnedPath = function() return true end,
  }

  local markers = {claim = function() end, release = function() end}
  package.loaded['overhaul/lib/platform/capabilities'] = {
    get = function() return markers end,
  }

  core_jobsystem = {
    create = function(fn)
      local job = {sleep = function() end}
      fn(job)
    end,
  }
  core_vehicles = {
    spawnNewVehicle = function()
      local spawned = makeVehicle(carId, 0)
      world.objects[carId] = spawned
      return spawned
    end,
  }

  overhaul_career_maintenance_tireSystem = {
    registerInspectionVehicle = function() end, unregisterInspectionVehicle = function() end,
  }
  overhaul_vehicles_maintenanceBridge = {
    registerInspectionVehicle = function() end, unregisterInspectionVehicle = function() end,
  }
  overhaul_career_market_vehicleShopping = {
    getCurrentSellerId = function() return 'private' end,
    isOnlineSellerId = function() return false end,
    getVehicleInfoByShopId = function() return listing end,
    getVisualValueFromMileage = function() return 0.5 end,
    openPurchaseMenu = function() end,
    buySpawnedVehicle = function() return true end,
  }
  overhaul_integration_services_parking = {
    getParkingSpots = function() return {byName = {spot1 = parkingSpot}} end,
  }
  overhaul_career_career = {
    isActive = function() return true end,
    closeAllMenus = function() end,
    hasBoughtStarterVehicle = function() return true end,
  }
  overhaul_career_garage_vehicleDeletionService = {
    flagForDeletion = function(vehId) world.flagged[#world.flagged + 1] = vehId end,
  }
  overhaul_career_market_testDrive = {
    isActive = function() return false end,
    abandonTestDrive = function() end,
    start = function() end,
  }
  overhaul_integration_services_markerInteraction = {closeViewDetailPrompt = function() end}
  overhaul_integration_services_taxi = {
    isTaxiRideActive = function() return world.taxiRide end,
  }

  world.tether = dofile(tetherPath)
  overhaul_career_maintenance_tether = world.tether
  world.inspect = dofile(inspectPath)
  world.listing = listing
  world.carId = carId
  world.car = car

  -- Simulation helpers -----------------------------------------------------------------------------

  function world.movePlayer(x)
    world.player.pos = vec3(x, 0, 0)
  end

  -- one frame: the inspection update first, then the tether service (as the hooks do)
  function world.tick(dtSim)
    world.inspect.onUpdate(dtSim or 0.1, dtSim or 0.1, dtSim or 0.1)
    if world.tether.onUpdate then world.tether.onUpdate() end
  end

  function world.ticks(count, dtSim)
    for _ = 1, count do world.tick(dtSim) end
  end

  function world.message(pattern)
    for _, text in ipairs(world.messages) do
      if tostring(text):find(pattern, 1, true) then return text end
    end
    return nil
  end

  function world.startSale()
    return world.inspect.startInspection(listing, false, {sleep = function() end}, nil)
  end

  return world
end

-- Scenario A: the taxi drives past the listed car before the player is anywhere near it ----------
-- The arrival check must not arm the sale while the player is a passenger: a cab passing within
-- ARRIVE_TO_VEH_INSPECTION_DIST (20 m) used to arm the 25 m sale tether, which the same cab then
-- broke a second later ("You have left the sale").

do
  local w = newWorld()
  assert(w.startSale() == true, 'sale should start')
  w.taxiRide = true
  w.movePlayer(15) -- cab routing passes 15 m behind the car
  w.ticks(5)
  check(#w.flagged == 0, 'A1 no release while the cab passes the car')
  check(next(w.messages) == nil, 'A2 no leave-sale message while the cab passes the car')

  w.movePlayer(120) -- cab continues, ride still active
  w.ticks(5)
  check(#w.flagged == 0, 'A3 no release while the cab drives on')

  w.taxiRide = false -- player climbs out 120 m away: no tether was ever armed from the cab
  w.ticks(5)
  check(#w.flagged == 0, 'A4 sale survives the dropoff; the arrival in the cab did not arm it')
  check(w.inspect.getSpawnedVehicleInfo() ~= nil, 'A5 inspection state still holds the car')
end

-- Scenario B: the inspection timer must not run out while the player is a passenger --------------

do
  local w = newWorld({pathLength = 300}) -- 60 s to reach the car
  w.startSale()
  w.taxiRide = true
  w.movePlayer(120)
  w.ticks(40, 2) -- 80 s of sim time in the cab
  check(w.message('sellerTimedOut') == nil, 'B1 cab time does not spend the inspection timer')
  check(w.inspect.getSpawnedVehicleInfo() ~= nil, 'B2 sale alive after a long ride')

  w.taxiRide = false -- on foot, still far away: the timer runs again
  w.ticks(40, 2)
  check(w.message('sellerTimedOut') ~= nil, 'B3 seller timeout still fires once the ride is over')
  check(#w.flagged == 1, 'B4 timed-out sale is released')
end

-- Scenario C: sale armed at the car, then the player leaves by cab -------------------------------
-- Upstream 2.8.1 dropped the distance sale tether: distance only closes the purchase menu, so a cab
-- ride must not invalidate the inspection either.

do
  local w = newWorld()
  w.startSale()
  w.movePlayer(15) -- player walks up to the car; the inspection arms here
  w.ticks(2)
  check(#w.flagged == 0, 'C1 sale still held at the car')

  w.taxiRide = true
  w.movePlayer(100) -- the cab takes the player away
  w.ticks(10)
  check(#w.flagged == 0, 'C2 sale survives the ride')
  check(w.message('leftSale') == nil, 'C3 no leave-sale message during the ride')

  w.taxiRide = false -- dropped off 100 m away
  w.ticks(2)
  check(#w.flagged == 0, 'C4 the dropoff does not invalidate the sale')
  check(w.inspect.getSpawnedVehicleInfo() ~= nil, 'C5 inspection still holds the car')
end

-- Scenario D: driving away normally also keeps the inspection (no taxi involved) -----------------
-- Only an explicit lifecycle action ends it now: seller timeout, the listed car moving, purchase.

do
  local w = newWorld()
  w.startSale()
  w.movePlayer(15)
  w.ticks(2)
  check(#w.flagged == 0, 'D1 sale armed at the car')

  w.movePlayer(100) -- player drives their own car away
  w.ticks(2)
  check(#w.flagged == 0, 'D2 plain drive-away no longer releases the sale')
  check(w.message('leftSale') == nil, 'D3 no leave-sale message on drive-away')
  check(w.inspect.getSpawnedVehicleInfo() ~= nil, 'D4 inspection still holds the car')
end

-- Scenario E: the vehicle tether still breaks by distance ----------------------------------------
-- Upstream 2.8.1 dropped the sale tether and its suppression predicate, so the vehicle tether is
-- back to its stock contract: inside the radius it holds, outside it fires.

do
  local w = newWorld()
  local fired = 0
  w.tether.startVehicleTether(w.carId, 25, false, function() fired = fired + 1 end)
  w.movePlayer(10)
  w.tether.onUpdate()
  check(fired == 0, 'E1 tether holds inside its radius')

  w.movePlayer(60)
  w.tether.onUpdate()
  check(fired == 1, 'E2 the vehicle tether breaks by distance')
end

print('')
if failures > 0 then
  print(failures .. ' check(s) failed')
  os.exit(1)
end
print('all checks passed')
