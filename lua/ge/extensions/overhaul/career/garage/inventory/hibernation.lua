-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Distance hibernation for stationary personal vehicles.
-- A hibernated vehicle keeps its object, inventory binding and saved position; only simulation stops.
-- Vehicles that touch each other (couplers or overlapping boxes) sleep and wake as one cluster, and a
-- cluster sleeps only when every vehicle touching it is also a candidate. Every other inactive vehicle
-- is left alone: this part reactivates only the ids it suspended itself.
local hibernation = {}

function hibernation.new(inputs)
  -- Config ------------------------------------------------------------------------------------------

  local SETTING_KEY = 'hibernateDistantVehicles'
  local DISTANCE_SETTING_KEY = 'hibernateDistanceMeters'
  local TICK_SECONDS = 1
  local DEFAULT_SLEEP_DISTANCE_METERS = 500
  -- Wake at 60% of the sleep distance so approaching traffic wakes before it reaches the player.
  local WAKE_DISTANCE_RATIO = 0.6
  local WAKE_LOOKAHEAD_SECONDS = 8
  -- Wake must stay below sleep, or a fast approach would wake and re-sleep the same cluster each tick.
  local MIN_SLEEP_WAKE_GAP_METERS = 20
  local STATIONARY_SECONDS = 10
  local STATIONARY_SPEED_METERS_PER_SECOND = 0.5
  local MAX_CLUSTERS_PER_TICK = 3
  -- Boxes are grown slightly so a car resting just above a trailer counts as touching it.
  local TOUCH_MARGIN_METERS = 0.5
  local NO_BOX_CLEARANCE_METERS = 8
  local CARRIER_TOKENS = {
    'flatbed', 'rollback', 'tiltdeck', 'carcarrier', 'car_hauler',
    'dryvan', 'boxutility', 'containertrailer',
  }

  -- State -------------------------------------------------------------------------------------------

  -- clusters[id] = {vehIds = {...}, inventoryIds = {...}}
  local clusters = {}
  local clusterOfVehId = {}
  local nextClusterId = 0
  -- Consecutive simulated seconds each vehicle has been standing still.
  local stationarySeconds = {}
  local tickTimer = TICK_SECONDS
  -- Simulated time collected since the last sleep scan; a scan adds this, not a single frame.
  local elapsedSim = 0

  -- Queries -----------------------------------------------------------------------------------------

  local function enabled()
    local settings = overhaul_shell_settings
    return settings ~= nil and settings.getSetting(SETTING_KEY) == true
  end

  -- Read live so a changed setting applies on the next scan instead of after a restart.
  local function sleepDistanceMeters()
    local settings = overhaul_shell_settings
    local distance = settings and tonumber(settings.getSetting(DISTANCE_SETTING_KEY))
    if not distance or distance <= 0 then return DEFAULT_SLEEP_DISTANCE_METERS end
    return distance
  end

  local function wakeReachMeters(playerSpeed, sleepDistance)
    local maxWakeDistance = math.max(0, sleepDistance - MIN_SLEEP_WAKE_GAP_METERS)
    return math.min(sleepDistance * WAKE_DISTANCE_RATIO + playerSpeed * WAKE_LOOKAHEAD_SECONDS, maxWakeDistance)
  end

  local function careerActive()
    local career = overhaul_career_career
    return career ~= nil and career.isActive ~= nil and career.isActive() == true
  end

  local function playerVehicleAndPosition()
    local vehId = be:getPlayerVehicleID(0)
    local vehicle = vehId and getObjectByID(vehId) or nil
    if not vehicle then return nil, nil end
    return vehicle, vehicle:getPosition()
  end

  local function vehicleSpeed(vehicle)
    local velocity = vehicle:getVelocity()
    return velocity and velocity:length() or 0
  end

  -- A record the player can no longer rely on stays awake: it is being moved, listed or repaired.
  local function recordIsProtected(inventoryId)
    local record = inputs.vehicles[inventoryId]
    if type(record) ~= 'table' then return true end
    if record.logisticsInUse or record.brokerRentalId or record.brokerJobId then return true end
    if record.loanType ~= nil or record.listedForAuction == true then return true end
    if inputs.isDamageRestorePending and inputs.isDamageRestorePending(inventoryId) then return true end
    return false
  end

  local function isCarrier(vehicle, inventoryId)
    local record = inputs.vehicles[inventoryId] or {}
    local names = {}
    names[#names + 1] = vehicle.jbeam
    names[#names + 1] = record.model
    if type(record.config) == 'table' then names[#names + 1] = record.config.partConfigFilename end
    for _, name in ipairs(names) do
      if type(name) == 'string' then
        local normalized = name:lower()
        for _, token in ipairs(CARRIER_TOKENS) do
          if normalized:find(token, 1, true) then return true end
        end
      end
    end
    return false
  end

  -- Couplers ----------------------------------------------------------------------------------------

  local function coupledNeighbours(vehId, into)
    local links = core_vehicles and core_vehicles.attachedCouplers
    if type(links) ~= 'table' then return end
    for _, link in ipairs(links) do
      if link[1] == vehId then into[link[2]] = true
      elseif link[2] == vehId then into[link[1]] = true end
    end
  end

  -- World boxes -------------------------------------------------------------------------------------

  local function worldBox(vehId)
    if not be:getObjectOOBBIsInitialized(vehId) then return nil end
    local axes = {}
    for axis = 0, 2 do
      axes[axis + 1] = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, axis))
    end
    return {center = vec3(be:getObjectOOBBCenterXYZ(vehId)), axes = axes}
  end

  local function growAxis(axis, margin)
    local length = axis:length()
    if length <= 1e-6 then return axis end
    return axis * ((length + margin) / length)
  end

  local function boxesTouch(a, b)
    if not a or not b then return false end
    -- Without the box test, nearby centers stay conservative rather than allowing a sleeping subset.
    if type(overlapsOBB_OBB) ~= 'function' then
      return a.center:squaredDistance(b.center) <= NO_BOX_CLEARANCE_METERS * NO_BOX_CLEARANCE_METERS
    end
    local ax, bx = a.axes, b.axes
    return overlapsOBB_OBB(a.center,
      growAxis(ax[1], TOUCH_MARGIN_METERS), growAxis(ax[2], TOUCH_MARGIN_METERS), growAxis(ax[3], TOUCH_MARGIN_METERS),
      b.center, bx[1], bx[2], bx[3]) and true or false
  end

  -- True when the two vehicles share a coupler or their live boxes touch.
  local function vehiclesTouch(a, b, boxByVehId)
    if a.coupled and a.coupled[b.vehId] then return true end
    if b.coupled and b.coupled[a.vehId] then return true end
    local boxA, boxB = boxByVehId[a.vehId], boxByVehId[b.vehId]
    if not boxA or not boxB then
      local distanceSquared = a.position:squaredDistance(b.position)
      return distanceSquared <= NO_BOX_CLEARANCE_METERS * NO_BOX_CLEARANCE_METERS
    end
    return boxesTouch(boxA, boxB)
  end

  -- Clusters ----------------------------------------------------------------------------------------

  local function releaseCluster(id)
    local cluster = clusters[id]
    if not cluster then return end
    clusters[id] = nil
    for _, vehId in ipairs(cluster.vehIds) do
      if clusterOfVehId[vehId] == id then clusterOfVehId[vehId] = nil end
    end
  end

  -- Re-sends vehicle-side state that a command queued while suspended would have carried.
  local function resyncVehicle(vehId)
    local tireSystem = overhaul_career_maintenance_tireSystem
    if tireSystem and tireSystem.sendContextForVehicle then
      tireSystem.sendContextForVehicle(vehId, true)
    end
    local inventoryId = inputs.vehIdToInventoryId[vehId]
    local bridge = overhaul_vehicles_maintenanceBridge
    if inventoryId and bridge and bridge.syncVehicleMaintenance then
      bridge.syncVehicleMaintenance(inventoryId)
    end
  end

  local function wakeCluster(id, reason)
    local cluster = clusters[id]
    if not cluster then return 0 end
    local vehIds = cluster.vehIds
    releaseCluster(id)
    local woken = 0
    for _, vehId in ipairs(vehIds) do
      local vehicle = getObjectByID(vehId)
      if vehicle and not be:getObjectActive(vehId) then
        vehicle:setActive(1)
        resyncVehicle(vehId)
        woken = woken + 1
      end
    end
    log('D', 'inventory.hibernation', string.format('Woke cluster reason=%s inventoryIds=%s vehicles=%d', tostring(reason), table.concat(cluster.inventoryIds, ','), woken))
    return woken
  end

  local function wakeVehicleNow(vehId)
    local id = clusterOfVehId[vehId]
    if not id then return false end
    wakeCluster(id, 'requested')
    return true
  end

  local function wakeAll(reason)
    local ids = {}
    for id in pairs(clusters) do ids[#ids + 1] = id end
    table.sort(ids)
    local woken = 0
    for _, id in ipairs(ids) do woken = woken + wakeCluster(id, reason) end
    if reason == 'save' then
      log('I', 'inventory.hibernation', string.format('Save wake: unhibernated %d owned vehicles in %d clusters', woken, #ids))
    end
    return woken
  end

  -- Suspends every vehicle of an eligible cluster, or none when the cluster changed during the scan.
  local function suspendCluster(members)
    for _, member in ipairs(members) do
      if getObjectByID(member.vehId) ~= member.vehicle or not be:getObjectActive(member.vehId) then
        return false
      end
    end
    local vehIds, inventoryIds = {}, {}
    for _, member in ipairs(members) do
      member.vehicle:setActive(0)
      vehIds[#vehIds + 1] = member.vehId
      inventoryIds[#inventoryIds + 1] = member.inventoryId
    end
    nextClusterId = nextClusterId + 1
    clusters[nextClusterId] = {vehIds = vehIds, inventoryIds = inventoryIds}
    for _, vehId in ipairs(vehIds) do clusterOfVehId[vehId] = nextClusterId end
    log('D', 'inventory.hibernation', string.format('Suspended cluster inventoryIds=%s vehicles=%d', table.concat(inventoryIds, ','), #vehIds))
    return true
  end

  -- Frame update ------------------------------------------------------------------------------------

  local function updateSleep(dtSim, playerPos)
    local entries, entryByVehId = {}, {}
    local boxByVehId = {}
    local playerVehId = be:getPlayerVehicleID(0)
    local sleepDistance = sleepDistanceMeters()

    -- Non-owned active vehicles join the graph as blockers: a car resting on someone else's carrier
    -- must keep that whole cluster awake.
    local function addEntry(vehicle, vehId, inventoryId)
      local position = vehicle:getPosition()
      boxByVehId[vehId] = worldBox(vehId)
      local coupled = {}
      coupledNeighbours(vehId, coupled)
      local entry = {
        vehId = vehId,
        inventoryId = inventoryId,
        vehicle = vehicle,
        position = position,
        distance = position:distance(playerPos),
        coupled = coupled,
        candidate = false,
      }
      entries[#entries + 1] = entry
      entryByVehId[vehId] = entry
      return entry
    end

    for vehId, inventoryId in pairs(inputs.vehIdToInventoryId) do
      local vehicle = vehId and getObjectByID(vehId) or nil
      if vehicle and be:getObjectActive(vehId) then
        addEntry(vehicle, vehId, inventoryId)
      end
    end
    for _, vehicle in ipairs(getAllVehicles()) do
      local vehId = vehicle:getID()
      if not entryByVehId[vehId] and be:getObjectActive(vehId) then
        addEntry(vehicle, vehId, nil)
      end
    end
    table.sort(entries, function(a, b) return a.vehId < b.vehId end)

    for _, entry in ipairs(entries) do
      local vehicle, inventoryId = entry.vehicle, entry.inventoryId
      if inventoryId ~= nil then
        local moving = vehicleSpeed(vehicle) > STATIONARY_SPEED_METERS_PER_SECOND
        stationarySeconds[entry.vehId] = moving and 0 or ((stationarySeconds[entry.vehId] or 0) + dtSim)
        entry.candidate = inputs.isPersonalInventoryId(inventoryId)
          and entry.distance >= sleepDistance
          and stationarySeconds[entry.vehId] >= STATIONARY_SECONDS
          and entry.vehId ~= playerVehId
          and not vehicle:isPlayerControlled()
          and vehicle.jbeam ~= 'unicycle'
          and not isCarrier(vehicle, inventoryId)
          and not recordIsProtected(inventoryId)
          and true or false
      end
    end

    -- Every vehicle touching a candidate joins its component. A component sleeps only when all of
    -- its members are candidates, so a car on a trailer, a coupled pair or a busy lot all move as one.
    local seen = {}
    local suspended = 0
    for _, entry in ipairs(entries) do
      if entry.candidate and not seen[entry.vehId] and suspended < MAX_CLUSTERS_PER_TICK then
        local members, queue = {}, {entry}
        local eligible = true
        seen[entry.vehId] = true
        local index = 1
        while index <= #queue do
          local current = queue[index]
          members[#members + 1] = current
          if not current.candidate then eligible = false end
          for _, other in ipairs(entries) do
            if not seen[other.vehId] and vehiclesTouch(current, other, boxByVehId) then
              seen[other.vehId] = true
              queue[#queue + 1] = other
            end
          end
          index = index + 1
        end
        if eligible and suspendCluster(members) then suspended = suspended + 1 end
      end
    end
  end

  -- Wakes every cluster the player is close enough to reach before the next check.
  local function updateWake(playerPos, playerSpeed)
    local ids = {}
    local reach = wakeReachMeters(playerSpeed, sleepDistanceMeters())
    for id in pairs(clusters) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local cluster = clusters[id]
      local nearest
      for _, vehId in ipairs(cluster.vehIds) do
        local vehicle = getObjectByID(vehId)
        if vehicle then
          local distance = vehicle:getPosition():distance(playerPos)
          if not nearest or distance < nearest then nearest = distance end
        end
      end
      if not nearest or nearest <= reach then wakeCluster(id, 'proximity') end
    end
  end

  local function onUpdate(dtReal, dtSim)
    if not enabled() then
      -- Turning the setting off restores everything this part suspended.
      if next(clusters) then wakeAll('disabled') end
      return
    end
    if not careerActive() then
      if next(clusters) then wakeAll('career-inactive') end
      return
    end
    if not inputs.state.inventorySetupDone then return end
    if inputs.isVehicleRestorePending and inputs.isVehicleRestorePending() then return end
    if not dtSim or dtSim <= 0 then return end

    local playerVehicle, playerPos = playerVehicleAndPosition()
    if not playerPos then return end
    local playerSpeed = playerVehicle and vehicleSpeed(playerVehicle) or 0

    -- Waking is a short distance check against a handful of clusters, so it runs every frame to keep
    -- the window after a teleport or a fast approach to one frame.
    updateWake(playerPos, playerSpeed)

    -- Saving needs replies from vehicle Lua; do not suspend a car again after the save hook wakes it.
    local saveSystem = overhaul_career_saveSystem
    if saveSystem and saveSystem.isSaveBusy and saveSystem.isSaveBusy() then
      elapsedSim = 0
      if next(stationarySeconds) then stationarySeconds = {} end
      return
    end

    elapsedSim = elapsedSim + (tonumber(dtSim) or 0)
    tickTimer = tickTimer + (tonumber(dtReal) or 0)
    if tickTimer < TICK_SECONDS then return end
    tickTimer = tickTimer % TICK_SECONDS
    updateSleep(elapsedSim, playerPos)
    elapsedSim = 0
  end

  return {
    onUpdate = onUpdate,
    wakeAll = wakeAll,
    wakeVehicle = wakeVehicleNow,
    wakeInventoryId = function(inventoryId)
      local vehId = inputs.inventoryIdToVehId[tonumber(inventoryId)]
      return vehId ~= nil and wakeVehicleNow(vehId) or false
    end,
    isHibernated = function(vehId)
      return vehId ~= nil and clusterOfVehId[vehId] ~= nil
    end,
    -- A destroyed or respawned member ends the cluster; the surviving members resume rather than
    -- staying suspended with no record.
    onVehicleDestroyed = function(vehId)
      local id = clusterOfVehId[vehId]
      if id then wakeCluster(id, 'destroyed') end
      stationarySeconds[vehId] = nil
    end,
    onVehicleSpawned = function(vehId)
      local id = clusterOfVehId[vehId]
      if id then wakeCluster(id, 'spawned') end
      stationarySeconds[vehId] = nil
    end,
    shutdown = function()
      wakeAll('shutdown')
    end,
    diagnostics = function()
      local ids = {}
      for id in pairs(clusters) do ids[#ids + 1] = id end
      table.sort(ids)
      local out = {}
      for _, id in ipairs(ids) do
        out[#out + 1] = deepcopy(clusters[id])
      end
      return {enabled = enabled(), distanceMeters = sleepDistanceMeters(), clusters = out}
    end,
  }
end

return hibernation
