local M = {}

M.dependencies = {
  "career_career",
  "career_saveSystem",
  "career_modules_inventory",
  "career_modules_payment",
  "career_modules_playerAttributes",
  "career_modules_valueCalculator",
  "career_modules_difficultyMode",
  "career_modules_delivery_general",
  "career_modules_delivery_parcelManager",
  "career_modules_insurance_insurance"
}

local configPath = "/levels/skeleton_coast/dakar/dakarConfig.json"
local saveFile = "/career/rls_career/skeletonCoastDakar.json"
local config
local sites
local spotsByName = {}
local checkpointPool = {}
local state = {
  phase = "idle",
  settings = {
    skipIntro = false
  },
  stats = {
    totalCompletions = 0,
    totalWins = 0,
    noRepairCompletions = 0,
    classCompletions = {},
    claimedAccolades = {}
  }
}
local phoneDirtyTimer = 0
local cargoIdBase = 900000000
local startPromptOpen = false
local activeCheckpointMarker
local activeCheckpointMarkerId
local enrichRoute

local function hideStartOverlay()
  if guihooks and guihooks.trigger then guihooks.trigger("DakarStartUi", { visible = false }) end
end

local function hideFinishOverlay()
  if guihooks and guihooks.trigger then guihooks.trigger("DakarFinishUi", { visible = false }) end
end

local function hideCompassOverlay()
  if guihooks and guihooks.trigger then guihooks.trigger("DakarCompassUi", { visible = false }) end
end

local function clearCheckpointMarker()
  if activeCheckpointMarker then
    activeCheckpointMarker:delete()
    activeCheckpointMarker = nil
    activeCheckpointMarkerId = nil
  end
end

