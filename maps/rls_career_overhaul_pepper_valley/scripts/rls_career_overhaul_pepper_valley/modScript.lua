local extensionName = "Peppervalley_careerMap"

if extensions.isExtensionLoaded(extensionName) then
    extensions.unload(extensionName)
end

extensions.load(extensionName)
setExtensionUnloadMode(extensionName, "manual")
