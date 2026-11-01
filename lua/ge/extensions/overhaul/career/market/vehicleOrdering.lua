-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Factory vehicle ordering from the garage computer.
-- Read catalog discovery, shipping quotes, order placement, then delivery ticks, persistence and hooks.
--
-- The catalog is the game's own vehicle list (core_vehicles.getConfigList), so any vehicle the
-- installation can load can be ordered. Orders are paid up front and delivered to the ordering
-- garage after the shipping delay. Standard shipping is slower; expedited is faster.
local M = {}

M.dependencies = {"overhaul_career_career"}

local modIdentity = require("overhaul/lib/platform/modIdentity")

local TAG = "overhaul.vehicleOrdering"
local SAVE_SUBDIR = "/career/rls_career"
local SAVE_FILE = "vehicleOrders.json"
local MAX_PENDING_ORDERS = 5

-- Shipping options ---------------------------------------------------------------------------------

local SHIPPING = {
  standard = {
    id = "standard",
    label = "Standard Shipping",
    description = "Slower, cheaper transport. The vehicle arrives at your garage after a delay.",
    cost = 50,
    durationSeconds = 300,
    accessDelaySeconds = 0,
  },
  expedited = {
    id = "expedited",
    label = "Expedited Shipping",
    description = "Priority transport. The vehicle arrives at your garage much sooner.",
    cost = 250,
    durationSeconds = 30,
    accessDelaySeconds = 0,
  },
}

-- Order state --------------------------------------------------------------------------------------

local orders = {} -- orderId -> order record
local orderSequence = 0
local catalogCache
local catalogIndex

local function now()
  return os.time()
end

local function careerActive()
  return overhaul_career_career and overhaul_career_career.isActive()
end

local function garageIdForComputer(computerId)
  if not computerId then return nil end
  local facility = overhaul_world_facilities.getFacilityIfExists("computer", computerId)
  if not facility and type(computerId) == "string" then
    facility = overhaul_world_facilities.getFacilityIfExists("computer", tonumber(computerId))
  end
  local garageId = facility and facility.garageId
  return garageId and tostring(garageId) or nil
end

local function garageIsOrderable(garageId)
  if not garageId then return false end
  garageId = tostring(garageId)
  if not overhaul_career_garage_garageManager.isPurchasedGarage(garageId) then return false end
  if overhaul_career_garage_garageManager.isGarageForSale(garageId) then return false end
  return true
end

-- Catalog ------------------------------------------------------------------------------------------

local function translate(value)
  if type(value) ~= "string" or value == "" then return value end
  return core_locales.translateWithOrWithoutContext(value)
end

local function configTypeOf(cfg)
  local configType = cfg.aggregates and cfg.aggregates["Config Type"]
  if type(configType) == "table" then
    for key in pairs(configType) do return key end
  end
  return configType
end

local function priceOf(cfg)
  local value = tonumber(cfg.Value)
  if value and value > 0 then return math.floor(value + 0.5) end
  local aggregate = cfg.aggregates and cfg.aggregates.Value
  local aggregateValue = tonumber(aggregate)
  if not aggregateValue and type(aggregate) == "table" then
    aggregateValue = tonumber(aggregate.max) or tonumber(aggregate.min)
  end
  if aggregateValue and aggregateValue > 0 then return math.floor(aggregateValue + 0.5) end
  return nil
end

-- Mirrors the value calculator's readers: a direct scalar first, then the aggregate range/flag form.
local function numberField(cfg, key)
  local value = tonumber(cfg[key])
  if value then return value end
  local aggregate = cfg.aggregates and cfg.aggregates[key]
  if type(aggregate) == "table" then
    return tonumber(aggregate.max) or tonumber(aggregate.min)
  end
  return tonumber(aggregate)
end

local function stringField(cfg, key)
  local direct = cfg[key]
  if type(direct) == "string" and direct ~= "" then return direct end
  local aggregate = cfg.aggregates and cfg.aggregates[key]
  if type(aggregate) == "string" and aggregate ~= "" then return aggregate end
  if type(aggregate) == "table" then
    for value, enabled in pairs(aggregate) do
      if enabled == true then return tostring(value) end
    end
  end
  return nil
end

-- Match the free-mode vehicle selector: every configuration the game can spawn, hiding only
-- auxiliary content and scenery props. Prices are the config's own catalog Value (the game's
-- number); a configuration without one can be browsed but not ordered.
local function isCatalogConfig(cfg)
  if type(cfg) ~= "table" or not cfg.model_key or not cfg.key then return false end
  if cfg.isAuxiliary then return false end
  local types = cfg.aggregates and cfg.aggregates.Type
  if type(types) == "table" and (types.Prop or types.PropParked or types.PropTraffic) then
    return false
  end
  return true
