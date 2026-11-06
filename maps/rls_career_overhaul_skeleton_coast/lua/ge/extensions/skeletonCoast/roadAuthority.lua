local M = {}

M.dependencies = {
  "career_career",
  "career_saveSystem",
  "career_modules_playerAttributes"
}

local levelId = "skeleton_coast"
local sitesPath = "/levels/skeleton_coast/roadAuthority.sites.json"
local rewardsPath = "/levels/skeleton_coast/roadAuthority.rewards.json"
local clueImageDir = "/levels/skeleton_coast/facilities/road_authority/"
local clueImageExtension = ".jpg"
local foundItemDebrisShape = "/levels/skeleton_coast/art/shapes/objects/road_authority/big_pile.DAE"
local vehicleDebrisShape = "/levels/skeleton_coast/art/shapes/objects/road_authority/s_containers_20_beamng.dae"
local saveDir = "/career/rls_skeleton_coast"
local saveFile = saveDir .. "/roadAuthority.json"
local maxActiveReports = 10
local minReportIntervalSeconds = 10 * 60
local maxReportIntervalSeconds = 30 * 60
local introDelaySeconds = 4
local rewardVehicleSellerIds = {
  "private",
  "scrappers",
  "nebenan",
  "vogelsangGroen",
  "vogelsangbayIbishu"
}

local defaultRewardConfig = {
  fallbackMoney = { min = 500, max = 1000 },
  rewards = {
    { id = "money_500", type = "money", weight = 60, money = { min = 500, max = 500 } },
    { id = "money_1000", type = "money", weight = 30, money = { min = 1000, max = 1000 } },
    { id = "money_1500", type = "money", weight = 10, money = { min = 1500, max = 1500 } }
  }
}

local sites
local rewardConfig
local normalizeRange
local loadRewards
local randomWholeRange
local valueInRange
local reportsById = {}
local reportOrder = {}
local debrisObjects = {}
local initialized = false
local introTimer = 0
local introVisible = false
local generationCheckTimer = 0
local phoneDirtyTimer = 0
local stagedReportId
local dismissedPromptReportId

local state = {
  introShown = false,
  activeReports = {},
  completedReports = {},
  debrisClearedCount = 0,
  nextReportTime = 0
}

local function isSkeletonCoastCareer()
  return getCurrentLevelIdentifier()
    and getCurrentLevelIdentifier() == levelId
    and career_career
    and career_career.isActive
    and career_career.isActive()
end

local function notify(msg, category)
  ui_message(msg, 5, category or "info", category or "info")
end

local function asVec3(value, fallback)
  if type(value) == "table" then return vec3(value[1] or 0, value[2] or 0, value[3] or 0) end
  return value or fallback or vec3()
end

local function getFirstTag(spot)
  local tags = spot.customFields and spot.customFields.tags
  if type(tags) == "table" then return tags[1] or tags[0] end
  return nil
end

local function reportRadius(scl)
  if not scl then return 12 end
  return math.max(scl:length() / 2 + 4, 12)
end

local function resolveClueImage(oldId, spotName, label)
  local fallback = clueImageDir .. spotName .. clueImageExtension
  if not FS or not FS.fileExists then return fallback end

  local candidates = {}
  if oldId then table.insert(candidates, tostring(oldId)) end
  table.insert(candidates, spotName)
  table.insert(candidates, label)
  for _, candidate in ipairs(candidates) do
    if candidate then
      local path = clueImageDir .. candidate .. clueImageExtension
      if FS:fileExists(path) then return path end
    end
  end

  return fallback
end

local function sanitizeSpot(spot)
  local id = spot.name
  local name = getFirstTag(spot) or id
  local scl = asVec3(spot.scl, vec3(2.5, 6, 3))
  return {
    id = id,
    name = name,
    pos = asVec3(spot.pos),
    rot = spot.rot or { 0, 0, 0, 1 },
    scl = scl,
    radius = reportRadius(scl),
    image = resolveClueImage(spot.oldId, id, name)
  }
