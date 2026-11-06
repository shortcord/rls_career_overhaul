local M = {}

local logTag = "skeletonCoast.mapCompatibility"
local patchStateKey = "__rlsSkeletonCoastMapPatch"
local maxBuildAttempts = 3
local retryScheduled = false

local function isSkeletonCoast()
  return getCurrentLevelIdentifier and getCurrentLevelIdentifier() == "skeleton_coast"
end

local function installPatch()
  if not map or type(map.assureLoad) ~= "function" or type(map.reset) ~= "function" then
    log("E", logTag, "BeamNG map module is unavailable; compatibility patch was not installed")
    return false
  end

  local existing = rawget(_G, patchStateKey)
  if existing and map.assureLoad == existing.wrapper then
    return true
  end

  local originalAssureLoad = map.assureLoad
  local originalReset = map.reset

  local function safeAssureLoad(...)
    if not isSkeletonCoast() then
      return originalAssureLoad(...)
    end

    local ok, result = pcall(originalAssureLoad, ...)
    if ok then
      return result
    end

    local firstError = tostring(result)
    if retryScheduled then
      return nil
    end

    retryScheduled = true
    log(
      "W",
      logTag,
      string.format(
        "Skeleton Coast AI map build failed on attempt 1/%d; deferring retries until the scene settles. %s",
        maxBuildAttempts,
        firstError
      )
    )
    core_jobsystem.create(function(job)
      local finalError = firstError
      for attempt = 2, maxBuildAttempts do
        job.sleep(0.5)
        pcall(originalReset)
        ok, result = pcall(originalAssureLoad)
        if ok then
          retryScheduled = false
          log("I", logTag, string.format("Skeleton Coast AI map rebuild succeeded on attempt %d/%d", attempt, maxBuildAttempts))
          return
        end
        finalError = tostring(result)
      end

      retryScheduled = false
      log(
        "E",
        logTag,
        string.format(
          "Skeleton Coast AI map could not be built after %d attempts. First error: %s; final error: %s",
          maxBuildAttempts,
          firstError,
          finalError
        )
      )
    end)
    return nil
  end

  rawset(_G, patchStateKey, {
    originalAssureLoad = originalAssureLoad,
    wrapper = safeAssureLoad,
  })
  map.assureLoad = safeAssureLoad
  log("I", logTag, "Installed Skeleton Coast AI-map rebuild guard")
  return true
end

local function removePatch()
  local state = rawget(_G, patchStateKey)
  if not state then
    return
  end

  if map and map.assureLoad == state.wrapper then
    map.assureLoad = state.originalAssureLoad
  end
  rawset(_G, patchStateKey, nil)
end

local function onExtensionLoaded()
  installPatch()
end

local function onExtensionUnloaded()
  removePatch()
end

M.installPatch = installPatch
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