local function startsWith(value, prefix)
  return type(value) == "string" and value:sub(1, #prefix) == prefix
end

local function isDakarCheckpointSpot(spot)
  return spot and startsWith(spot.id, config.checkpointNamePrefix or "dakarCheckpoint")
end

local function keys(tbl)
  local ret = {}
  for key, _ in pairs(tbl or {}) do table.insert(ret, key) end
  return ret
end

local function notify(msg, category)
  ui_message(msg, 5, category or "info", category or "info")
end

local function loadConfig()
  config = config or jsonReadFile(configPath)
  return config
end

local function asVec3(pos)
  if type(pos) == "table" then return vec3(pos[1] or 0, pos[2] or 0, pos[3] or 0) end
  return pos or vec3()
end

local function getFirstTag(spot)
  local tags = spot.customFields and spot.customFields.tags
  if type(tags) == "table" then
    return tags[1] or tags[0]
  end
  return nil
end

local function resolveCheckpointImage(label)
  local dir = config.checkpointImageDir or ""
  local extension = config.checkpointImageExtension or ".png"
  local fallback = dir .. label .. extension
  if not FS or not FS.fileExists then return fallback end

  local extensions = { extension, ".jpg", ".jpeg", ".png" }
  local checked = {}
  for _, ext in ipairs(extensions) do
    if ext and not checked[ext] then
      checked[ext] = true
      local path = dir .. label .. ext
      if FS:fileExists(path) then return path end
    end
  end

  return fallback
end

local function sanitizeSpot(spot)
  local label = getFirstTag(spot) or spot.name
  return {
    id = spot.name,
    name = label,
    pos = asVec3(spot.pos),
    image = resolveCheckpointImage(label)
  }
end

local function loadSites()
  if sites then return end
  loadConfig()
  sites = jsonReadFile(config.sitesFile) or {}
  spotsByName = {}
  checkpointPool = {}
  for _, raw in ipairs(sites.parkingSpots or {}) do
    local spot = sanitizeSpot(raw)
    spotsByName[spot.id] = spot
    if startsWith(spot.id, config.checkpointNamePrefix or "dakarCheckpoint") then
      table.insert(checkpointPool, spot)
    end
  end
end

local function savePath()
  if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then return nil end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  return currentSavePath and (currentSavePath .. saveFile) or nil
end

local function rebuildActiveRoute(active)
  if not active or active.route then return end
  loadSites()
  local route = {}
  for _, id in ipairs(active.routeIds or {}) do
    if spotsByName[id] then table.insert(route, spotsByName[id]) end
  end
  active.route = enrichRoute(route)
end

local function encodeForSave()
  local liveRoute = state.active and state.active.route or nil
  if state.active then state.active.route = nil end
  local payload = deepcopy(state)
  if state.active then state.active.route = liveRoute end
  if payload.active and liveRoute then
    payload.active.routeIds = {}
    for _, spot in ipairs(liveRoute) do
      table.insert(payload.active.routeIds, spot.id)
    end
  end
  return payload
end

local function ensureStats()
  state.settings = state.settings or {}
  state.settings.skipIntro = state.settings.skipIntro == true
  state.stats = state.stats or {}
  state.stats.totalCompletions = state.stats.totalCompletions or 0
  state.stats.totalWins = state.stats.totalWins or 0
  state.stats.noRepairCompletions = state.stats.noRepairCompletions or 0
  state.stats.classCompletions = state.stats.classCompletions or {}
  state.stats.claimedAccolades = state.stats.claimedAccolades or {}
end

local function saveState()
  ensureStats()
  local path = savePath()
  if not path then return end
  career_saveSystem.jsonWriteFileSafe(path, encodeForSave(), true)
end

local function loadState()
  local path = savePath()
  local loaded = path and jsonReadFile(path) or nil
  if loaded then state = loaded end
  ensureStats()
  loadConfig()
  rebuildActiveRoute(state.active)
  if config.failure and config.failure.failActiveOnLoad and state.phase == "active" then
    state.lastFailure = { reason = "reload", time = os.time() }
    state.phase = "failed"
    state.active = nil
    hideCompassOverlay()
    saveState()
  end
end

local function currentInventoryId()
  local veh = getPlayerVehicle(0)
  return veh and career_modules_inventory.getInventoryIdFromVehicleId(veh:getID()) or career_modules_inventory.getCurrentVehicle()
end

local function currentVehicleInfo()
  local invId = currentInventoryId()
  local vehInfo = invId and career_modules_inventory.getVehicle(invId) or nil
  local veh = getPlayerVehicle(0)
  return invId, vehInfo, veh
end

local function getVehicleValue(invId)
  if career_modules_valueCalculator and career_modules_valueCalculator.getInventoryVehicleValue then
    return career_modules_valueCalculator.getInventoryVehicleValue(invId) or 0
  end
  local veh = invId and career_modules_inventory.getVehicle(invId)
  return (veh and (veh.Value or veh.value or veh.configBaseValue)) or 1000
end

local function readInfo(model)
  return model and jsonReadFile("/vehicles/" .. model .. "/info.json") or nil
end

local function configKeyFromPath(value)
  if type(value) ~= "string" then return nil end
  local key = value:match("([^/\\]+)%.pc$") or value:match("([^/\\]+)$")
  return key ~= "" and key or nil
end

local function getConfigKey(vehInfo, veh)
  local vehicleConfig = vehInfo and vehInfo.config
  local candidates = {
    vehicleConfig and vehicleConfig.partConfigFilename,
    vehicleConfig and vehicleConfig.partConfig,
    vehicleConfig and vehicleConfig.path,
    vehInfo and vehInfo.configKey,
    vehInfo and vehInfo.key,
    veh and veh.partConfig
  }

  for _, candidate in ipairs(candidates) do
    local key = configKeyFromPath(candidate)
    if key then return key end
  end
  return nil
end

local function readConfigInfo(model, configKey)
  return model and configKey and jsonReadFile("/vehicles/" .. model .. "/info_" .. configKey .. ".json") or nil
end

local function bodyStyleLookup(info)
  local lookup = {}
  local raw = info and (info["Body Style"] or info["bodyStyle"] or info["BodyStyle"])
  if type(raw) == "string" then lookup[raw] = true end
  if type(raw) == "table" then
    for _, v in pairs(raw) do lookup[v] = true end
  end
  return lookup
end

local function detectClass()
  loadConfig()
  local invId, vehInfo, veh = currentVehicleInfo()
  local model = vehInfo and (vehInfo.model or vehInfo.modelKey)
  local configKey = getConfigKey(vehInfo, veh)
  local info = readConfigInfo(model, configKey) or readInfo(model)
  local bodyStyles = bodyStyleLookup(info)

  for _, classId in ipairs(config.classOrder or {"Heavy", "SSV", "Raid", "Unlimited"}) do
    local rule = config.classes[classId]
    for _, m in ipairs(rule.models or {}) do
      if model == m then
        return {
          id = classId,
          label = rule.label or classId,
          rule = rule,
          model = model,
          configKey = configKey,
          bodyStyles = keys(bodyStyles),
          inventoryId = invId,
          vehicleName = vehInfo and (vehInfo.niceName or vehInfo.model) or "Current Vehicle",
          vehicleValue = getVehicleValue(invId)
        }
      end
    end
  end

  for _, classId in ipairs(config.classOrder or {"Heavy", "SSV", "Raid", "Unlimited"}) do
    local rule = config.classes[classId]
    local matches = classId == "Unlimited"
    for _, style in ipairs(rule.bodyStyles or {}) do
      matches = matches or bodyStyles[style]
    end
    if matches then
      return {
        id = classId,
        label = rule.label or classId,
        rule = rule,
        model = model,
        configKey = configKey,
        bodyStyles = keys(bodyStyles),
        inventoryId = invId,
        vehicleName = vehInfo and (vehInfo.niceName or vehInfo.model) or "Current Vehicle",
        vehicleValue = getVehicleValue(invId)
      }
    end
  end
end

local function getPlayerCargoContainers(callback)
  if not career_modules_delivery_general or not career_modules_delivery_general.getNearbyVehicleCargoContainers then
    callback({})
    return
  end
  career_modules_delivery_general.getNearbyVehicleCargoContainers(callback)
end

local function getRepairContainers(containers, vehId)
  local valid = {}
  local totalSlots = 0
  for _, con in ipairs(containers or {}) do
    if con.vehId == vehId and con.cargoTypesLookup and con.cargoTypesLookup.parcel and (con.freeCargoSlots or 0) > 0 then
      table.insert(valid, con)
      totalSlots = totalSlots + (con.freeCargoSlots or 0)
    end
  end
  table.sort(valid, function(a, b) return (a.freeCargoSlots or 0) > (b.freeCargoSlots or 0) end)
  return valid, totalSlots
end

local function payMoney(amount, label)
  local cost = { money = { amount = amount, canBeNegative = false } }
  if career_modules_payment.canPay and not career_modules_payment.canPay(cost) then return false end
  career_modules_payment.pay(cost, { label = label or "Dakar event sign-up" })
  return true
end

local function canPayMoney(amount)
  if amount <= 0 then return true end
  local cost = { money = { amount = amount, canBeNegative = false } }
  return not career_modules_payment.canPay or career_modules_payment.canPay(cost)
end

local function addMoney(amount, label)
  career_modules_playerAttributes.addAttributes({ money = amount }, { label = label or "Dakar reward", tags = { "gameplay", "dakar" } })
end

local function scaleRewardMoney(amount)
  amount = math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
  if career_modules_difficultyMode and career_modules_difficultyMode.scaleFlatRewards then
    local reward = { money = amount }
    career_modules_difficultyMode.scaleFlatRewards(reward, { includeMoney = true })
    return math.max(0, math.floor((tonumber(reward.money) or amount) + 0.5))
  end
  return amount
end

local function addRepairCargo(containers, count)
  local ids = {}
  if not career_modules_delivery_parcelManager or not career_modules_delivery_parcelManager.addCargo then return ids end
  local remaining = count
  for _, container in ipairs(containers or {}) do
    local kitsHere = math.min(remaining, math.floor((container.freeCargoSlots or 0) / config.repairKit.slots))
    for _ = 1, kitsHere do
      cargoIdBase = cargoIdBase + 1
      local cargo = {
        id = cargoIdBase,
        name = "Dakar Repair Kit",
        type = "parcel",
        slots = config.repairKit.slots,
        weight = config.repairKit.weightKg,
        location = deepcopy(container.location),
        origin = { type = "dakarRegistration" },
        destination = { type = "dakarEvent" },
        offerExpiresAt = math.huge,
        generatedAtTimestamp = os.time(),
        data = { dakarRepairKit = true },
        automaticDropOff = false,
        hiddenInFacility = true,
        modifiers = {},
        rewards = { money = 0 }
      }
      career_modules_delivery_parcelManager.addCargo(cargo)
      table.insert(ids, cargo.id)
    end
    remaining = remaining - kitsHere
    if remaining <= 0 then break end
  end
  if career_modules_delivery_general and career_modules_delivery_general.requestUpdateContainerWeights then
    career_modules_delivery_general.requestUpdateContainerWeights()
  end
  return ids
end

local function removeRepairCargo(id)
  if career_modules_delivery_parcelManager and career_modules_delivery_parcelManager.getCargoById then
    local cargo = career_modules_delivery_parcelManager.getCargoById(id)
    if cargo then
      cargo.location = { type = "delete" }
      cargo.data = cargo.data or {}
      cargo.data.delivered = true
    end
  end
  if career_modules_delivery_general and career_modules_delivery_general.requestUpdateContainerWeights then
    career_modules_delivery_general.requestUpdateContainerWeights()
  end
end

local function dist(a, b)
  return (a.pos - b.pos):length()
end

local function normalizedDegrees(degrees)
  degrees = tonumber(degrees) or 0
  degrees = degrees % 360
  if degrees < 0 then degrees = degrees + 360 end
  return math.floor(degrees + 0.5) % 360
end

local function bearingBetween(fromSpot, toSpot)
  if not fromSpot or not toSpot then return nil end
  local delta = toSpot.pos - fromSpot.pos
  return normalizedDegrees(math.deg(math.atan2(delta.x, delta.y)))
end

local function headingFromVector(vec)
  if not vec then return nil end
  return normalizedDegrees(math.deg(math.atan2(vec.x, vec.y)))
end

local function formatHeading(degrees)
  if degrees == nil then return "---" end
  return string.format("%03d\194\176", normalizedDegrees(degrees))
end

function enrichRoute(route)
  loadSites()
  local enriched = {}
  local last = spotsByName[config.startSpot]
  for _, raw in ipairs(route or {}) do
    local cp = deepcopy(raw)
    cp.headingDegrees = bearingBetween(last, cp)
    cp.headingText = formatHeading(cp.headingDegrees)
    table.insert(enriched, cp)
    last = cp
  end
  return enriched
end

local function shuffleCopy(list)
  local copy = deepcopy(list)
  arrayShuffle(copy)
  return copy
end

local function buildRoute(classRule)
  loadSites()
  local startSpot = spotsByName[config.startSpot]
  local finishSpot = spotsByName[config.finishSpot]
  local minSpacing = classRule.minSpacingMeters or 1000
  local endpointMinSpacing = classRule.endpointMinSpacingMeters or minSpacing
  local checkpointCount = classRule.checkpointCount or 3

  for _ = 1, 100 do
    local picked = {}
    for _, cp in ipairs(shuffleCopy(checkpointPool)) do
      local ok = dist(cp, startSpot) >= endpointMinSpacing and dist(cp, finishSpot) >= endpointMinSpacing
      for _, prior in ipairs(picked) do
        ok = ok and dist(cp, prior) >= minSpacing
      end
      if ok then table.insert(picked, cp) end
      if #picked >= checkpointCount then break end
    end
    if #picked >= checkpointCount then
      table.insert(picked, finishSpot)
      return enrichRoute(picked)
    end
  end
end

local function routeDistance(route)
  local startSpot = spotsByName[config.startSpot]
  local last = startSpot
  local total = 0
  for _, cp in ipairs(route or {}) do
    total = total + dist(last, cp)
    last = cp
  end
  return total
end

local function targetTime(distanceMeters)
  local first = config.rewards and config.rewards.placements and config.rewards.placements[1] or {}
  local secondsPerKm = first.secondsPerKm or config.rewards.targetSecondsPerKm or 45
  return (distanceMeters / 1000) * secondsPerKm
end

local function placementFor(finalSeconds, distanceMeters, targetSeconds)
  local distanceKm = math.max(0, (tonumber(distanceMeters) or 0) / 1000)
  for _, placement in ipairs(config.rewards.placements or {}) do
    if placement.secondsPerKm then
      if finalSeconds <= distanceKm * placement.secondsPerKm then return placement end
    elseif finalSeconds <= (targetSeconds or 0) + (placement.lateSeconds or 0) then
      return placement
    end
  end
  return { id = "top10", label = "Finished", bonusFactor = 0 }
end

local function formatSeconds(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function formatDistanceMeters(meters)
  meters = tonumber(meters) or 0
  if meters >= 1000 then return string.format("%.1f km", meters / 1000) end
  return tostring(math.max(0, math.floor(meters + 0.5))) .. " m"
end

local function emitDakarNotification(title, message, meta, image, ttl)
  if not guihooks or not guihooks.trigger then return end
  guihooks.trigger("PhoneLockNotification", {
    title = title or "Dakar",
    message = message or "",
    kind = "dakar",
    ttl = ttl or 8,
    meta = meta or "",
    source = "Dakar",
    image = image,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }
  })
end

local function emitStartNotification()
  loadSites()
  local veh = getPlayerVehicle(0)
  local startSpot = spotsByName[config.startSpot]
  local meters = (veh and startSpot) and (startSpot.pos - veh:getPosition()):length() or nil
  emitDakarNotification(
    "Dakar Signed Up",
    "Drive to the starting line.",
    meters and formatDistanceMeters(meters) or "",
    resolveCheckpointImage("Dakar Start"),
    9
  )
end

local function emitCheckpointNotification()
  local active = state.active
  local cp = active and active.route and active.route[active.index]
  if not cp then return end
  local veh = getPlayerVehicle(0)
  local meters = veh and (cp.pos - veh:getPosition()):length() or nil
  local count = active.route and #active.route or 0
  local metaParts = { string.format("%d/%d", active.index or 1, count) }
  if meters then table.insert(metaParts, formatDistanceMeters(meters)) end
  if config.showHeadingClue ~= false then table.insert(metaParts, cp.headingText or formatHeading(cp.headingDegrees)) end
  emitDakarNotification(
    "Next Checkpoint",
    cp.name or "Checkpoint",
    table.concat(metaParts, " - "),
    cp.image,
    10
  )
end

local function compassPayload()
  local active = state.active
  local cp = active and active.route and active.route[active.index]
  if state.phase ~= "active" or not active or not cp then
    return { visible = false }
  end
  local veh = getPlayerVehicle(0)
  local vehHeading = veh and headingFromVector(veh:getDirectionVector()) or nil
  local distance = veh and (cp.pos - veh:getPosition()):length() or nil
  return {
    visible = true,
    payload = {
      vehicleHeadingDegrees = vehHeading,
      vehicleHeadingText = formatHeading(vehHeading),
      clueHeadingDegrees = cp.headingDegrees,
      clueHeadingText = cp.headingText or formatHeading(cp.headingDegrees),
      checkpointName = cp.name or "Checkpoint",
      checkpointIndex = active.index or 1,
      checkpointCount = active.route and #active.route or 0,
      distanceMeters = distance,
      distanceText = distance and formatDistanceMeters(distance) or ""
    }
  }
end

local function emitCompass()
  if guihooks and guihooks.trigger then guihooks.trigger("DakarCompassUi", compassPayload()) end
end

local function phonePayload()
  local active = state.active
  local cp = active and active.route and active.route[active.index]
  local veh = getPlayerVehicle(0)
  local distance = (cp and veh) and (cp.pos - veh:getPosition()):length() or nil
  local startSpot = spotsByName[config.startSpot]
  local startDistance = (state.phase == "signedUp" and startSpot and veh) and (startSpot.pos - veh:getPosition()):length() or nil
  return {
    phase = state.phase,
    active = active ~= nil,
    pending = state.phase == "signedUp",
    start = startDistance and {
      distanceMeters = startDistance,
      atStart = startDistance <= (config.startRadiusMeters or 18)
    } or nil,
    checkpoint = cp and {
      name = cp.name,
      image = cp.image,
      index = active.index,
      count = #active.route,
      distanceMeters = distance,
      headingDegrees = cp.headingDegrees,
      headingText = cp.headingText or formatHeading(cp.headingDegrees)
    } or nil,
    repairsLeft = active and active.repairsLeft or (state.pending and state.pending.repairsLeft or 0),
    canRepair = active and active.repairsLeft and active.repairsLeft > 0 or false,
    lastResult = state.lastResult
  }
end

local function emitPhone()
  guihooks.trigger("dakarPhoneData", phonePayload())
end

local function accoladeProgress(acc)
  ensureStats()
  if acc.stat == "classCompletions" then
    return state.stats.classCompletions[acc.class] or 0
  end
  return state.stats[acc.stat] or 0
end

local function formatMoney(amount)
  amount = math.floor((tonumber(amount) or 0) + 0.5)
  local str = tostring(amount)
  while true do
    local formatted, count = str:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    str = formatted
    if count == 0 then break end
  end
  return "$" .. str
end

local function accoladeRewardMoney(acc)
  local reward = acc and acc.reward or {}
  return tonumber(reward.money) or 0
end

local function menuPayload()
  loadConfig()
  local classInfo = detectClass()
  local invId, vehInfo, veh = currentVehicleInfo()
  local setupBlockedReason = (not veh or not invId) and "You must be in your race vehicle." or nil
  local kit = config.repairKit
  local kitCost = math.floor(((classInfo and classInfo.vehicleValue) or 0) * kit.costVehicleValueFactor)
  local containerSlots = 0
  local containerCount = 0
  local maxKitsByCargo = 0
  local veh = getPlayerVehicle(0)
  local cached = career_modules_delivery_general and career_modules_delivery_general.getMostRecentCargoContainerData and career_modules_delivery_general.getMostRecentCargoContainerData() or {}
  for _, con in ipairs(cached or {}) do
    if veh and con.vehId == veh:getID() and con.cargoTypesLookup and con.cargoTypesLookup.parcel then
      containerSlots = containerSlots + (con.freeCargoSlots or 0)
      containerCount = containerCount + 1
    end
  end
  maxKitsByCargo = math.floor(containerSlots / kit.slots)

  local accolades = {}
  for _, acc in ipairs(config.accolades or {}) do
    local progress = accoladeProgress(acc)
    local rewardMoney = accoladeRewardMoney(acc)
    table.insert(accolades, {
      id = acc.id,
      title = acc.title,
      description = acc.description,
      progress = progress,
      target = acc.target,
      claimed = state.stats.claimedAccolades[acc.id] == true,
      ready = progress >= acc.target and state.stats.claimedAccolades[acc.id] ~= true,
      rewardMoney = rewardMoney,
      rewardLabel = formatMoney(rewardMoney),
      reward = acc.reward
    })
  end

  return {
    phase = state.phase,
    classInfo = classInfo,
    setupBlockedReason = setupBlockedReason,
    showIntro = state.settings.skipIntro ~= true,
    classes = config.classes,
    classOrder = config.classOrder,
    repairKit = {
      slots = kit.slots,
      weightKg = kit.weightKg,
      cost = kitCost,
      freeCargoSlots = containerSlots,
      cargoContainerCount = containerCount,
      maxByCargo = maxKitsByCargo
    },
    pending = state.pending,
    lastResult = state.lastResult,
    accolades = accolades
  }
end

local function startPayload(distance)
  local pending = state.pending or {}
  return {
    visible = true,
    payload = {
      title = "Dakar Start",
      level = "Skeleton Coast",
      classLabel = pending.classLabel or "Unlimited",
      repairsLeft = pending.repairsLeft or 0,
      distanceMeters = distance or 0
    }
  }
end

local function finishPayload()
  local r = state.lastResult or {}
  return {
    visible = true,
    payload = {
      title = "Dakar Complete",
      placement = r.placement or "Finished",
      placementId = r.placementId or "top10",
      classLabel = r.classLabel or "Dakar",
      elapsedSeconds = r.elapsedSeconds or 0,
      adjustedSeconds = r.adjustedSeconds or 0,
      targetSeconds = r.targetSeconds or 0,
      repairPenaltySeconds = r.repairPenaltySeconds or 0,
      repairsUsed = r.repairsUsed or 0,
      totalDistanceKm = r.totalDistanceKm or 0,
      baseReward = r.baseReward or 0,
      bonus = r.bonus or 0,
      totalReward = r.totalReward or 0
    }
  }
end

local function emitMenu()
  getPlayerCargoContainers(function()
    guihooks.trigger("dakarData", menuPayload())
  end)
end

local function clearGroundRoute()
  if core_groundMarkers and core_groundMarkers.setPath then core_groundMarkers.setPath(nil) end
end

local function routeToStart()
  loadSites()
  local startSpot = spotsByName[config.startSpot]
  if startSpot and core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(startSpot.pos, { clearPathOnReachingTarget = true })
  end
end

function M.requestDakarMenuData()
  emitMenu()
end

function M.requestDakarPhoneData()
  emitPhone()
end

function M.closeMenu()
  log("I", "skeletonCoastDakar", "Closing Dakar menu")
  hideStartOverlay()
  hideFinishOverlay()
  if state.phase ~= "active" then hideCompassOverlay() end
  if career_career and career_career.closeAllMenus then career_career.closeAllMenus() end
  guihooks.trigger("ChangeState", { state = "play", params = {} })
end

function M.closeStartPrompt()
  startPromptOpen = false
  hideStartOverlay()
end

function M.dismissFinish()
  hideFinishOverlay()
end

function M.openMenu(tab)
  guihooks.trigger("ChangeState", { state = "dakar", params = { tab or "signup" } })
  emitMenu()
end

function M.dismissIntro(dontShowAgain)
  state.settings = state.settings or {}
  if dontShowAgain == true then
    state.settings.skipIntro = true
    saveState()
  end
  emitMenu()
end

function M.signUp(kitCount)
  loadConfig()
  loadSites()
  kitCount = math.max(0, math.floor(tonumber(kitCount) or 0))
  log("I", "skeletonCoastDakar", "Dakar sign-up requested with " .. tostring(kitCount) .. " repair kits")
  if state.phase == "active" then notify("Finish or abandon the current Dakar first.", "warning") return end

  local classInfo = detectClass()
  local invId, vehInfo, veh = currentVehicleInfo()
  if not veh or not invId then notify("You must be in your race vehicle.", "warning") emitMenu() return end
  if not classInfo then notify("Could not determine this vehicle's Dakar class.", "warning") emitMenu() return end

  getPlayerCargoContainers(function(containers)
    local neededSlots = kitCount * config.repairKit.slots
    local repairContainers, totalSlots = getRepairContainers(containers, veh:getID())
    if kitCount > 0 and totalSlots < neededSlots then
      notify("Not enough parcel cargo space for those Repair Kits.", "warning")
      emitMenu()
      return
    end
    if kitCount > 0 and (not career_modules_delivery_parcelManager or not career_modules_delivery_parcelManager.addCargo) then
      notify("Cargo manager is not available for Dakar Repair Kits.", "warning")
      emitMenu()
      return
    end

    local cost = math.floor(getVehicleValue(invId) * config.repairKit.costVehicleValueFactor * kitCount)
    if cost > 0 and not canPayMoney(cost) then
      notify("Not enough money for those Repair Kits.", "warning")
      emitMenu()
      return
    end

    local kitIds = kitCount > 0 and addRepairCargo(repairContainers, kitCount) or {}
    if kitCount > 0 and #kitIds < kitCount then
      notify("Could not load all Dakar Repair Kits.", "warning")
      emitMenu()
      return
    end
    if cost > 0 and not payMoney(cost, "Purchased Dakar Repair Kits") then
      for _, id in ipairs(kitIds) do removeRepairCargo(id) end
      notify("Not enough money for those Repair Kits.", "warning")
      emitMenu()
      return
    end
    state.phase = "signedUp"
    state.pending = {
      classId = classInfo.id,
      classLabel = classInfo.label,
      inventoryId = invId,
      vehicleId = veh:getID(),
      repairsLeft = kitCount,
      repairKitCargoIds = kitIds,
      kitCost = cost,
      signedUpAt = os.time()
    }
    state.lastResult = nil
    startPromptOpen = false
    saveState()
    routeToStart()
    notify("Dakar signed up. Drive to the starting line.", "info")
    emitStartNotification()
    if career_career and career_career.closeAllMenus then career_career.closeAllMenus() end
    guihooks.trigger("ChangeState", { state = "play", params = {} })
    emitMenu()
    emitPhone()
  end)
end

function M.startEvent()
  loadConfig()
  loadSites()
  if state.phase ~= "signedUp" or not state.pending then notify("Sign up before starting Dakar.", "warning") return end
  local classRule = config.classes[state.pending.classId] or config.classes.Unlimited
  local route = buildRoute(classRule)
  if not route then notify("Dakar route generation failed. Add more spaced checkpoints or lower spacing.", "warning") return end
  local totalDistance = routeDistance(route)
  state.phase = "active"
  state.active = {
    classId = state.pending.classId,
    classLabel = state.pending.classLabel,
    inventoryId = state.pending.inventoryId,
    vehicleId = state.pending.vehicleId,
    route = route,
    index = 1,
    elapsed = 0,
    repairsLeft = state.pending.repairsLeft or 0,
    repairKitCargoIds = deepcopy(state.pending.repairKitCargoIds or {}),
    repairPenaltySeconds = 0,
    repairsUsed = 0,
    totalDistanceMeters = totalDistance,
    targetSeconds = targetTime(totalDistance),
    startedAt = os.time()
  }
  state.pending = nil
  startPromptOpen = false
  clearGroundRoute()
  hideStartOverlay()
  saveState()
  notify("Dakar started. Navigate to the first checkpoint.", "info")
  emitCheckpointNotification()
  emitPhone()
  emitCompass()
end

local function completeEvent()
  local active = state.active
  if not active then return end
  local adjustedSeconds = active.elapsed + (active.repairPenaltySeconds or 0)
  local placement = placementFor(adjustedSeconds, active.totalDistanceMeters, active.targetSeconds)
  local distanceKm = active.totalDistanceMeters / 1000
  local rawBaseReward = math.floor((config.rewards.baseMoney or 5000) + (config.rewards.moneyPerKm or 1000) * distanceKm)
  local rawBonus = math.floor(rawBaseReward * (placement.bonusFactor or 0))
  local baseReward = scaleRewardMoney(rawBaseReward)
  local bonus = scaleRewardMoney(rawBonus)
  local total = baseReward + bonus
  addMoney(total, "Dakar finish reward")

  ensureStats()
  state.stats.totalCompletions = state.stats.totalCompletions + 1
  state.stats.classCompletions[active.classId] = (state.stats.classCompletions[active.classId] or 0) + 1
  if placement.id == "first" then state.stats.totalWins = state.stats.totalWins + 1 end
  if (active.repairsUsed or 0) == 0 then state.stats.noRepairCompletions = state.stats.noRepairCompletions + 1 end

  state.lastResult = {
    placement = placement.label,
    placementId = placement.id,
    elapsedSeconds = active.elapsed,
    adjustedSeconds = adjustedSeconds,
    targetSeconds = active.targetSeconds,
    repairPenaltySeconds = active.repairPenaltySeconds or 0,
    repairsUsed = active.repairsUsed or 0,
    totalDistanceKm = distanceKm,
    classLabel = active.classLabel,
    baseReward = baseReward,
    bonus = bonus,
    totalReward = total
  }
  state.phase = "idle"
  state.active = nil
  clearCheckpointMarker()
  hideCompassOverlay()
  saveState()
  if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
  guihooks.trigger("DakarFinishUi", finishPayload())
  emitPhone()
end

local function advanceCheckpoint()
  if not state.active then return end
  Engine.Audio.playOnce("AudioGui", "art/sound/ui_checkpoint.ogg", { volume = 2 })
  if state.active.index >= #state.active.route then
    completeEvent()
  else
    state.active.index = state.active.index + 1
    saveState()
    emitCheckpointNotification()
    emitPhone()
  end
end

function M.useRepairKit()
  local active = state.active
  if not active or (active.repairsLeft or 0) <= 0 then notify("No Dakar Repair Kits remaining.", "warning") return end
  active.repairsLeft = active.repairsLeft - 1
  active.repairsUsed = (active.repairsUsed or 0) + 1
  active.repairPenaltySeconds = (active.repairPenaltySeconds or 0) + (config.repairKit.penaltySeconds or 60)
  local cargoId = table.remove(active.repairKitCargoIds, 1)
  if cargoId then removeRepairCargo(cargoId) end

  local vehInfo = active.inventoryId and career_modules_inventory.getVehicle(active.inventoryId)
  if vehInfo and career_modules_insurance_insurance and career_modules_insurance_insurance.startRepairInstant then
    local wasSpawned = career_modules_inventory.getVehicleIdFromInventoryId and career_modules_inventory.getVehicleIdFromInventoryId(vehInfo.id)
    local repaired = pcall(function()
      career_modules_insurance_insurance.startRepairInstant(vehInfo, wasSpawned and function()
        saveState()
        emitPhone()
      end or nil, true)
    end)
    if repaired then
      if not wasSpawned then
        saveState()
        emitPhone()
      end
      return
    end
    log("W", "skeletonCoastDakar", "Dakar Repair Kit instant repair failed; falling back to beamstate restore.")
    local veh = getPlayerVehicle(0)
    if veh then veh:queueLuaCommand("beamstate.restore()") end
  else
    local veh = getPlayerVehicle(0)
    if veh then veh:queueLuaCommand("beamstate.restore()") end
  end
  saveState()
  emitPhone()
end

function M.abandonEvent()
  if state.phase ~= "active" then return end
  state.phase = "failed"
  state.lastFailure = { reason = "abandoned", time = os.time() }
  state.active = nil
  startPromptOpen = false
  clearCheckpointMarker()
  clearGroundRoute()
  hideCompassOverlay()
  saveState()
  notify("Dakar abandoned.", "warning")
  emitPhone()
end

function M.claimAccolade(id)
  loadConfig()
  ensureStats()
  if state.stats.claimedAccolades[id] then return end
  for _, acc in ipairs(config.accolades or {}) do
    if acc.id == id and accoladeProgress(acc) >= acc.target then
      local reward = acc.reward or {}
      if reward.money then addMoney(reward.money, acc.title .. " reward") end
      if reward.vehicle then
        notify(acc.title .. " vehicle reward unlocked. Placeholder config: " .. tostring(reward.vehicle.config), "info")
      end
      state.stats.claimedAccolades[id] = true
      saveState()
      emitMenu()
      return
    end
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  loadConfig()
  if levelIdentifier ~= config.levelId then return end
  loadSites()

  local function addPoi(id, spot, label, action)
    if not spot then return end
    table.insert(elements, {
      id = id,
      data = { type = "skeletonCoastDakar", action = action, id = id, name = label },
      markerInfo = {
        inspectVehicleMarker = {
          pos = spot.pos,
          radius = config.startRadiusMeters or 18,
          vehicleHeight = 4
        },
        bigmapMarker = {
          pos = spot.pos,
          icon = "poi_fasttravel_round_orange_green",
          name = label,
          description = "Skeleton Coast Dakar"
        },
        clusterType = "activity"
      },
      pos = spot.pos,
      radius = config.startRadiusMeters or 18
    })
  end

  addPoi("skeletonCoastDakarRegistration", spotsByName[config.registrationSpot], "Dakar Registration", "registration")
  if state.phase == "signedUp" then
    addPoi("skeletonCoastDakarStart", spotsByName[config.startSpot], "Dakar Start", "start")
  end
end

function M.onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData or {}) do
    if elem.type == "skeletonCoastDakar" and elem.action == "registration" then
      table.insert(activityData, {
        icon = "poi_fasttravel_round_orange_green",
        heading = "Dakar",
        preheadings = { "Skeleton Coast" },
        sorting = {
          type = elem.type,
          id = "registration"
        },
        buttonLabel = "Event Sign Up",
        buttonFun = function() M.openMenu("signup") end
      })
    elseif elem.type == "skeletonCoastDakar" and elem.action == "start" then
      table.insert(activityData, {
        icon = "poi_fasttravel_round_orange_green",
        heading = "Dakar Start",
        preheadings = { "Skeleton Coast" },
        sorting = {
          type = elem.type,
          id = "start"
        },
        buttonLabel = "Start Event",
        buttonFun = function() M.startEvent() end
      })
    end
  end
