-- Vehicle damage snapshots: session storage, restoration and career save capture.
-- Map: Inventory and damage queries; Session state; Save tasks; Capture replies; Saving a vehicle's damage; Loading and clearing; Profile saves; Hooks.

local M = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")
local vehicleCallbacks = require("overhaul/lib/vehicles/callbacks")
local repairConfig = require('overhaul/lib/repair/operationSettings')

-- Inventory and damage queries -----------------------------------------------------------------

local function getSpawnedVehicles()
  local inventoryIdToVehId = overhaul_career_garage_inventory.getMapInventoryIdToVehId()
  local spawnedVehicles = {}
  for inventoryId, vehId in pairs(inventoryIdToVehId) do
    spawnedVehicles[inventoryId] = true
  end
  return spawnedVehicles
end

local function getDamagedVehicles()
  local spawnedVehicles = getSpawnedVehicles()
  local damagedVehicles = {}
  for inventoryId, _ in pairs(spawnedVehicles) do
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if vehicle then
      local brokenPartCount = overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions)
      if brokenPartCount > 0 then
        damagedVehicles[inventoryId] = true
      end
    end
  end

  return damagedVehicles
end

-- A car whose saved damage is not restored yet must keep its saved file, not its pristine live state.
local function damageRestorePending(inventoryId)
  local inventory = overhaul_career_garage_inventory
  return inventory and inventory.isDamageRestorePending and inventory.isDamageRestorePending(inventoryId)
end

-- Session state -------------------------------------------------------------------------------

local SESSION_DIR = "/temp/rls_career/damageSession/"
local DAMAGE_SUBDIR = "/career/vehicles/damage/"
local FILE_SUFFIX = "_damageState.json"
local SAVE_EXTENSION = "damageManager"
-- A silent car is asked once more, then the save keeps the last damage it is known to have.
local MAX_CAPTURE_ATTEMPTS = 2

-- sessionState: "pending", "written", "failed" or "cleared" per vehicle key.
local sessionState = {}
local requestSeq = {}
local captures = {}
local saveTask
local captureSequenceCounter = 0
local captureEpoch = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
local clearUndamagedVehicle

local function fileName(inventoryId)
  return tostring(inventoryId) .. FILE_SUFFIX
end

local function getSessionFile(inventoryId)
  return SESSION_DIR .. fileName(inventoryId)
end

local function getLoadedSaveFile(inventoryId)
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  return currentSavePath .. DAMAGE_SUBDIR .. fileName(inventoryId)
end

-- The file that holds this vehicle's damage now: the session copy once one exists, else the loaded save.
local function getVehicleSaveFile(inventoryId)
  local state = sessionState[tostring(inventoryId)]
  if state == "cleared" then return nil end
  if state == "written" or state == "pending" then return getSessionFile(inventoryId) end
  return getLoadedSaveFile(inventoryId)
end

local function nextCaptureSequence(inventoryId)
  captureSequenceCounter = captureSequenceCounter + 1
  requestSeq[tostring(inventoryId)] = captureSequenceCounter
  return captureSequenceCounter
end

-- Save tasks -----------------------------------------------------------------------------------

local function ensureDirFor(file, writer)
  local dir = file and string.match(file, "^(.*)/[^/]+$")
  if dir and not writer.exists(dir) then
    writer.mkdir(dir, true)
  end
end

local function taskIsCurrent(task)
  return task and overhaul_career_saveSystem.isAsyncSaveExtensionCurrent(SAVE_EXTENSION, task.generation)
end

local function finishSave(task)
  if taskIsCurrent(task) and task.snapshotDone and task.inventoryDone and task.pending == 0 then
    overhaul_career_saveSystem.asyncSaveExtensionFinished(SAVE_EXTENSION, task.generation)
  end
end

local function failSave(task, message)
  if taskIsCurrent(task) then
    log('E', 'damageManager', message)
    overhaul_career_saveSystem.saveFailed(message)
  end
end

local function copyDamage(source, destination, task, writer)
  ensureDirFor(destination, writer)
  if writer.copy(source, destination) ~= 0 then
    failSave(task, "Failed to copy damage state to " .. destination)
    return false
  end
  return true
end

local onCaptureDeadline -- set once the retry and fallback paths below exist