end

local function loadSites()
  if sites then return end
  sites = jsonReadFile(sitesPath) or {}
  reportsById = {}
  reportOrder = {}
  for _, raw in ipairs(sites.parkingSpots or {}) do
    if raw.name then
      local report = sanitizeSpot(raw)
      reportsById[report.id] = report
      table.insert(reportOrder, report)
    end
  end
end

local function tableCount(tbl)
  local count = 0
  for _, _ in pairs(tbl or {}) do count = count + 1 end
  return count
end

local function pruneCompletedActiveReports()
  if type(state.activeReports) ~= "table" or type(state.completedReports) ~= "table" then return 0 end

  local removed = 0
  for id, _ in pairs(state.activeReports) do
    if state.completedReports[id] == true then
      state.activeReports[id] = nil
      removed = removed + 1
    end
  end
  return removed
end

local function activeReportCount()
  pruneCompletedActiveReports()
  return tableCount(state.activeReports)
end

local function ensureState()
  state = state or {}
  state.introShown = state.introShown == true
  state.activeReports = state.activeReports or {}
  state.completedReports = state.completedReports or {}
  state.debrisClearedCount = tonumber(state.debrisClearedCount) or 0
  state.nextReportTime = tonumber(state.nextReportTime) or 0
end

local function saveRootPath()
  if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then return nil end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  return currentSavePath
end

local function ensureSaveDir(currentSavePath)
  if not currentSavePath or not FS then return end
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then FS:directoryCreate(dirPath, true) end
end

local function savePath()
  local currentSavePath = saveRootPath()
  if not currentSavePath then return nil end
  ensureSaveDir(currentSavePath)
  return currentSavePath .. saveFile
end

local function encodeForSave()
  ensureState()
  return {
    introShown = state.introShown,
    activeReports = deepcopy(state.activeReports),
    completedReports = deepcopy(state.completedReports),
    debrisClearedCount = state.debrisClearedCount,
    nextReportTime = state.nextReportTime
  }
end

local function saveState()
  local path = savePath()
  if not path or not career_saveSystem or not career_saveSystem.jsonWriteFileSafe then return end
  career_saveSystem.jsonWriteFileSafe(path, encodeForSave(), true)
end

local function loadState()
  local path = savePath()
  local loaded = path and jsonReadFile(path) or nil
  if loaded then state = loaded end
  ensureState()
  if pruneCompletedActiveReports() > 0 then saveState() end
end

local function isActiveReport(id)
  return state.activeReports and state.activeReports[id] ~= nil and not (state.completedReports and state.completedReports[id] == true)
end

local function isCompletedReport(id)
  return state.completedReports and state.completedReports[id] == true
end

local function getActiveReportReward(id)
  local active = state.activeReports and state.activeReports[id]
  if type(active) == "table" then return active.reward end
  return nil
end

local function getDebrisShapeForReport(report)
  local reward = report and getActiveReportReward(report.id)
  if reward and reward.type == "vehicle" then return vehicleDebrisShape end
  return foundItemDebrisShape
end

local function ensureDebrisObject(report)
  local name = "roadAuthorityDebris_" .. report.id
  local shapeName = getDebrisShapeForReport(report)
  local existing = scenetree.findObject(name)
  if existing then
    if existing.shapeName ~= shapeName then
      existing:delete()
    else
      debrisObjects[report.id] = existing
      return existing
    end
  end

  existing = scenetree.findObject(name)
  if existing then
    debrisObjects[report.id] = existing
    return existing
  end

  local obj = createObject("TSStatic")
  if not obj then return nil end
  obj.shapeName = shapeName
  obj:setPosRot(
    report.pos.x,
    report.pos.y,
    report.pos.z,
    report.rot[1] or 0,
    report.rot[2] or 0,
    report.rot[3] or 0,
    report.rot[4] or 1
  )
  obj.scale = vec3(1, 1, 1)
  obj.useInstanceRenderData = true
  obj:registerObject(name)
  debrisObjects[report.id] = obj
  return obj