end

local function showCheckpointMarker(cp)
  if not isDakarCheckpointSpot(cp) then
    clearCheckpointMarker()
    return
  end
  if activeCheckpointMarkerId == cp.id then return end
  clearCheckpointMarker()
  local marker = createObject("TSStatic")
  if not marker then return end
  marker.shapeName = "art/shapes/race/flagMarkerOrange.dae"
  marker:setPosRot(cp.pos.x, cp.pos.y, cp.pos.z, 0, 0, 0, 0)
  marker.scale = vec3(3, 3, 3)
  local markerName = "skeletonCoastDakarCheckpointMarker"
  if scenetree.findObject(markerName) then scenetree.findObject(markerName):delete() end
  marker:registerObject(markerName)
  activeCheckpointMarker = marker
  activeCheckpointMarkerId = cp.id
end

function M.onUpdate(dtReal, dtSim)
  if state.phase == "signedUp" and state.pending then
    loadSites()
    local veh = getPlayerVehicle(0)
    local startSpot = spotsByName[config.startSpot]
    if veh and startSpot then
      local distance = (startSpot.pos - veh:getPosition()):length()
      if distance <= (config.startRadiusMeters or 18) then
        if not startPromptOpen then
          startPromptOpen = true
          notify("You are at the Dakar starting line.", "info")
          guihooks.trigger("DakarStartUi", startPayload(distance))
        end
      elseif distance > ((config.startRadiusMeters or 18) * 1.8) then
        startPromptOpen = false
        hideStartOverlay()
      end
    end

    phoneDirtyTimer = phoneDirtyTimer + (dtReal or 0)
    if phoneDirtyTimer > 0.5 then
      phoneDirtyTimer = 0
      emitPhone()
    end
    return
  end

  if state.phase ~= "active" or not state.active then return end
  state.active.elapsed = state.active.elapsed + (dtSim or 0)
  local veh = getPlayerVehicle(0)
  local cp = state.active.route[state.active.index]
  if not cp then
    hideCompassOverlay()
    return
  end
  emitCompass()
  if not veh then return end

  local distance = (cp.pos - veh:getPosition()):length()
  if distance <= (config.checkpointRevealDistanceMeters or 300) then
    showCheckpointMarker(cp)
  else
    clearCheckpointMarker()
  end
  if distance <= (config.checkpointRadiusMeters or 18) then
    clearCheckpointMarker()
    advanceCheckpoint()
  end

  phoneDirtyTimer = phoneDirtyTimer + (dtReal or 0)
  if phoneDirtyTimer > 0.5 then
    phoneDirtyTimer = 0
    emitPhone()
    emitCompass()
  end
end

function M.onCareerActivated()
  loadConfig()
  loadSites()
  loadState()
  if state.phase == "signedUp" then routeToStart() end
  if state.phase ~= "active" then hideCompassOverlay() else emitCompass() end
end

function M.onExtensionLoaded()
  loadConfig()
  loadSites()
  loadState()
  if state.phase ~= "active" then hideCompassOverlay() else emitCompass() end
end

return M