local function hasLiveSaveTarget(capture)
  for _, target in ipairs(capture.targets) do
    if taskIsCurrent(target.task) then return true end
  end
  return false
end

-- A capture joined to a save gets a bounded wait; the deadline owns the retry and the fallback.
local function ensureCaptureDeadline(capture)
  if capture.deadlineScheduled then return end
  capture.deadlineScheduled = true
  core_jobsystem.create(function(job)
    job.sleep(repairConfig.get().captureTimeoutS)
    onCaptureDeadline(capture)
  end)
end

local function attachTarget(capture, destination, task)
  if not taskIsCurrent(task) then return end
  for _, target in ipairs(capture.targets) do
    if target.task == task and target.file == destination then return end
  end
  capture.targets[#capture.targets + 1] = {file = destination, task = task}
  task.pending = task.pending + 1
  log('D', 'damageManager', string.format('Save damage queued generation=%s inventoryId=%s pending=%d',
    tostring(task.generation), capture.key, task.pending))
  ensureCaptureDeadline(capture)
end

local function finishCapture(capture, ok, reason)
  local done = capture and capture.done
  if not done then return end
  capture.done = nil
  local called, err = pcall(done, ok, reason)
  if not called then log('E', 'damageManager', 'Damage capture completion failed: ' .. tostring(err)) end
end

local function clearSessionStore()
  for _, capture in pairs(captures) do finishCapture(capture, false, 'Career changed') end
  failSave(saveTask, "Damage capture cancelled by career change")
  sessionState, requestSeq, captures, saveTask = {}, {}, {}, nil
  if FS:directoryExists(SESSION_DIR) then
    for _, file in ipairs(FS:findFiles(SESSION_DIR, '*' .. FILE_SUFFIX, 0, false, false) or {}) do
      FS:removeFile(file)
    end
  end
end

-- Capture replies ------------------------------------------------------------------------------

function M.deleteVehicleDelayed(vehId)
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    local object = be:getObjectByID(vehId)
    if object then object:delete() end
  end)
end

-- Copies a finished capture to the session file (when it is still the latest request) and to every target.
local function onDamageDataWritten(writer, inventoryId, writtenFile, captureSequence, undamaged)
  local key = tostring(inventoryId)
  captureSequence = tonumber(captureSequence)
  local capture = captures[captureSequence]
  if not capture or capture.key ~= key or capture.file ~= writtenFile then return end
  if capture.discarded then
    captures[captureSequence] = nil
    writer.remove(writtenFile)
    return
  end
  local current = requestSeq[key] == captureSequence
  if #capture.targets > 0 then
    log('D', 'damageManager', string.format('Save damage replied inventoryId=%s sequence=%d current=%s written=%s',
      key, captureSequence, tostring(current), tostring(undamaged or FS:fileExists(writtenFile))))
  end
  local successful = false
  if undamaged then
    if current then
      clearUndamagedVehicle(inventoryId, key, getSessionFile(key), false, true, writer)
    end
    for _, target in ipairs(capture.targets) do
      if taskIsCurrent(target.task) then
        clearUndamagedVehicle(inventoryId, key, target.file, false, false, writer, true)
        target.task.pending = target.task.pending - 1
        finishSave(target.task)
      end
    end
    captures[captureSequence] = nil
    finishCapture(capture, current, not current and 'Capture superseded' or nil)
    return
  end
  local written = FS:fileExists(writtenFile)
  if requestSeq[key] == captureSequence then
    if written and copyDamage(writtenFile, getSessionFile(key), saveTask, writer) then
      sessionState[key] = "written"
      successful = true
    else
      sessionState[key] = capture.previousState
    end
  end
  for _, target in ipairs(capture.targets) do
    if taskIsCurrent(target.task) then
      if written then
        copyDamage(writtenFile, target.file, target.task, writer)
      else
        failSave(target.task, "Vehicle damage capture did not write " .. writtenFile)
      end
      target.task.pending = target.task.pending - 1
      finishSave(target.task)
    end
  end
  captures[captureSequence] = nil
  writer.remove(writtenFile)
  finishCapture(capture, successful, not successful and (current and 'Damage snapshot was not written' or 'Capture superseded') or nil)
end

function M.onDamageDataWritten(...)
  return overhaul_career_saveSystem.captureSaveWrites(onDamageDataWritten, ...)
