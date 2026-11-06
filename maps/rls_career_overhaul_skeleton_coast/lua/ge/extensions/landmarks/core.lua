-- by @MegaKnight -- DO NOT RE-USE CODE WITHOUT PERMISSION --
--   adds landmarks/pois/lore spots to Skeleton Coast    --

local M = {}

local landmarks = {}			-- table of landmarks, NOT the one used by bigmap lua
local markSelectedOnMap = nil	-- landmark selected in bigmap mode, id/name
local enabled = false   		-- gui will display upon entering radius of curMark
local curMark = nil	    		-- id/name
local guiActive = false 		-- when inside landmark radius
local im = ui_imgui				-- for gui
local guiColors = nil			-- for gui


local function playSound()
	Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>Click_Small_02', {position = playerPos})
end

local function disableMark()
	if guiActive then playSound() end
	guiActive = false
	enabled = false
	guiColors = nil
end

-- pre-calculate and store colors for better performance
local function calcColors()
	local data = landmarks[curMark].uiData
	guiColors = {}
	guiColors.bg = im.ImVec4(data.bgColor[1], data.bgColor[2], data.bgColor[3], data.bgColor[4])
	guiColors.txt = im.ImVec4(data.textColor[1], data.textColor[2],data.textColor[3], data.textColor[4])
	if not data.closeButton then return end
	guiColors.btn = im.ImVec4(data.buttonCol[1], data.buttonCol[2], data.buttonCol[3], data.buttonCol[4])
	guiColors.btnHov = im.ImVec4(data.buttonHoverCol[1], data.buttonHoverCol[2], data.buttonHoverCol[3], data.buttonHoverCol[4])
	guiColors.btnAct = im.ImVec4(data.buttonActiveCol[1], data.buttonActiveCol[2], data.buttonActiveCol[3], data.buttonActiveCol[4])
end

local function renderGui()
	local data = landmarks[curMark].uiData
	-- style
	im.PushStyleColor2(im.Col_WindowBg, guiColors.bg)
	im.PushStyleColor2(im.Col_Text, guiColors.txt)
	if data.roundedEdges then im.PushStyleVar1(im.StyleVar_WindowRounding, 0) end
	if data.closeButton then
		im.PushStyleColor2(im.Col_Button, guiColors.btn)
		im.PushStyleColor2(im.Col_ButtonHovered, guiColors.btnHov)
		im.PushStyleColor2(im.Col_ButtonActive, guiColors.btnAct)
	end
	
	im.Begin(data.title, nil, im.WindowFlags_AlwaysAutoResize)
	local llore = data.lore
	for i = 1, #llore do
		im.Text(llore[i])
	end
	if data.closeButton then
		im.Separator()
		if im.Button(data.buttonText) then
			log("I", "", "button clicked, gui and landmark disabled")
			disableMark()
		end
	end
	im.End()
	
	im.PopStyleVar()
end


local function addPoisToBigmap(levelIdentifier, elements) 
	if levelIdentifier == "skeleton_coast" then
		local temp = jsonReadFile("/lua/ge/extensions/landmarks/pois.json")
		if not temp then return end
		for i = 1, #temp do
			local l = temp[i]
			l.markerInfo.bigmapMarker.pos = vec3(l.markerInfo.bigmapMarker.pos.x, l.markerInfo.bigmapMarker.pos.y, l.markerInfo.bigmapMarker.pos.z)
			table.insert(elements, l)
			landmarks[l.id] = {}
			landmarks[l.id].pos = l.markerInfo.bigmapMarker.pos
			landmarks[l.id].radius = l.popUpRadius
			landmarks[l.id].uiData = {}
			landmarks[l.id].uiData = l.uiData
		end
	end
	--dump(landmarks)
end


local function onGetRawPoiListForLevel(levelIdentifier, elements)
	addPoisToBigmap(levelIdentifier, elements)
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel


local function onSetBigmapNavFocus(pos)
	if not landmarks then return end
	--print(pos)
	if markSelectedOnMap then
		guiActive = false
		enabled = true
		curMark = markSelectedOnMap
		log("I", "", "activated landmark " .. curMark)
	elseif enabled and (not guiActive) then
		disableMark()
		log("I", "", "navigation changed, disabled landmark")
	end
end
M.onSetBigmapNavFocus = onSetBigmapNavFocus


local function onPoiSelectedFromBigmap(idInCluster)
	if not landmarks then return end
	--if enabled or guiActive then return end
	--dump(idInCluster)
	--print(freeroam_bigMapMode.selectedPoiId)
	if landmarks[idInCluster] then
		markSelectedOnMap = idInCluster
		log("I", "", "selected landmark with id " .. idInCluster)
	else
		markSelectedOnMap = nil
	end
end
M.onPoiSelectedFromBigmap = onPoiSelectedFromBigmap


local function onUpdate(dtReal, dtSim)
	if not landmarks then enabled = false return end
	if (not guiActive) and enabled and (core_groundMarkers.getTargetPos() and core_groundMarkers.getTargetPos() ~= landmarks[curMark].pos) then 
		log("I", "", "navigation changed, disabled landmark")
		disableMark()
		return 
	end
	
	if enabled then
		local playerPos = getPlayerVehicle(0):getPosition()
		local markPos = landmarks[curMark].pos
		local distX = markPos.x - playerPos.x
		local distY = markPos.y - playerPos.y
		local distZ = markPos.z - playerPos.z
		local dist = math.sqrt((distX * distX) + (distY * distY) + (distZ * distZ))
	
		-- if inside landmark radius, choose big enough so navigation isnt cancelled before entering
		if guiActive then
			renderGui()
			if dist > landmarks[curMark].radius then
				disableMark()
				log("I", "", "landmark " .. curMark .. " left, disabled gui and landmark")
			end
		else
			if dist <= landmarks[curMark].radius then
				log("I", "", "landmark " .. curMark .. " reached, enabled gui")
				playSound()
				calcColors()
				guiActive = true
				--guihooks.trigger('toastrMsg', {type = "success", title = landmarks[curMark].uiData.title , msg = "hello :)", config = {timeOut = 10000}}) 
			end
		end
	end
end
M.onUpdate = onUpdate


return M