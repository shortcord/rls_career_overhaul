-- Save damage capture: a vehicle that never answers must not hold the career save open.
-- Runs damageManager.lua against stubbed engine globals; no BeamNG needed.

local logs, toasts = {}, {}
log = function(level, tag, message)
  logs[#logs + 1] = {level = level, tag = tag, message = message}
end

local function logged(pattern)
  for _, entry in ipairs(logs) do
    if entry.message:find(pattern, 1, true) then return entry end
  end
  return nil
end

local function toastNaming(text)
  for _, toast in ipairs(toasts) do
    if toast.event == 'toastrMsg' and tostring(toast.payload.msg):find(text, 1, true) then return toast end
  end
  return nil
end

-- Files and folders -----------------------------------------------------------------------------

local files = {}
local dirs = {['/temp/rls_career/damageSession'] = true}

FS = {}
function FS:fileExists(path) return files[path] ~= nil end
function FS:directoryExists(path) return dirs[path] == true end
function FS:directoryCreate(path) dirs[path] = true return 0 end
function FS:removeFile(path) files[path] = nil return 0 end
function FS:copyFile(source, destination)
  if files[source] == nil then return 1 end
  files[destination] = files[source]
  return 0
end
function FS:findFiles(dir, pattern)
  local prefix = dir:sub(-1) == '/' and dir or dir .. '/'
  local match = '^' .. prefix:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '[^/]*') .. pattern:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '[^/]*') .. '$'
  local out = {}
  for path in pairs(files) do
    if path:match(match) then out[#out + 1] = path end
  end
  return out
end

path = {
  split = function(value)
    local dir, name = value:match('^(.*)/([^/]+)$')
    return dir or '', name or value
  end,
}

jsonReadFile = function(path) return files[path] end

-- Engine doubles --------------------------------------------------------------------------------

guihooks = {
  trigger = function(event, payload) toasts[#toasts + 1] = {event = event, payload = payload} end,
}

local objects = {}
local queued = {}

be = {
  getObjectByID = function(_, vehId) return objects[vehId] end,
}

local jobs = {}
core_jobsystem = {
  create = function(callback) jobs[#jobs + 1] = callback end,
}

local function runJobs()
  local running = jobs
  jobs = {}
  for _, callback in ipairs(running) do callback({sleep = function() end}) end
end

package.preload['overhaul/lib/vehicles/callbacks'] = function()
  local nextId = 7000
  return {
    open = function() nextId = nextId + 1 return nextId end,
    close = function() end,
  }
end

package.preload['overhaul/lib/vehicles/vehicleCommands'] = function()
  return {
    call = function(extension, fn, ...)
      return string.format('%s:%s(%q)', extension, fn, tostring((...)))
    end,
  }
end

package.preload['overhaul/lib/repair/operationSettings'] = function()
  return {get = function() return {captureTimeoutS = 5, replacementTimeoutS = 30} end}
end

-- Garage inventory double -----------------------------------------------------------------------

local inventory = {vehIds = {}, records = {}, hibernated = {}, woken = {}}
function inventory.getVehicleIdFromInventoryId(inventoryId) return inventory.vehIds[inventoryId] end
function inventory.getVehicles() return inventory.records end
function inventory.getMapInventoryIdToVehId() return inventory.vehIds end
function inventory.isDamageRestorePending() return false end
function inventory.isTransientBuild() return false end
function inventory.isVehicleHibernated(vehId) return inventory.hibernated[vehId] == true end
function inventory.getVehicleNiceNameTranslated(inventoryId)
  local record = inventory.records[inventoryId]
  return record and record.niceName
end
function inventory.wakeVehicle(vehId)
  if inventory.hibernated[vehId] ~= true then return false end
  inventory.woken[#inventory.woken + 1] = vehId
  inventory.hibernated[vehId] = nil
  return true
end

overhaul_career_garage_inventory = inventory
overhaul_career_market_valueCalculator = {getNumberOfBrokenParts = function() return 1 end}

-- Save system double ----------------------------------------------------------------------------

local currentWriter
local function newWriter()
  local writer = {}
  writer.json = function(file, value) files[file] = value return true end
  writer.copy = function(source, destination) return FS:copyFile(source, destination) end
  writer.remove = function(file) return FS:removeFile(file) end
  writer.mkdir = function(dir) dirs[dir] = true return true end
  writer.exists = function(dir) return dirs[dir] == true end
  writer.findFiles = function(...) return FS:findFiles(...) end
  writer.read = function(file) return files[file] end
  currentWriter = writer
  return writer
end

local saveSystem = {active = {}, generation = 0, finished = false, failed = nil, profilePath = '/saves/modded/autosave4_recovery'}
function saveSystem.registerAsyncSaveExtension(name)
  saveSystem.generation = saveSystem.generation + 1
  saveSystem.active[name] = saveSystem.generation
  return saveSystem.generation
end
function saveSystem.isAsyncSaveExtensionCurrent(name, generation)
  return generation ~= nil and saveSystem.active[name] == generation and generation == saveSystem.generation
end
function saveSystem.asyncSaveExtensionFinished(name, generation)
  if not saveSystem.isAsyncSaveExtensionCurrent(name, generation) then return end
  saveSystem.active[name] = nil
  saveSystem.finished = true
end
function saveSystem.saveFailed(reason) saveSystem.failed = reason end
function saveSystem.getCurrentProfile() return 'modded', saveSystem.profilePath end
function saveSystem.getSaveWriter() return currentWriter or newWriter() end
function saveSystem.captureSaveWrites(callback, ...) return callback(currentWriter or newWriter(), ...) end
function saveSystem.withFeatureWrites(_, callback, ...) return callback(...) end
overhaul_career_saveSystem = saveSystem

local damageManager = dofile('lua/ge/extensions/overhaul/career/repair/damageManager.lua')

-- Fixture ---------------------------------------------------------------------------------------

local SAVE_PATH = '/saves/modded/autosave4'
local DAMAGE_DIR = SAVE_PATH .. '/career/vehicles/damage/'
local TARGET = DAMAGE_DIR .. '12_damageState.json'
local LAST_KNOWN = '/saves/modded/autosave4_recovery/career/vehicles/damage/12_damageState.json'
local SNAPSHOT = {partStates = {['/pickup'] = {}}}

local function reset(options)
  options = options or {}
  logs, files, queued, toasts = {}, {}, {}, {}
  jobs = {}
  inventory.vehIds, inventory.records, inventory.hibernated, inventory.woken = {}, {}, {}, {}
  for vehId in pairs(objects) do objects[vehId] = nil end
  dirs = {['/temp/rls_career/damageSession'] = true, [DAMAGE_DIR] = true}
  saveSystem.active, saveSystem.generation = {}, 0
  saveSystem.finished, saveSystem.failed = false, nil
  saveSystem.profilePath = '/saves/modded/autosave4_recovery'
  currentWriter = newWriter()
  if options.lastKnown then files[LAST_KNOWN] = SNAPSHOT end
  inventory.vehIds[12] = 5001
  inventory.records[12] = {partConditions = {}, niceName = 'Gavril D-Series'}
  if options.hibernated then inventory.hibernated[5001] = true end
  objects[5001] = {
    queueLuaCommand = function(_, command)
      queued[#queued + 1] = {vehId = 5001, command = command, hibernated = inventory.hibernated[5001] == true}
    end,
  }
end

-- Parses the capture identity a queued vehicle command carries.
local function captureOf(command)
  local key, file, sequence = command:match('\\"([^\\]*)\\", \\"([^\\]*)\\", (%d+)')
  return key, file, tonumber(sequence)
end

local function startSave()
  damageManager.onOverhaulSaveCurrentProfileAsyncStart()
  damageManager.saveDamageState(12, TARGET, nil, {}, currentWriter)
  damageManager.onOverhaulSaveCurrentProfile(SAVE_PATH, nil, currentWriter)
  damageManager.onOverhaulVehicleSaveFinished()
end

local function reply(written, undamaged)
  local key, file, sequence = captureOf(queued[#queued].command)
  if written then files[file] = SNAPSHOT end
  damageManager.onDamageDataWritten(key, file, sequence, undamaged)
end

-- Tests -----------------------------------------------------------------------------------------

local function testSaveFinishesWhenTheVehicleAnswers()
  reset({})
  startSave()
  reply(true, false)
  assert(saveSystem.finished, 'a replied capture must finish the save')
  assert(files[TARGET], 'the capture must be copied to the save target')
  assert(#queued == 1, 'a replied capture must not be retried')
  assert(#inventory.woken == 0, 'a replied capture must not wake the vehicle')
end

local function testHibernatedCarIsWokenBeforeTheCaptureIsQueued()
  reset({hibernated = true})
  startSave()
  assert(not queued[1].hibernated, 'the capture must not be queued to a sleeping car')
  assert(#inventory.woken == 1, 'the hibernated car must be woken before it is asked')
end

local function testMissingReplyRetriesTheCapture()
  reset({lastKnown = true})
  startSave()
  -- The car can hibernate again while the save waits; the retry must still reach it.
  inventory.hibernated[5001] = true
  runJobs()
  assert(#queued == 2, 'a silent capture must be requested once more, got ' .. #queued)
  assert(#inventory.woken == 1, 'the retry must wake the vehicle before asking again')
  assert(not queued[2].hibernated, 'the retry must be queued to an awake car')
  assert(logged('retry'), 'the retry must be logged')
  assert(not saveSystem.finished, 'the save must wait for the retry')
end

local function testRetryAnswerFinishesTheSave()
  reset({lastKnown = true})
  startSave()
  runJobs()
  reply(true, false)
  assert(saveSystem.finished, 'a replied retry must finish the save')
  assert(files[TARGET], 'the retry capture must be copied to the save target')
  assert(saveSystem.failed == nil, 'a replied retry must not fail the save')
end

local function testSilentRetryFallsBackToLastKnownDamage()
  reset({lastKnown = true})
  startSave()
  runJobs()
  runJobs()
  assert(saveSystem.finished, 'a silent retry must complete the save from the last known snapshot')
  assert(saveSystem.failed == nil, 'a stale fallback must not fail the save')
  assert(files[TARGET] == SNAPSHOT, 'the last known damage must be copied to the save target')
  assert(logged('fallback'), 'the fallback must be logged')
  assert(logged('12'), 'the fallback log must name the inventory id')
end

local function testSilentRetryWithoutSnapshotFailsTheSave()
  reset({})
  startSave()
  runJobs()
  runJobs()
  assert(not saveSystem.finished, 'a save without any damage snapshot must not complete')
  assert(saveSystem.failed and saveSystem.failed:find('Gavril D-Series', 1, true),
    'the failure must name the car, got ' .. tostring(saveSystem.failed))
end

local function testFallbackWarnsWhichCarKeptOldDamage()
  reset({lastKnown = true})
  startSave()
  runJobs()
  runJobs()
  damageManager.onOverhaulSaveFinished()
  local toast = toastNaming('Gavril D-Series')
  assert(toast, 'the fallback must warn the player which car kept its old damage')
  assert(toast.payload.type == 'warning', 'the fallback warning must not be an error')
end

local function testFallbackWarningListsEveryCar()
  reset({lastKnown = true})
  local otherTarget = DAMAGE_DIR .. '7_damageState.json'
  local otherLastKnown = '/saves/modded/autosave4_recovery/career/vehicles/damage/7_damageState.json'
  files[otherLastKnown] = SNAPSHOT
  inventory.vehIds[7] = 5300
  inventory.records[7] = {partConditions = {}, niceName = 'Bruckell EC9'}
  objects[5300] = {queueLuaCommand = function() end}
  damageManager.onOverhaulSaveCurrentProfileAsyncStart()
  damageManager.saveDamageState(12, TARGET, nil, {}, currentWriter)
  damageManager.saveDamageState(7, otherTarget, nil, {}, currentWriter)
  damageManager.onOverhaulSaveCurrentProfile(SAVE_PATH, nil, currentWriter)
  damageManager.onOverhaulVehicleSaveFinished()
  runJobs()
  runJobs()
  assert(saveSystem.finished, 'both stale cars must complete the save')
  damageManager.onOverhaulSaveFinished()
  local toast = toastNaming('Gavril D-Series')
  assert(toast, 'the warning must name the first car')
  assert(tostring(toast.payload.msg):find('Bruckell EC9', 1, true), 'the warning must name every car, got ' .. tostring(toast.payload.msg))
end

local function testLateReplyToTheRetiredCaptureIsIgnored()
  reset({lastKnown = true})
  startSave()
  local key, file, sequence = captureOf(queued[1].command)
  runJobs()
  files[file] = SNAPSHOT
  damageManager.onDamageDataWritten(key, file, sequence, false)
  assert(not saveSystem.finished, 'a retired capture must not finish the save')
  assert(not files[TARGET], 'a retired capture must not write the save target')
end

local function testRetryAsksTheRespawnedVehicle()
  reset({lastKnown = true})
  startSave()
  -- The car respawns while the save waits for an answer from the old object.
  objects[5001] = nil
  inventory.vehIds[12] = 5002
  objects[5002] = {
    queueLuaCommand = function(_, command)
      queued[#queued + 1] = {vehId = 5002, command = command, hibernated = inventory.hibernated[5002] == true}
    end,
  }
  runJobs()
  assert(queued[#queued].vehId == 5002, 'the retry must ask the respawned object, got ' .. tostring(queued[#queued].vehId))
  reply(true, false)
  assert(saveSystem.finished, 'a reply from the respawned car must finish the save')
end

local function testMissingVehicleFallsBackWithoutAsking()
  reset({lastKnown = true})
  startSave()
  objects[5001] = nil
  inventory.vehIds[12] = nil
  runJobs()
  assert(#queued == 1, 'a missing vehicle must not be asked again')
  assert(saveSystem.finished, 'a missing vehicle must complete from the last known snapshot')
  assert(files[TARGET] == SNAPSHOT, 'the missing vehicle must keep its last known damage')
end

testSaveFinishesWhenTheVehicleAnswers()
testHibernatedCarIsWokenBeforeTheCaptureIsQueued()
testMissingReplyRetriesTheCapture()
testRetryAnswerFinishesTheSave()
testSilentRetryFallsBackToLastKnownDamage()
testSilentRetryWithoutSnapshotFailsTheSave()
testLateReplyToTheRetiredCaptureIsIgnored()
testRetryAsksTheRespawnedVehicle()
testMissingVehicleFallsBackWithoutAsking()
testFallbackWarnsWhichCarKeptOldDamage()
testFallbackWarningListsEveryCar()
print('damage save retry: ok')