end

local function setObjectHidden(obj, hidden)
  if obj and obj.setHidden then obj:setHidden(hidden == true) end
end

local function deleteDebrisObject(report)
  if not report then return end
  local obj = debrisObjects[report.id] or scenetree.findObject("roadAuthorityDebris_" .. report.id)
  if obj and obj.delete then obj:delete() end
  debrisObjects[report.id] = nil
end

local function rebuildDebrisVisibility()
  loadSites()
  ensureState()
  for _, report in ipairs(reportOrder) do
    if isActiveReport(report.id) and not isCompletedReport(report.id) then
      setObjectHidden(ensureDebrisObject(report), false)
    else
      deleteDebrisObject(report)
    end
  end
end

local function hideClearOverlay()
  stagedReportId = nil
  if guihooks and guihooks.trigger then guihooks.trigger("RoadAuthorityClearUi", { visible = false }) end
end

local function hideIntroOverlay()
  introVisible = false
  if guihooks and guihooks.trigger then guihooks.trigger("RoadAuthorityIntroUi", { visible = false }) end
end

local function phonePayload()
  loadSites()
  local active = {}
  for _, report in ipairs(reportOrder) do
    if isActiveReport(report.id) then
      table.insert(active, {
        id = report.id,
        name = report.name,
        image = report.image,
        status = "Active"
      })
    end
  end
  return {
    activeReports = active,
    debrisClearedCount = state.debrisClearedCount or 0,
    maxActiveReports = maxActiveReports
  }
end

local function emitPhone()
  if guihooks and guihooks.trigger then guihooks.trigger("roadAuthorityPhoneData", phonePayload()) end
end

local function emitNotification(title, message, image, ttl)
  if not guihooks or not guihooks.trigger then return end
  guihooks.trigger("PhoneLockNotification", {
    title = title or "Road Authority",
    message = message or "",
    kind = "dakar",
    ttl = ttl or 8,
    source = "Road Authority",
    image = image,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }
  })
end

local function introPayload()
  return {
    visible = true,
    payload = {
      title = "SKELETON COAST",
      subtitle = "Road Authority",
      body = "Welcome to Skeleton Coast.\n\nPer our agreement, you have been granted access to Skeleton Coast.\n\nDuring your stay, you have been assigned to the Road Authority Department of the Wildlife Protection Agency. Cleanup reports will be sent to your phone. These reports identify locations where abandoned debris must be removed from protected areas.\n\nAny items recovered during these operations are yours to keep.\n\nShould your cleanup activities uncover information regarding the individual known as Uncle, remember the terms of our agreement:\n\nDo not approach him.\n\nDo not contact him.\n\nReport your findings to us immediately.\n\nYour first reports will arrive shortly.\n\n- Skeleton Coast Road Authority",
      actionLabel = "Continue"
    }
  }
end

local function clearPayload(report)
  return {
    visible = true,
    payload = {
      title = "Road Authority",
      reportId = report.id,
      reportName = report.name
    }
  }
end

local function scheduleNextReport()
  state.nextReportTime = os.time() + math.random(minReportIntervalSeconds, maxReportIntervalSeconds)
end

local function selectReward()
  local config = loadRewards()
  local rewardPool = config.rewards or defaultRewardConfig.rewards
  local totalWeight = 0
  for _, reward in ipairs(rewardPool) do totalWeight = totalWeight + (reward.weight or 0) end
  if totalWeight <= 0 then return rewardPool[1] end
  local pick = math.random() * totalWeight
  local running = 0
  for _, reward in ipairs(rewardPool) do
    running = running + (reward.weight or 0)
    if pick <= running then return reward end
  end
  return rewardPool[1]
end

local function grantMoneyReward(amount, report, fallback)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount <= 0 or not career_modules_playerAttributes then return false end
  career_modules_playerAttributes.addAttributes(
    { money = amount },
    { label = (report and report.name or "Road Authority") .. " cleanup reward", tags = { "gameplay", "roadAuthority" } }
  )
  notify("You found $" .. tostring(amount) .. " in the debris.", "info")
  return true