end

-- Own-mod configs are the .pc files shipped under the career mod's vehicles/ folder (junk cars,
-- "used and abused" variants, extra police trims). They are career flavour, not the game's catalog.
local ownModInfo
local function getOwnModInfo()
  if ownModInfo ~= nil then return ownModInfo end
  ownModInfo = false
  local ok, mod = pcall(modIdentity.identifyOwnMod)
  if ok and type(mod) == "table" then
    local root = type(mod.unpackedPath) == "string"
      and mod.unpackedPath:gsub("\\", "/"):gsub("/+$", ""):lower() or nil
    ownModInfo = {
      id = mod.modID,
      name = mod.modname,
      title = mod.modData and mod.modData.title or nil,
      root = root,
    }
  end
  return ownModInfo
end

-- Source/modID are not always filled for unpacked mods; the file behind the .pc path is definitive.
local function isOwnModConfigByPath(cfg)
  local info = getOwnModInfo()
  if not info or not info.root or type(cfg.pcFilename) ~= "string" then return false end
  -- Base content is never ours; only mod-provided files need the (slower) origin lookup.
  if cfg.Source == "BeamNG - Official" then return false end
  local ok, real = pcall(function() return FS:getFileRealPath(cfg.pcFilename) end)
  if not ok or type(real) ~= "string" or real == "" then return false end
  real = real:gsub("\\", "/"):lower()
  return real:sub(1, #info.root + 1) == info.root .. "/"
end

local function isOwnModConfig(cfg)
  local info = getOwnModInfo()
  if info then
    if info.id and cfg.modID and cfg.modID == info.id then return true end
    if info.name and cfg.Source == info.name then return true end
    if info.title and cfg.Source == info.title then return true end
  end
  return isOwnModConfigByPath(cfg)
end

-- Match the free-mode vehicle selector: every configuration the game can spawn, hiding only
-- auxiliary content and scenery props. The career mod's own added configurations stay out.
local function isCatalogConfig(cfg)
  if type(cfg) ~= "table" or not cfg.model_key or not cfg.key then return false end
  if cfg.isAuxiliary then return false end
  local ownMod = isOwnModConfig(cfg)
  if ownMod then return false, true end
  local types = cfg.aggregates and cfg.aggregates.Type
  if type(types) == "table" and (types.Prop or types.PropParked or types.PropTraffic) then
    return false
  end
  return true
end

local modelInfoCache = {}
local function modelInfoFor(model)
  local cached = modelInfoCache[model]
  if cached then return cached end
  local data = core_vehicles.getModel(model)
  local info = (data and data.model) or {}
  cached = {
    name = translate(info.Name or model),
    brand = translate(info.Brand),
    preview = info.preview,
    missing = info.missingJbeamFiles and true or false,
  }
  modelInfoCache[model] = cached
  return cached
end

-- RLS valuation: the same catalog profile the market uses (parts-derived value, with the config's
-- authored Value as that calculator's own fallback). A config it cannot value keeps cfg.Value.
local function catalogPriceOf(cfg)
  local calculator = overhaul_career_market_valueCalculator
  if calculator and calculator.getVehicleCatalogProfile then
    local ok, profile = pcall(calculator.getVehicleCatalogProfile, cfg.model_key, cfg.key, cfg)
    if ok and type(profile) == "table" then
      local value = tonumber(profile.catalogValue)
      if value and value > 0 then return math.floor(value + 0.5) end
    end
  end
  return priceOf(cfg)
end

local function buildCatalog()
  local startedAt = os.clock()
  local list = core_vehicles.getConfigList(true) or {}
  local configs = list.configs or list
  local catalog, index = {}, {}
  local models, hiddenOwn = {}, 0
  if not getOwnModInfo() then
    log("W", TAG, "own mod identity unavailable; the career mod's added configurations may appear")
  end
  for _, cfg in pairs(configs) do
    local eligible, ownMod = isCatalogConfig(cfg)
    if eligible then
      local modelInfo = modelInfoFor(cfg.model_key)
      if not modelInfo.missing then
        local price = catalogPriceOf(cfg)
        local brand = cfg.Brand or modelInfo.brand
        local configLabel = translate(cfg.Configuration or cfg.key)
        local label = cfg.Name or cfg.Configuration or cfg.key
        if type(brand) == "string" and brand ~= "" and type(label) == "string" then
          label = brand .. " " .. label
        end
        local years = cfg.Years
        local year = type(years) == "table" and tonumber(years.max) or nil
        local key = cfg.model_key .. "|" .. cfg.key
        local entry = {
          model = cfg.model_key,
          config = cfg.key,
          label = translate(label),
          brand = brand,
          modelName = modelInfo.name,
          modelPreview = modelInfo.preview,
          configLabel = configLabel,
          name = translate(cfg.Name or cfg.Configuration or cfg.key),
          price = price,
          isDefault = cfg.is_default_config == true,
          configType = configTypeOf(cfg),
          preview = cfg.preview,
          power = numberField(cfg, "Power"),
          drivetrain = translate(stringField(cfg, "Drivetrain")),
          transmission = translate(stringField(cfg, "Transmission")),
          weight = numberField(cfg, "Weight"),
          year = year,
        }
        catalog[#catalog + 1] = entry
        index[key] = {model = entry.model, config = entry.config, label = entry.label, price = price,
          pcFilename = cfg.pcFilename, year = year}
        models[cfg.model_key] = true
      end
    elseif ownMod then
      hiddenOwn = hiddenOwn + 1
    end
  end
  table.sort(catalog, function(a, b) return a.label < b.label end)
  local modelCount = 0
  for _ in pairs(models) do modelCount = modelCount + 1 end
  log("I", TAG, string.format(
    "vehicle catalog: %d configurations across %d vehicles (%d own-mod configs hidden) in %.0f ms",
    #catalog, modelCount, hiddenOwn, (os.clock() - startedAt) * 1000))
  return catalog, index
end

function M.getCatalog()
  if not catalogCache or #catalogCache == 0 then
    catalogCache, catalogIndex = buildCatalog()
    if #catalogCache == 0 then
      log("W", TAG, "vehicle catalog is empty (vehicle data not loaded yet)")
    end
  end
  return catalogCache
end

local function findCatalogEntry(model, config)
  if not model or not config then return nil end
  if not catalogIndex then M.getCatalog() end
  return catalogIndex and catalogIndex[tostring(model) .. "|" .. tostring(config)] or nil
end

function M.getShippingOptions()
  return {
    standard = {id = "standard", label = SHIPPING.standard.label, description = SHIPPING.standard.description,
      cost = SHIPPING.standard.cost, durationSeconds = SHIPPING.standard.durationSeconds},
    expedited = {id = "expedited", label = SHIPPING.expedited.label, description = SHIPPING.expedited.description,
      cost = SHIPPING.expedited.cost, durationSeconds = SHIPPING.expedited.durationSeconds},
  }
end

-- Order projection ---------------------------------------------------------------------------------

local function publicOrder(order)
  return {
    id = order.id,
    model = order.model,
    config = order.config,
    label = order.label,
    vehiclePrice = order.vehiclePrice,
    shippingMethod = order.shippingMethod,
    shippingLabel = SHIPPING[order.shippingMethod] and SHIPPING[order.shippingMethod].label or order.shippingMethod,
    shippingCost = order.shippingCost,
    total = order.total,
    status = order.status,
    remaining = order.status == "pending" and math.max(0, math.ceil(order.remaining or 0)) or nil,
    garageId = order.garageId,
    inventoryId = order.inventoryId,
    error = order.error,
  }
end

local function pendingOrderCount()
  local count = 0
  for _, order in pairs(orders) do
    if order.status == "pending" then count = count + 1 end
  end
  return count
end

function M.getOrders(garageId)
  local list = {}
  garageId = garageId and tostring(garageId) or nil
  for _, order in pairs(orders) do
    if not garageId or order.garageId == garageId then
      list[#list + 1] = publicOrder(order)
    end
  end
  table.sort(list, function(a, b)
    local left = tonumber((a.id:gsub("%D", ""))) or 0
    local right = tonumber((b.id:gsub("%D", ""))) or 0
    return left > right
  end)
  return list
end

function M.getUiData(computerId)
  local garageId = garageIdForComputer(computerId)
  local attributes = overhaul_career_economy_playerAttributes
  local money = (attributes and attributes.getAttributeValue("money")) or 0
  return {
    catalog = M.getCatalog(),
    shipping = M.getShippingOptions(),
    orders = M.getOrders(garageId),
    money = math.floor(money),
    maxPendingOrders = MAX_PENDING_ORDERS,
    garageId = garageId,
    garageName = garageId and (overhaul_world_facilities.getFacilityIfExists("garage", garageId) or {}).name or nil,
    canOrder = garageIsOrderable(garageId),
  }
end

-- Persistence --------------------------------------------------------------------------------------

local function saveOrders(currentSavePath)
  if not careerActive() then return end
  local saveSystem = overhaul_career_saveSystem
  if not saveSystem then return end
  if not currentSavePath then
    local _, path = saveSystem.getCurrentProfile()
    currentSavePath = path
  end
  if not currentSavePath then return end
  -- jsonWriteFileSafe renames over an existing file, so the directory has to exist first.
  local dirPath = currentSavePath .. SAVE_SUBDIR
  local writer = saveSystem.getSaveWriter and saveSystem.getSaveWriter()
  if writer then
    if not writer.exists(dirPath) then writer.mkdir(dirPath) end
  elseif not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  local ok, err = pcall(saveSystem.jsonWriteFileSafe, dirPath .. "/" .. SAVE_FILE, {
    orders = orders,
    orderSequence = orderSequence,
  }, true)
  if not ok then log("E", TAG, "failed to save orders: " .. tostring(err)) end
end

local function loadOrders()
  orders = {}
  orderSequence = 0
  if not careerActive() then return end
  local saveSystem = overhaul_career_saveSystem
  if not saveSystem then return end
  local _, currentSavePath = saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  local data = jsonReadFile(currentSavePath .. SAVE_SUBDIR .. "/" .. SAVE_FILE) or {}
  if type(data.orders) == "table" then
    for key, order in pairs(data.orders) do
      if type(order) == "table" and order.id then orders[key] = order end
    end
  end
  orderSequence = tonumber(data.orderSequence) or 0
end

function M.onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  saveOrders(currentSavePath)
end

function M.onOverhaulModulesActivated()
  catalogCache = nil
  catalogIndex = nil
  modelInfoCache = {}
  ownModInfo = nil
  loadOrders()
end

function M.onExtensionLoaded()
  catalogCache = nil
  catalogIndex = nil
  modelInfoCache = {}
  ownModInfo = nil
  loadOrders()
end

-- Payment ------------------------------------------------------------------------------------------

local function charge(amount, label, vehicleName)
  local price = {money = {amount = amount, canBeNegative = false}}
  if not overhaul_career_economy_payment.canPay(price) then
    return false, "You cannot afford this order"
  end
  local paid = overhaul_career_economy_payment.pay(price, {
    category = "purchase",
    label = label,
    finance = {vehicleName = vehicleName},
    tags = {"vehicleOrdered"},
  })
  if not paid then return false, "Payment failed" end
  return true
end

local function refund(amount, label)
  local ok, err = pcall(overhaul_career_economy_payment.reward,
    {money = {amount = amount, canBeNegative = false}},
    {category = "purchase", label = label, tags = {"vehicleOrderRefund"}})
  if not ok then log("E", TAG, "refund failed: " .. tostring(err)) end
end

-- Delivery -----------------------------------------------------------------------------------------

local function deliveryPosition(garage)
  for _, spot in ipairs(overhaul_world_facilities.getParkingSpotsForFacility(garage) or {}) do
    if spot.pos and spot.rot and not spot:hasAnyVehicles() then return spot.pos, spot.rot end
  end
  local doorPos = overhaul_world_facilities.getAverageDoorPositionForFacility(garage)
  if doorPos then return doorPos, quat() end
  return nil
end

local function deliverOrder(order)
  -- The garage only exists in facility data for its own level; deliver once the player is back there.
  local garage = overhaul_world_facilities.getFacilityIfExists("garage", order.garageId)
  if not garage then return false, "Your garage is on another map", true end

  local pos, rot = deliveryPosition(garage)
  if not pos then return false, "No place to deliver the vehicle" end

  local entry = findCatalogEntry(order.model, order.config)
  local configPath = entry and entry.pcFilename
  if not configPath then
    configPath = "/vehicles/" .. tostring(order.model) .. "/" .. tostring(order.config) .. ".pc"
  end

  local vehicle = core_vehicles.spawnNewVehicle(order.model, {
    config = configPath,
    pos = pos,
    rot = rot or quat(),
    autoEnterVehicle = false,
  })
  if not vehicle then return false, "Vehicle could not be spawned" end
  core_vehicleBridge.executeAction(vehicle, "setIgnitionLevel", 0)

  local inventoryId = overhaul_career_garage_inventory.addVehicle(vehicle:getID(), nil, {
    owned = true,
    finalPrice = order.vehiclePrice,
    year = entry and entry.year or nil,
  })
  if not inventoryId then
    -- Nothing was recorded, so remove the world vehicle instead of leaving a free car behind.
    pcall(function() vehicle:delete() end)
    return false, "Vehicle could not be stored"
  end

  overhaul_career_garage_inventory.moveVehicleToGarage(inventoryId, order.garageId)
  if (order.accessDelay or 0) > 0 then
    pcall(overhaul_career_garage_inventory.delayVehicleAccess, inventoryId, order.accessDelay, "bought")
  end

  order.inventoryId = inventoryId
  order.status = "delivered"
  order.deliveredAt = now()
  return true
end

local function failOrder(order, reason)
  order.status = "failed"
  order.error = reason
  refund(order.total, "Vehicle order refund: " .. tostring(order.label or order.model))
end

-- Public order actions -----------------------------------------------------------------------------

function M.placeOrder(model, config, shippingMethod, computerId)
  if not careerActive() then return false, "Career is not active" end
  local garageId = garageIdForComputer(computerId)
  if not garageId then return false, "This computer is not attached to a garage" end
  if not garageIsOrderable(garageId) then return false, "You can only order vehicles at a garage you own" end

  local option = SHIPPING[shippingMethod] or SHIPPING.standard
  local entry = findCatalogEntry(model, config)
  if not entry then return false, "That vehicle is not in the catalog" end
  if not entry.price then return false, "This configuration has no catalog price" end

  local space = overhaul_career_garage_garageManager.isGarageSpace(garageId)
  if not (space and space[1]) then return false, "That garage has no free space" end
  if pendingOrderCount() >= MAX_PENDING_ORDERS then return false, "You already have too many pending orders" end

  local total = entry.price + option.cost
  local paid, payError = charge(total, "Vehicle order: " .. entry.label, entry.label)
  if not paid then return false, payError end

  orderSequence = orderSequence + 1
  local order = {
    id = string.format("order_%d_%d", now(), orderSequence),
    model = entry.model,
    config = entry.config,
    label = entry.label,
    vehiclePrice = entry.price,
    shippingMethod = option.id,
    shippingCost = option.cost,
    total = total,
    garageId = garageId,
    status = "pending",
    remaining = option.durationSeconds,
    accessDelay = option.accessDelaySeconds,
    placedAt = now(),
  }
  orders[order.id] = order
  saveOrders()
  return true, nil, order.id
end

function M.cancelOrder(orderId)
  local order = orderId and orders[orderId]
  if not order then return false, "Order not found" end
  if order.status ~= "pending" then return false, "Only pending orders can be cancelled" end
  order.status = "cancelled"
  order.cancelledAt = now()
  refund(order.total, "Vehicle order refund: " .. tostring(order.label or order.model))
  saveOrders()
  return true
end

-- Bridge-friendly wrappers: the UI reads one table instead of a multiple-return tuple.
function M.requestOrder(model, config, shippingMethod, computerId)
  local ok, err, orderId = M.placeOrder(model, config, shippingMethod, computerId)
  return {ok = ok == true, error = err, orderId = orderId}
end

function M.requestCancelOrder(orderId)
  local ok, err = M.cancelOrder(orderId)
  return {ok = ok == true, error = err}
end

-- Update tick --------------------------------------------------------------------------------------

function M.onUpdate(dtReal)
  if not careerActive() then return end
  local changed = false
  local dt = tonumber(dtReal) or 0
  for _, order in pairs(orders) do
    if order.status == "pending" then
      order.remaining = (order.remaining or 0) - dt
      if order.remaining <= 0 then
        local ok, err, retry = deliverOrder(order)
        if ok then
          changed = true
        elseif retry then
          -- Keep the order ready; it is delivered as soon as the player is on the garage's map.
          order.remaining = 0
        else
          failOrder(order, err)
          changed = true
        end
      end
    end
  end
  if changed then
    saveOrders()
    local ok = pcall(guihooks.trigger, "vehicleOrderingUpdated")
    if not ok then log("W", TAG, "could not notify the UI") end
  end
end

-- Garage computer tile -----------------------------------------------------------------------------

function M.onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if not menuData or not computerFunctions or not computerFunctions.general then return end
  local facility = menuData.computerFacility
  local garageId = facility and facility.garageId and tostring(facility.garageId) or nil
  if not garageIsOrderable(garageId) then return end
  if computerFunctions.general.vehicleOrdering then return end

  computerFunctions.general.vehicleOrdering = {
    id = "vehicleOrdering",
    label = "Order Vehicle",
    order = 900,
    routeTarget = "overhaul.computer.vehicleOrdering",
    callback = function(computerId)
      extensions.ui_router.navigate("overhaul.computer.vehicleOrdering", {computerId = computerId})
    end,
  }
end

return M
