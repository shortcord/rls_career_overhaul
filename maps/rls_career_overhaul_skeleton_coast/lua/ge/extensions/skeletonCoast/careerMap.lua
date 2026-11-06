local M = {}

local managedExtensions = {
    {
        name = "skeletonCoast_mapCompatibility",
        always = true,
        loaded = false
    },
    {
        name = "landmarks_core",
        always = true,
        loaded = false
    },
    {
        name = "skeletonCoast_dakar",
        loaded = false
    },
    {
        name = "skeletonCoast_roadAuthority",
        loaded = false
    }
}

local function isSkeletonCoastCareer()
    return getCurrentLevelIdentifier()
        and getCurrentLevelIdentifier() == "skeleton_coast"
        and career_career
        and career_career.isActive
        and career_career.isActive()
end

local function updateManagedLoaders()
    local careerShouldLoad = isSkeletonCoastCareer()
    for _, entry in ipairs(managedExtensions) do
        local shouldLoad = entry.always or careerShouldLoad
        entry.loaded = extensions.isExtensionLoaded(entry.name)
        if shouldLoad and not entry.loaded then
            extensions.load(entry.name)
            setExtensionUnloadMode(entry.name, "manual")
            entry.loaded = true
        elseif not shouldLoad and entry.loaded then
            extensions.unload(entry.name)
            entry.loaded = false
        end
    end
end

function M.onExtensionLoaded()
    updateManagedLoaders()
end

function M.onGetMaps()
    extensions.hook("returnCompatibleMap", {
        ["skeleton_coast"] = "Skeleton Coast"
    })
end

function M.onCareerActivated()
    updateManagedLoaders()
end

function M.onClientStartMission()
    updateManagedLoaders()
end

function M.onUpdate()
    updateManagedLoaders()
end

return M