end

local function grantFallbackMoney(report)
  local config = loadRewards()
  return grantMoneyReward(randomWholeRange(config.fallbackMoney), report, true)
end

local function grantConfiguredMoneyReward(reward, report)
  local amount = reward.amount or randomWholeRange(reward.money)
  return grantMoneyReward(amount, report, false)
end

local function getOwnedPartRewardCandidates(range)
  local candidates = {}
  if not career_modules_partInventory or not career_modules_partInventory.getInventory then return candidates end
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return candidates end

  local inventory = career_modules_partInventory.getInventory() or {}
  local vehicles = career_modules_inventory.getVehicles() or {}
  for _, part in pairs(inventory) do
    local vehicle = part and part.location and vehicles[part.location]
    if vehicle and vehicle.owned and part.location > 0 and valueInRange(part.value, range) then
      table.insert(candidates, part)
    end
  end
  return candidates
end

local function getPartVehicleLabel(part)
  local modelKey = part and part.vehicleModel
  if modelKey and core_vehicles and core_vehicles.getModel then
    local modelData = core_vehicles.getModel(modelKey)
    local modelInfo = modelData and modelData.model
    if type(modelInfo) == "table" then
      local brand = modelInfo.Brand or modelInfo.brand
      local name = modelInfo.Name or modelInfo.name
      if brand and name then return tostring(brand) .. " " .. tostring(name) end
      if name then return tostring(name) end
    end
  end

  if career_modules_inventory and career_modules_inventory.getVehicles and part and part.location then
    local vehicle = (career_modules_inventory.getVehicles() or {})[part.location]
    if vehicle and vehicle.niceName then return tostring(vehicle.niceName) end
    if vehicle and vehicle.model then return tostring(vehicle.model) end
  end

  return tostring(modelKey or "vehicle")
end

