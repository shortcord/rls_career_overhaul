return {
    onGetMaps = function()
        extensions.hook("returnCompatibleMap", {["Utah"] = "Utah"})
    end
}