end

-- Saving a vehicle's damage ----------------------------------------------------------------------

-- A damaged car answers a capture through its own Lua. A silent car is asked once more after being
-- woken, and the save then keeps the last snapshot that car is known to have.
local function captureFileFor(key, sequence)
  return SESSION_DIR .. key .. "_capture_" .. captureEpoch .. "_"
    .. tostring(saveTask and saveTask.generation or "session") .. "_" .. sequence .. FILE_SUFFIX
end

-- The name the player knows a car by, or its inventory id once the record is gone.
local function vehicleLabel(inventoryId)
  local inventory = overhaul_career_garage_inventory
  local name = inventory.getVehicleNiceNameTranslated and inventory.getVehicleNiceNameTranslated(inventoryId)
  if type(name) ~= 'string' or name == '' then
    local record = inventory.getVehicles()[inventoryId]
    name = record and (record.niceName or record.model)
    if type(name) == 'table' and core_locales then name = core_locales.translateWithOrWithoutContext(name) end
  end
  if type(name) ~= 'string' or name == '' then return 'vehicle ' .. tostring(inventoryId) end
  return name
end

-- Cars whose damage had to come from the last snapshot, reported once the save completes.
local function noteStaleVehicle(task, label)
  if not task then return end
  local stale = task.staleVehicles
  if not stale then stale = {} task.staleVehicles = stale end
  for _, name in ipairs(stale) do
    if name == label then return end
  end
  stale[#stale + 1] = label
end

-- Asks the vehicle to write its damage to captureFile, then to reply; a removed car is deleted after the reply.
local function queueDamageCapture(capture, object, vehId, key, captureFile, captureSequence, removeVehicle, inspectDamage)
  local replyId = vehicleCallbacks.open('damageDataWritten', {owner = 'damageManager', timeout = false})
  capture.replyId = replyId
  local replyArguments = string.format("%q, %q, %d", key, captureFile, captureSequence)
  local reply = string.format("obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'damageDataWritten', %q));",
    replyId, replyArguments)
  local saveCommand = "extensions.load('overhaulDamageState'); "
    .. vehicleCommands.call("overhaulDamageState", "saveDamageData", captureFile) .. "; " .. reply
  if inspectDamage then
    local pristineReply = string.format("obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'damageDataWritten', %q));",
      replyId, replyArguments .. ', true')
    -- Part conditions can miss a dent with no broken beam; ask the live shape before deleting its saved state.
    saveCommand = "extensions.load('overhaulDamageState'); if " .. vehicleCommands.call('overhaulDamageState', 'hasStructuralDamage') .. " then "
      .. saveCommand .. " else " .. pristineReply .. " end;"
  end
  if not removeVehicle then
    object:queueLuaCommand(saveCommand)
    return
  end
  local deleteReplyId = vehicleCallbacks.open('damageVehicleDelete', {owner = 'damageManager', timeout = false})
  object:queueLuaCommand(saveCommand .. " obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(" .. deleteReplyId .. ", 'damageVehicleDelete', " .. vehId .. "));")
end

-- A capture that gave up: its save targets fail, and the caller's completion hears why.
local function failCapture(capture, reason)
  if captures[capture.sequence] ~= capture or capture.discarded then return end
  capture.discarded = true
  local key = capture.key
  if requestSeq[key] == capture.sequence then
    nextCaptureSequence(capture.inventoryId)
    sessionState[key] = capture.previousState
  end
  for _, target in ipairs(capture.targets) do
    if taskIsCurrent(target.task) then
      failSave(target.task, reason)
      target.task.pending = target.task.pending - 1
    end
  end
  capture.targets = {}
  finishCapture(capture, false, reason)
end

-- Starts a live capture of a damaged vehicle; the reply copies the capture to its save targets.
local function captureDamagedVehicle(inventoryId, key, saveFile, removeVehicle, intoSession, writer, inspectDamage, done)
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local object = be:getObjectByID(vehId)
  if not object then
    if not intoSession then failSave(saveTask, "Missing vehicle for damage capture " .. key) end
    return
  end
  local previous = captures[requestSeq[key]]
  finishCapture(previous, false, 'Capture superseded')
  local captureSequence = nextCaptureSequence(inventoryId)
  local captureFile = captureFileFor(key, captureSequence)
  ensureDirFor(captureFile, writer)
  local previousState = sessionState[key]
  if previous then previousState = previous.previousState end
  local capture = {key = key, inventoryId = inventoryId, vehId = vehId, sequence = captureSequence, attempt = 1,
    file = captureFile, targets = {}, done = done, previousState = previousState,
    removeVehicle = removeVehicle, inspectDamage = inspectDamage}
  captures[captureSequence] = capture
  sessionState[key] = "pending"
  if not intoSession then attachTarget(capture, saveFile, saveTask) end
  -- A hibernated car does not run queued vehicle Lua: wake it, or the capture would never answer.
  local inventory = overhaul_career_garage_inventory
  if vehId and inventory.wakeVehicle and inventory.wakeVehicle(vehId) then
    log('D', 'damageManager', string.format('Damage capture woke hibernated vehId=%s inventoryId=%s', tostring(vehId), key))
  end
  local queued, err = pcall(queueDamageCapture, capture, object, vehId, key, captureFile, captureSequence, removeVehicle, inspectDamage)
  if not queued then failCapture(capture, 'Damage capture failed: ' .. tostring(err)); return capture end
  if done then
    core_jobsystem.create(function(job)
      job.sleep(repairConfig.get().captureTimeoutS)
      -- A save-joined capture is timed by its save deadline, which retries before it gives up.
      if capture.done and not capture.discarded and not hasLiveSaveTarget(capture) then
        failCapture(capture, 'Damage capture timed out')
      end
    end)
  end
  return capture
end

-- True when the file holds a damage snapshot the vehicle can be restored from.
local function isValidDamageSnapshot(file)
  if not (file and FS:fileExists(file)) then return false end
  local snapshot = jsonReadFile(file)
  return type(snapshot) == 'table' and type(snapshot.partStates) == 'table'
end

-- The newest damage the car is known to have: its session copy, else the loaded save's copy.
-- A cleared car has no snapshot, so a silent capture still fails rather than saving it undamaged.
local function lastKnownDamageSource(inventoryId)
  local sessionFile = getSessionFile(inventoryId)
  if isValidDamageSnapshot(sessionFile) then return sessionFile, 'session' end
  local loaded = getLoadedSaveFile(inventoryId)
  if isValidDamageSnapshot(loaded) then return loaded, 'save' end
  return nil, nil
end

-- Drops the request so a late reply can neither write the save nor count a second time.
local function retireCapture(capture)
  capture.discarded = true
  capture.targets, capture.done = {}, nil
  if captures[capture.sequence] == capture then captures[capture.sequence] = nil end
  if capture.replyId then
    vehicleCallbacks.close(capture.replyId)
    capture.replyId = nil
  end
end

local fallbackSaveCapture -- defined below; the retry hands over to it when there is nothing to ask

-- Re-asks a silent car. A command queued while the car was hibernated never runs, so wake it first.
local function retrySaveCapture(capture)
  local key, inventoryId = capture.key, capture.inventoryId
  local inventory = overhaul_career_garage_inventory
  -- A respawned car answers from its new object, so never re-ask the id the silent capture used.
  local currentVehId = inventory.getVehicleIdFromInventoryId and inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehId = currentVehId or capture.vehId
  local object = vehId and be:getObjectByID(vehId) or nil
  if not object then
    log('W', 'damageManager', string.format('Save damage retry skipped inventoryId=%s vehId=%s reason=vehicle missing',
      key, tostring(vehId)))
    return fallbackSaveCapture(capture)
  end
  local woke = inventory.wakeVehicle and inventory.wakeVehicle(vehId) or false
  local sequence = nextCaptureSequence(inventoryId)
  local retry = {key = key, inventoryId = inventoryId, vehId = vehId, sequence = sequence,
    attempt = (capture.attempt or 1) + 1, file = captureFileFor(key, sequence),
    targets = capture.targets, done = capture.done, previousState = capture.previousState,
    removeVehicle = capture.removeVehicle, inspectDamage = capture.inspectDamage}
  retireCapture(capture)
  captures[sequence] = retry
  sessionState[key] = 'pending'
  log('D', 'damageManager', string.format('Save damage retry inventoryId=%s vehId=%s sequence=%d attempt=%d woke=%s',
    key, tostring(vehId), sequence, retry.attempt, tostring(woke == true)))
  local queued, err = pcall(queueDamageCapture, retry, object, vehId, key, retry.file, sequence, retry.removeVehicle, retry.inspectDamage)
  if not queued then
    log('E', 'damageManager', 'Save damage retry could not queue: ' .. tostring(err))
    return fallbackSaveCapture(retry)
  end
  ensureCaptureDeadline(retry)
end

-- Last resort: the save keeps the newest damage the car is known to have, or fails rather than
-- recording missing damage as if the car were undamaged.
fallbackSaveCapture = function(capture)
  local key, inventoryId, vehId = capture.key, capture.inventoryId, capture.vehId
  local targets = capture.targets or {}
  retireCapture(capture)
  local source, kind = lastKnownDamageSource(inventoryId)
  if requestSeq[key] == capture.sequence then
    nextCaptureSequence(inventoryId)
    sessionState[key] = source and 'written' or capture.previousState
  end
  local live = {}
  for _, target in ipairs(targets) do
    if taskIsCurrent(target.task) then live[#live + 1] = target end
  end
  local label = vehicleLabel(inventoryId)
  if not source then
    log('E', 'damageManager', string.format('Save damage unavailable inventoryId=%s vehId=%s vehicle=%s',
      key, tostring(vehId), label))
    for _, target in ipairs(live) do
      failSave(target.task, 'the current damage for ' .. label .. ' could not be read')
      target.task.pending = target.task.pending - 1
    end
    return
  end
  if #live > 0 then noteStaleVehicle(saveTask, label) end
  log('W', 'damageManager', string.format('Save damage fallback inventoryId=%s vehId=%s vehicle=%s source=%s attempt=%d',
    key, tostring(vehId), label, tostring(kind), capture.attempt or 1))
  overhaul_career_saveSystem.captureSaveWrites(function(writer)
    local sessionFile = getSessionFile(inventoryId)
    if source ~= sessionFile then copyDamage(source, sessionFile, saveTask, writer) end
    for _, target in ipairs(live) do
      if target.file ~= sessionFile then copyDamage(source, target.file, target.task, writer) end
    end
  end)
  for _, target in ipairs(live) do
    target.task.pending = target.task.pending - 1
    finishSave(target.task)
  end
end

onCaptureDeadline = function(capture)
  if capture.discarded or captures[capture.sequence] ~= capture then return end
  if not hasLiveSaveTarget(capture) then return end
  local inventory = overhaul_career_garage_inventory
  local hibernated = inventory and inventory.isVehicleHibernated and capture.vehId
    and inventory.isVehicleHibernated(capture.vehId) == true
  log('W', 'damageManager', string.format('Save damage capture silent inventoryId=%s vehId=%s sequence=%d attempt=%d hibernated=%s',
    capture.key, tostring(capture.vehId), capture.sequence, capture.attempt or 1, tostring(hibernated or false)))
  if (capture.attempt or 1) < MAX_CAPTURE_ATTEMPTS then
    retrySaveCapture(capture)
  else
    fallbackSaveCapture(capture)
  end
end

-- Resets the damage tracking inside a spawned vehicle, if it has one.
local function resetLiveDamageTracking(inventoryId)
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then return end
  local object = be:getObjectByID(vehId)
  if object then
    object:queueLuaCommand("if overhaulDamageState then " .. vehicleCommands.call("overhaulDamageState", "reset") .. "; end")
  end
end

-- An undamaged vehicle drops its saved damage; a removed car is deleted first.
clearUndamagedVehicle = function(inventoryId, key, saveFile, removeVehicle, intoSession, writer, preserveSession)
  if removeVehicle then
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    local object = be:getObjectByID(vehId)
    if object then object:delete() end
  end
  writer.remove(saveFile)
  if preserveSession then return end
  nextCaptureSequence(inventoryId)
  sessionState[key] = "cleared"
  if not intoSession then
    writer.remove(getSessionFile(inventoryId))
  end
  resetLiveDamageTracking(inventoryId)
end

-- A car the profile save left to its live capture, but which is stored or still restoring when its turn comes,
-- keeps the damage it already has: an in-flight capture, the session copy or the loaded save's file. Cleared keeps none.
local function keepCurrentDamage(inventoryId, key, saveFile, writer)
  if sessionState[key] == "pending" then
    local capture = captures[requestSeq[key]]
    if capture then attachTarget(capture, saveFile, saveTask)
    else failSave(saveTask, "Missing pending damage capture for " .. key) end
    return
  end
  local source = getVehicleSaveFile(inventoryId)
  if source and source ~= saveFile and FS:fileExists(source) then copyDamage(source, saveFile, saveTask, writer) end
end

function M.saveDamageState(inventoryId, saveFile, removeVehicle, partConditions, writer, done)
  local inventory = overhaul_career_garage_inventory
  if inventory.isTransientBuild and inventory.isTransientBuild(inventoryId) then return end
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  local key = tostring(inventoryId)
  local intoSession = not saveFile
  if intoSession then
    saveFile = getSessionFile(inventoryId)
  end
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local spawnedVehicles = overhaul_career_garage_inventory.getMapInventoryIdToVehId()
  if not (vehicle and spawnedVehicles[inventoryId] and not damageRestorePending(inventoryId)) then
    local liveAtSaveStart = saveTask and saveTask.liveFiles and saveTask.liveFiles[fileName(inventoryId)]
    if vehicle and not intoSession and liveAtSaveStart then keepCurrentDamage(inventoryId, key, saveFile, writer) end
    return
  end

  local pendingCapture = captures[requestSeq[key]]
  if not intoSession and not removeVehicle and pendingCapture then
    for _, target in ipairs(pendingCapture.targets) do
      if target.task == saveTask and target.file == saveFile then return end
    end
  end
  local numberOfBrokenParts = overhaul_career_market_valueCalculator.getNumberOfBrokenParts(partConditions or vehicle.partConditions)
  return captureDamagedVehicle(inventoryId, key, saveFile, removeVehicle, intoSession, writer, numberOfBrokenParts == 0, done)
end

-- Replacement authorization comes only from this request's completed snapshot.
function M.captureDamageState(inventoryId, done)
  local completed = false
  local function complete(ok, reason)
    if completed then return end
    completed = true
    if done then done(ok, reason) end
  end
  local started, capture = pcall(M.saveDamageState, inventoryId, nil, false, nil, nil, complete)
  if not started or not capture then
    complete(false, started and 'Damage capture unavailable' or tostring(capture))
    return false
  end
  return true
end

-- Paid tire work edits only generated beams belonging to the selected wheels.
-- The rest of the snapshot still uses the ordinary same-build replay.
function M.repairTireDamage(inventoryId, wheelNames)
  if M.isDamageCapturePending(inventoryId) then return false end
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local data = vehId and core_vehicle_manager.getVehicleData(vehId)
  local vdata = data and data.vdata
  if not vdata or not vdata.wheels or not vdata.beams then return false end
  local selected, found = {}, {}
  for wheelId, wheel in pairs(vdata.wheels) do
    if wheelNames[wheel.name] then selected[wheelId], found[wheel.name] = true, true end
  end
  for name, paid in pairs(wheelNames) do
    if paid and not found[name] then return false end
  end
  if not next(selected) then return false end
  local file = getVehicleSaveFile(inventoryId)
  if not file or not FS:fileExists(file) then return true end
  local snapshot = jsonReadFile(file)
  if not snapshot or type(snapshot.partStates) ~= 'table' then return false end
  local wheelBeams = {}
  for _, beam in pairs(vdata.beams) do
    if selected[beam.wheelID] then wheelBeams[beam.cid] = true end
  end
  for _, part in pairs(snapshot.partStates) do
    for cid, beam in pairs(part.beams or {}) do
      if wheelBeams[tonumber(cid)] then beam.broken, beam.deformed = nil, nil end
    end
  end
  local writer = overhaul_career_saveSystem.getSaveWriter()
  local sessionFile = getSessionFile(inventoryId)
  ensureDirFor(sessionFile, writer)
  if not writer.json(sessionFile, snapshot, false) then return false end
  sessionState[tostring(inventoryId)] = 'written'
  return true
end

-- Loading and clearing -------------------------------------------------------------------------

function M.hasDamageState(inventoryId)
  -- The replacement can bind before the outgoing vehicle's capture reply arrives.
  if M.isDamageCapturePending(inventoryId) then return true end
  local file = getVehicleSaveFile(inventoryId)
  return file ~= nil and FS:fileExists(file)
end

function M.isDamageCapturePending(inventoryId)
  return sessionState[tostring(inventoryId)] == "pending"
end

function M.loadDamageState(inventoryId)
  if M.isDamageCapturePending(inventoryId) then return false end
  local saveFile = getVehicleSaveFile(inventoryId)
  local object = be:getObjectByID(overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId))
  if not object then
    return
  end

  if saveFile and FS:fileExists(saveFile) then
    object:queueLuaCommand("extensions.load('overhaulDamageState'); " .. vehicleCommands.call("overhaulDamageState", "loadDamageData", saveFile) .. ";")
  else
    object:queueLuaCommand("extensions.load('overhaulDamageState'); if overhaulDamageState then " .. vehicleCommands.call("overhaulDamageState", "reset") .. "; end")
  end
end

function M.clearDamageState(inventoryId)
  finishCapture(captures[requestSeq[tostring(inventoryId)]], false, 'Damage state cleared')
  nextCaptureSequence(inventoryId)
  sessionState[tostring(inventoryId)] = "cleared"
  overhaul_career_saveSystem.getSaveWriter().remove(getSessionFile(inventoryId))
  resetLiveDamageTracking(inventoryId)
end

-- Removed inventory ids may be reused before saving; late captures must never revive their state.
function M.discardDamageState(inventoryId)
  local key = tostring(inventoryId)
  local writer = overhaul_career_saveSystem.getSaveWriter()
  nextCaptureSequence(inventoryId)
  sessionState[key] = 'cleared'
  writer.remove(getSessionFile(inventoryId))
  for _, capture in pairs(captures) do
    if capture.key == key and not capture.discarded then
      capture.discarded = true
      finishCapture(capture, false, 'Vehicle removed')
      for _, target in ipairs(capture.targets) do
        if taskIsCurrent(target.task) then
          writer.remove(target.file)
          target.task.pending = target.task.pending - 1
          finishSave(target.task)
        end
      end
      capture.targets = {}
    end
  end
end

function M.repairPartsAndReloadState(inventoryId, partsToRepair, partsToRemove)
  if not inventoryId then
    log('E', 'damageManager.repairParts', 'No inventoryId provided.')
    return
  end

  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then
    log('E', 'damageManager.repairParts', 'Could not find vehicleId for inventoryId: ' .. inventoryId)
    return
  end

  local object = be:getObjectByID(vehId)
  if not object then
    log('E', 'damageManager.repairParts', 'Could not find vehicle object for vehId: ' .. vehId)
    return
  end

  local saveFile = getVehicleSaveFile(inventoryId)
  if not saveFile then
    log('I', 'damageManager.repairParts', 'No damage state for inventoryId: ' .. inventoryId .. '. Skipping reload.')
    return
  end

  if not FS:fileExists(saveFile) then
    log('I', 'damageManager.repairParts', 'No damage save file found for vehicle ' .. inventoryId .. ' at ' .. saveFile .. '. Skipping reload.')
    return
  end

  log('I', 'damageManager.repairParts', 'Attempting to repair parts for vehicle ' .. inventoryId .. '. Using save file: ' .. saveFile)

  local command = "extensions.load('overhaulDamageState'); "
    .. vehicleCommands.call("overhaulDamageState", "loadDamageData", saveFile:gsub("\\", "/"), partsToRepair, partsToRemove)
    .. ";"

  object:queueLuaCommand(command)
end

-- Profile saves -------------------------------------------------------------------------------

local function listDamageFiles(dir, writer)
  local out = {}
  if dir and writer.exists(dir) then
    for _, filePath in ipairs(writer.findFiles(dir, '*' .. FILE_SUFFIX, 0, false, false) or {}) do
      local _, name, _ = path.split(filePath)
      out[name] = filePath
    end
  end
  return out
end

-- Damage files of spawned cars belong to the live capture, so the profile save leaves them alone.
local function collectSpawnedDamageFiles()
  local spawned = {}
  local inventory = overhaul_career_garage_inventory
  for inventoryId, _ in pairs(inventory and inventory.getMapInventoryIdToVehId and inventory.getMapInventoryIdToVehId() or {}) do
    local transient = inventory.isTransientBuild and inventory.isTransientBuild(inventoryId)
    if not damageRestorePending(inventoryId) and not transient then spawned[fileName(inventoryId)] = true end
  end
  return spawned
end

-- Keeps the saved damage of cars that are not spawned or captured, copying it when the profile folder changes.
local function keepSavedDamage(oldSavePath, newDamageDir, sameFolder, spawned, keep, writer)
  for name, oldFilePath in pairs(oldSavePath and listDamageFiles(oldSavePath .. DAMAGE_SUBDIR, writer) or {}) do
    local key = string.sub(name, 1, -string.len(FILE_SUFFIX) - 1)
    if not sessionState[key] and not spawned[name] then
      keep[name] = true
      if not sameFolder then
        copyDamage(oldFilePath, newDamageDir .. name, saveTask, writer)
      end
    end
  end
end

-- Session copies move into the profile folder; a pending capture is redirected to write there too.
local function keepSessionDamage(newDamageDir, spawned, keep, writer)
  for key, state in pairs(sessionState) do
    local name = fileName(key)
    if not spawned[name] and (state == "written" or state == "pending") then
      local sessionFile = getSessionFile(key)
      if FS:fileExists(sessionFile) then
        keep[name] = true
        copyDamage(sessionFile, newDamageDir .. name, saveTask, writer)
      elseif state == "written" then
        failSave(saveTask, "Missing session damage state for " .. key)
      end
      if state == "pending" then
        keep[name] = true
        local capture = captures[requestSeq[key]]
        if capture then
          attachTarget(capture, newDamageDir .. name, saveTask)
        else
          failSave(saveTask, "Missing pending damage capture for " .. key)
        end
      end
    elseif state == "failed" then
      failSave(saveTask, "Damage capture failed for " .. key)
    end
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not currentSavePath then return end
  local _, oldSavePath = overhaul_career_saveSystem.getCurrentProfile()
  local newDamageDir = currentSavePath .. DAMAGE_SUBDIR
  if not writer.exists(newDamageDir) then
    -- A fresh slot has no vehicles directory until its queued writers run.
    writer.mkdir(newDamageDir, true)
  end

  local spawned = collectSpawnedDamageFiles()
  -- These cars are left to their live capture; one stored or respawned before its turn keeps its current damage.
  if saveTask then saveTask.liveFiles = spawned end
  local keep = {}
  local sameFolder = oldSavePath == currentSavePath
  keepSavedDamage(oldSavePath, newDamageDir, sameFolder, spawned, keep, writer)
  keepSessionDamage(newDamageDir, spawned, keep, writer)

  for name, newFilePath in pairs(listDamageFiles(newDamageDir, writer)) do
    if not keep[name] and not spawned[name] then
      writer.remove(newFilePath)
    end
  end
  if saveTask then
    saveTask.snapshotDone = true
    finishSave(saveTask)
  end
end

-- Hooks ----------------------------------------------------------------------------------------

M.onExtensionLoaded = clearSessionStore
M.onExtensionUnloaded = clearSessionStore
M.onOverhaulActive = clearSessionStore
M.onOverhaulBeforeSetProfile = clearSessionStore
M.onOverhaulSaveCurrentProfileAsyncStart = function()
  saveTask = {generation = overhaul_career_saveSystem.registerAsyncSaveExtension(SAVE_EXTENSION), pending = 0}
end
M.onOverhaulVehicleSaveFinished = function()
  if saveTask then
    saveTask.inventoryDone = true
    finishSave(saveTask)
  end
end

-- A completed save that had to reuse old damage tells the player which cars need another save.
M.onOverhaulSaveFinished = function()
  local stale = saveTask and saveTask.staleVehicles
  if not stale or #stale == 0 then return end
  saveTask.staleVehicles = nil
  local names = table.concat(stale, ', ')
  log('W', 'damageManager', 'Save kept the last known damage for: ' .. names)
  guihooks.trigger("toastrMsg", {type = "warning", label = "career-save", title = "Vehicle damage not updated",
    msg = string.format("The current damage for %s could not be read, so the last saved damage was kept. Save again to update it.", names),
    config = {timeOut = 20000}})
end

M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.getSpawnedVehicles = getSpawnedVehicles
M.getDamagedVehicles = getDamagedVehicles
function M.onCheatVehicleRecovered(inventoryId)
  return M.clearDamageState(inventoryId)
end

return M