local function grantOwnedVehiclePartReward(reward, report)
  if not career_modules_partInventory or not career_modules_partInventory.addPartToInventory then return false end
  local candidates = getOwnedPartRewardCandidates(reward.value)
  if #candidates <= 0 then return false end

  local sourcePart = candidates[math.random(1, #candidates)]
  local vehicleLabel = getPartVehicleLabel(sourcePart)
  local part = deepcopy(sourcePart)
  part.location = 0
  part.partId = nil
  part.partShopId = nil
  part.finalValue = nil
  part.sourcePart = nil
  part.rewardSource = "roadAuthority"
  career_modules_partInventory.addPartToInventory(part)
  local partLabel = type(part.description) == "table" and part.description.description or part.name or "part"
  notify("You found a " .. tostring(partLabel) .. " for a " .. tostring(vehicleLabel) .. ".", "info")
  return true
end

local function getVehicleRewardCandidates(range)
  local candidates = {}
  if not career_modules_vehicleShopping then return candidates end

  if career_modules_vehicleShopping.getVehiclesInShop then
    for _, vehicleInfo in ipairs(career_modules_vehicleShopping.getVehiclesInShop() or {}) do
      if vehicleInfo and valueInRange(vehicleInfo.Value or vehicleInfo.value or vehicleInfo.marketValue, range) then
        table.insert(candidates, vehicleInfo)
      end
    end
  end

  if #candidates > 0 or not career_modules_vehicleShopping.getRandomVehicleFromCache then return candidates end

  for _, sellerId in ipairs(rewardVehicleSellerIds) do
    for _, vehicleInfo in ipairs(career_modules_vehicleShopping.getRandomVehicleFromCache(sellerId, 30) or {}) do
      if vehicleInfo and valueInRange(vehicleInfo.Value or vehicleInfo.value or vehicleInfo.marketValue, range) then
        vehicleInfo = deepcopy(vehicleInfo)
        vehicleInfo.sellerId = vehicleInfo.sellerId or sellerId
        vehicleInfo.sellerName = vehicleInfo.sellerName or "Road Authority Recovery"
        vehicleInfo.Mileage = tonumber(vehicleInfo.Mileage) or 0
        vehicleInfo.year = tonumber(vehicleInfo.year) or 1985
        table.insert(candidates, vehicleInfo)
        if #candidates >= 25 then return candidates end
      end
    end
  end
  return candidates
end

local function grantVehicleReward(reward, report)
  if not career_modules_vehicleShopping or not career_modules_vehicleShopping.grantRewardVehicle then return false end
  local candidates = getVehicleRewardCandidates(reward.value)
  if #candidates <= 0 and reward.value and (tonumber(reward.value.max) or 0) < 10000 then
    candidates = getVehicleRewardCandidates({ min = tonumber(reward.value.min) or 0, max = 10000 })
  end
  if #candidates <= 0 then
    notify("Road Authority could not find a matching recovery vehicle, paying fallback cash.", "warning")
    return false
  end

  local vehicleInfo = candidates[math.random(1, #candidates)]
  local spawnTransform = report and {
    pos = { report.pos.x, report.pos.y, report.pos.z },
    rot = report.rot
  } or nil
  if career_modules_vehicleShopping.grantRewardVehicle(vehicleInfo, "Road Authority cleanup reward", {
    ignoreGarageLimit = true,
    randomPaint = true,
    spawnTransform = spawnTransform
  }) then
    notify("Road Authority recovered a vehicle: " .. tostring(vehicleInfo.niceName or vehicleInfo.Name or vehicleInfo.key or "vehicle") .. ".", "info")
    return true
  end
  notify("Road Authority vehicle recovery failed, paying fallback cash.", "warning")
  return false
end

local function grantReward(reward, report)
  if not reward then return grantFallbackMoney(report) end
  local granted = false
  if reward.type == "money" then
    granted = grantConfiguredMoneyReward(reward, report)
  elseif reward.type == "ownedVehiclePart" then
    granted = grantOwnedVehiclePartReward(reward, report)
  elseif reward.type == "vehicle" then
    granted = grantVehicleReward(reward, report)
  end

  if not granted then
    return grantFallbackMoney(report)
  end
  return true
end

local function ungeneratedReports()
  loadSites()
  local candidates = {}
  for _, report in ipairs(reportOrder) do
    if not isActiveReport(report.id) and not isCompletedReport(report.id) then table.insert(candidates, report) end
  end
  return candidates
end

local function findReportByDebugKey(key)
  if not key then return nil end
  loadSites()
  key = string.lower(tostring(key))
  for _, report in ipairs(reportOrder) do
    if string.lower(tostring(report.id)) == key or string.lower(tostring(report.name)) == key then
      return report
    end
  end
  return nil
end

local function generateReport(force, requestedReport)
  ensureState()
  pruneCompletedActiveReports()
  local report
  local candidates

  if requestedReport then
    if isActiveReport(requestedReport.id) or isCompletedReport(requestedReport.id) then return false end
    report = requestedReport
  else
    if activeReportCount() >= maxActiveReports then return false end
    candidates = ungeneratedReports()
    if #candidates <= 0 then
      state.nextReportTime = 0
      saveState()
      return false
    end
    report = candidates[math.random(1, #candidates)]
  end

  local reward = selectReward()
  state.activeReports[report.id] = {
    id = report.id,
    generatedAt = os.time(),
    reward = deepcopy(reward)
  }
  local remainingCandidates = candidates and #candidates - 1 or #ungeneratedReports()
  if remainingCandidates > 0 and activeReportCount() < maxActiveReports then
    scheduleNextReport()
  else
    state.nextReportTime = 0
  end
  saveState()
  rebuildDebrisVisibility()
  emitPhone()
  if not force then emitNotification("New Cleanup Report", report.name, report.image, 9) end
  return true, report
end

local function ensureIntroAndFirstReport(dtReal)
  if state.introShown then return end
  introTimer = introTimer + (dtReal or 0)
  if introTimer < introDelaySeconds then return end

  introVisible = true
  if guihooks and guihooks.trigger then guihooks.trigger("RoadAuthorityIntroUi", introPayload()) end
end

function M.dismissIntro()
  state.introShown = true
  introVisible = false
  hideIntroOverlay()
  emitNotification(
    "Road Authority",
    "Cleanup reports are now available.",
    "/levels/skeleton_coast/facilities/road_authority/castleHill.jpg",
    9
  )
  notify("Road Authority cleanup reports are now available.", "info")
  generateReport(true)
  saveState()
  emitPhone()
end

local function checkTimedGeneration()
  ensureState()
  if not state.introShown then return end
  if activeReportCount() >= maxActiveReports then return end
  if #ungeneratedReports() <= 0 then
    state.nextReportTime = 0
    saveState()
    return
  end
  if (state.nextReportTime or 0) <= 0 then
    scheduleNextReport()
    saveState()
    return
  end
  if os.time() >= state.nextReportTime then generateReport(false) end
end

function M.requestRoadAuthorityPhoneData()
  emitPhone()
end

function M.getRoadAuthorityReportsForUi()
  return phonePayload()
end

function M.debugGenerateRoadAuthorityTask(reportKey, resetCompleted)
  if not isSkeletonCoastCareer() then
    notify("Road Authority debug task requires Skeleton Coast career.", "warning")
    return false
  end

  loadSites()
  loadState()

  local report = findReportByDebugKey(reportKey)
  if reportKey and not report then
    local reason = "Road Authority report not found: " .. tostring(reportKey)
    notify(reason, "warning")
    return false, reason
  end

  if report and resetCompleted == true then
    state.completedReports[report.id] = nil
  end

  local generated, generatedReport = generateReport(true, report)
  if not generated then
    local reason = "No available Road Authority cleanup reports."
    if report and isActiveReport(report.id) then
      reason = "Road Authority report already active: " .. tostring(report.name)
    elseif report and isCompletedReport(report.id) then
      reason = "Road Authority report already completed: " .. tostring(report.name) .. ". Pass true as the second argument to reset it."
    end
    notify(reason, "warning")
    return false, reason
  end

  state.introShown = true
  saveState()
  notify("Debug Road Authority task generated: " .. tostring(generatedReport.name), "info")
  return true, {
    id = generatedReport.id,
    name = generatedReport.name,
    image = generatedReport.image,
    activeReports = activeReportCount()
  }
end

function M.clearReport(id)
  loadSites()
  ensureState()
  local report = reportsById[id]
  if not report or not isActiveReport(id) then return end

  local reward = getActiveReportReward(id) or selectReward()
  state.activeReports[id] = nil
  state.completedReports[id] = true
  state.debrisClearedCount = (state.debrisClearedCount or 0) + 1
  saveState()
  if stagedReportId == id then hideClearOverlay() end
  rebuildDebrisVisibility()
  emitPhone()
  grantReward(reward, report)
  if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
end

function M.closeClearPrompt()
  dismissedPromptReportId = stagedReportId
  hideClearOverlay()
end

local function updateClearOverlay()
  if not isSkeletonCoastCareer() then
    hideClearOverlay()
    return
  end

  local veh = getPlayerVehicle(0)
  if not veh then
    hideClearOverlay()
    return
  end

  loadSites()
  ensureState()
  local playerPos = veh:getPosition()
  local nearest
  local nearestDistance
  for _, report in ipairs(reportOrder) do
    if isActiveReport(report.id) then
      local distance = (report.pos - playerPos):length()
      if distance <= report.radius and (not nearestDistance or distance < nearestDistance) then
        nearest = report
        nearestDistance = distance
      end
    end
  end

  if nearest then
    if dismissedPromptReportId == nearest.id then return end
    stagedReportId = nearest.id
    if guihooks and guihooks.trigger then guihooks.trigger("RoadAuthorityClearUi", clearPayload(nearest)) end
  else
    dismissedPromptReportId = nil
    if stagedReportId then hideClearOverlay() end
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  -- Road Authority uses its own lightweight overlay near active debris.
  -- Do not register parking/inspect POIs here; those create the orange P marker
  -- and the standard activity prompt that duplicates the custom cleanup UI.
end

normalizeRange = function(range, fallbackMin, fallbackMax)
  if type(range) ~= "table" then return { min = fallbackMin, max = fallbackMax } end
  local minValue = tonumber(range.min) or fallbackMin
  local maxValue = tonumber(range.max) or fallbackMax or minValue
  if maxValue < minValue then minValue, maxValue = maxValue, minValue end
  return { min = minValue, max = maxValue }
end

loadRewards = function()
  if rewardConfig then return rewardConfig end

  local loaded = jsonReadFile(rewardsPath)
  if type(loaded) ~= "table" or type(loaded.rewards) ~= "table" or #loaded.rewards == 0 then
    rewardConfig = deepcopy(defaultRewardConfig)
    return rewardConfig
  end

  local rewards = {}
  for _, raw in ipairs(loaded.rewards) do
    if type(raw) == "table" and raw.type and (tonumber(raw.weight) or 0) > 0 then
      local reward = deepcopy(raw)
      reward.weight = tonumber(raw.weight) or 0
      if reward.type == "money" then
        reward.money = normalizeRange(reward.money, tonumber(raw.amount) or 500, tonumber(raw.amount) or 500)
      elseif reward.type == "ownedVehiclePart" or reward.type == "vehicle" then
        reward.value = normalizeRange(reward.value, 0, math.huge)
      end
      table.insert(rewards, reward)
    end
  end

  if #rewards == 0 then
    rewardConfig = deepcopy(defaultRewardConfig)
  else
    rewardConfig = {
      fallbackMoney = normalizeRange(loaded.fallbackMoney, 500, 1000),
      rewards = rewards
    }
  end
  return rewardConfig
end

randomWholeRange = function(range)
  range = normalizeRange(range, 0, 0)
  local minValue = math.floor(range.min or 0)
  local maxValue = math.floor(range.max or minValue)
  if maxValue <= minValue then return minValue end
  return math.random(minValue, maxValue)
end

valueInRange = function(value, range)
  value = tonumber(value)
  if not value or type(range) ~= "table" then return false end
  return value >= (tonumber(range.min) or 0) and value <= (tonumber(range.max) or math.huge)
end

function M.onActivityAcceptGatherData(elemData, activityData)
  -- See onGetRawPoiListForLevel: cleanup is handled by RoadAuthorityClearUi.
end

function M.onUpdate(dtReal)
  if not initialized or not isSkeletonCoastCareer() then return end
  ensureIntroAndFirstReport(dtReal)

  generationCheckTimer = generationCheckTimer + (dtReal or 0)
  if generationCheckTimer >= 10 then
    generationCheckTimer = 0
    checkTimedGeneration()
  end

  phoneDirtyTimer = phoneDirtyTimer + (dtReal or 0)
  if phoneDirtyTimer >= 2 then
    phoneDirtyTimer = 0
    emitPhone()
  end

  updateClearOverlay()
end

function M.onCareerActivated()
  loadSites()
  loadState()
  rebuildDebrisVisibility()
  initialized = true
end

function M.onClientStartMission()
  if not isSkeletonCoastCareer() then return end
  loadSites()
  loadState()
  rebuildDebrisVisibility()
  initialized = true
end

function M.onExtensionLoaded()
  loadSites()
  loadState()
  rebuildDebrisVisibility()
  initialized = true
end

function M.onSaveCurrentSaveSlot()
  saveState()
end

function M.onExtensionUnloaded()
  hideIntroOverlay()
  hideClearOverlay()
  for _, obj in pairs(debrisObjects) do
    if obj and obj.delete then obj:delete() end
  end
  debrisObjects = {}
end

return M
