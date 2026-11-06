local M = {}

-- Timed Lights
local oldLightsValue = nil
local ddt = 0

-- Eigene Timer pro Soundblock
local timerTurtledove = 0
local timerKestrel = 0
local timerVulture = 0
local timerHyena = 0
local timerLion = 0
local timerBarking = 0
local timerJackal = 0
local timerSeagulls = 0
local timerEagle = 0
local timercricketnight = 0
local timerflex = 0
local timercaralarm = 0
local timercarpassing = 0
local timerbikepassing = 0
local timerhammer = 0
local timermine_pipes1 = 0
local timermine_pipes2 = 0
local timermine_pipes4 = 0
local timerhyena_growl = 0

-- Funktion zum Schalten von Lichtgruppen
local function setLights(group, value)
    for i = 0, group.obj:getCount(), 1 do
        local id = group.obj:idAt(i)
        local obj = scenetree.findObjectById(id)
        if obj and obj.obj:isSubClassOf('LightBase') then
            obj.obj:setLightEnabled(value)
        end
    end
end

local function onUpdate(dt)
    ddt = ddt + dt
    local tod = scenetree.tod
    if not tod then return end

    -- Kaptaube (alle 10 Sekunden tags)
    timerTurtledove = timerTurtledove + dt
    if timerTurtledove >= 10 then
        timerTurtledove = 0
        if tod.time >= 0.760 or tod.time < 0.245 then
            for i = 1, 16 do
                local sfx = scenetree.findObject('SFX_birdcall_turtledove' .. i)
                if sfx then sfx:play() end
            end
        end
    end

    -- Flex (alle 240 Sekunden tags)
    timerflex = timerflex + dt
    if timerflex >= 240 then
        timerflex = 0
        if tod.time >= 0.800 or tod.time < 0.185 then
            for i = 1, 4 do
                local sfx = scenetree.findObject('SFX_flex' .. i)
                if sfx then sfx:play() end
            end
        end
    end
	
    -- Bellen (alle 120 Sekunden tags)
    timerflex = timerflex + dt
    if timerflex >= 120 then
        timerflex = 0
        if tod.time >= 0.800 or tod.time < 0.185 then
            for i = 1, 6 do
                local sfx = scenetree.findObject('SFX_barking' .. i)
                if sfx then sfx:play() end
            end
        end
    end
	
    -- Hammer (alle 300 Sekunden tags)
    timerhammer = timerhammer + dt
    if timerhammer >= 300 then
        timerhammer = 0
        if tod.time >= 0.800 or tod.time < 0.185 then
            for i = 1, 9 do
                local sfx = scenetree.findObject('SFX_hammer' .. i)
                if sfx then sfx:play() end
            end
        end
    end
	
    -- Grillen (alle 30 Sekunden tags)
    timercricketnight = timercricketnight + dt
    if timercricketnight >= 30 then
        timercricketnight = 0
        if tod.time >= 0.260 or tod.time < 0.765 then
            for i = 1, 7 do
                local sfx = scenetree.findObject('SFX_crickets_night' .. i)
                if sfx then sfx:play() end
            end
        end
    end

    -- Falke (alle 180 Sek. tags)
    timerKestrel = timerKestrel + dt
    if timerKestrel >= 180 then
        timerKestrel = 0
        if tod.time >= 0.780 or tod.time < 0.235 then
            for i = 1, 10 do
                local sfx = scenetree.findObject('SFX_birdcall_kestrel' .. i)
                if sfx then sfx:play() end
            end
        end
    end

    -- Geier (alle 210 Sek. tags)
    timerVulture = timerVulture + dt
    if timerVulture >= 210 then
        timerVulture = 0
        if tod.time >= 0.780 or tod.time < 0.230 then
            for i = 1, 6 do
                local sfx = scenetree.findObject('SFX_birdcall_vulture' .. i)
                if sfx then sfx:play() end
            end
        end
    end

    -- Hyaene (alle 360 Sek. bei Dämmerung)
    timerHyena = timerHyena + dt
    if timerHyena >= 360 then
        timerHyena = 0
        if tod.time >= 0.260 and tod.time < 0.745 then
            local sfx1 = scenetree.findObject('SFX_hyena_nightcall')
            if sfx1 then sfx1:play() end
            local sfx2 = scenetree.findObject('SFX_hyena_nightcall2')
            if sfx2 then sfx2:play() end
        end
    end
	
    -- caralarm (alle 480 Sek)
    timercaralarm = timercaralarm + dt
    if timercaralarm >= 480 then
        timercaralarm = 0
        local sfx1 = scenetree.findObject('SFX_caralarm')
        if sfx1 then sfx1:play() end
    end
	
    -- carpassing (alle 262 Sek)
    timercarpassing = timercarpassing + dt
    if timercarpassing >= 262 then
        timercarpassing = 0
        local sfx1 = scenetree.findObject('SFX_carpassing1')
        if sfx1 then sfx1:play() end
    end

    -- bikepassing (alle 315 Sek)
    timerbikepassing = timerbikepassing + dt
    if timerbikepassing >= 315 then
        timerbikepassing = 0
        local sfx1 = scenetree.findObject('SFX_bikepassing1')
        if sfx1 then sfx1:play() end
    end
	
	-- mine_pipes1 (alle 180 Sek.)
	timermine_pipes1 = timermine_pipes1 + dt
	if timermine_pipes1 >= 180 then
		timermine_pipes1 = 0
		local sfx = scenetree.findObject('SFX_mine_pipes1')
		if sfx then sfx:play() end
	end
	
	-- mine_pipes2 (alle 150 Sek.)
	timermine_pipes2 = timermine_pipes2 + dt
	if timermine_pipes2 >= 150 then
		timermine_pipes2 = 0
		local sfx = scenetree.findObject('SFX_mine_pipes2')
		if sfx then sfx:play() end
	end
	
	-- mine_pipes4 (alle 130 Sek.)
	timermine_pipes4 = timermine_pipes4 + dt
	if timermine_pipes4 >= 130 then
		timermine_pipes4 = 0
		local sfx = scenetree.findObject('SFX_mine_pipes4')
		if sfx then sfx:play() end
	end
	
	-- hyena_growl (alle 240 Sek.)
	timerhyena_growl = timerhyena_growl + dt
	if timerhyena_growl >= 240 then
		timerhyena_growl = 0
		local sfx = scenetree.findObject('SFX_hyena_growl')
		if sfx then sfx:play() end
	end
	
    -- Loewe (alle 360 Sek.)
    timerLion = timerLion + dt
    if timerLion >= 360 then
        timerLion = 0
        for i = 1, 3 do
            local sfx = scenetree.findObject('SFX_lion_call' .. i)
            if sfx then sfx:play() end
        end
    end

    -- Schakal (alle 360 Sek.)
    timerJackal = timerJackal + dt
    if timerJackal >= 360 then
        timerJackal = 0
        for i = 1, 11 do
            local sfx = scenetree.findObject('SFX_jackal_call' .. i)
            if sfx then sfx:play() end
        end
    end

    -- Moewen (alle 130 Sek. tags)
    timerSeagulls = timerSeagulls + dt
    if timerSeagulls >= 130 then
        timerSeagulls = 0
        if tod.time >= 0.780 or tod.time < 0.235 then
            for i = 1, 4 do
                local sfx = scenetree.findObject('SFX_birdcall_seagulls' .. i)
                if sfx then sfx:play() end
            end
        end
    end

    -- Adler (alle 180 Sek. tags)
    timerEagle = timerEagle + dt
    if timerEagle >= 180 then
        timerEagle = 0
        if tod.time >= 0.780 or tod.time < 0.235 then
			for i = 1, 6 do
				local sfx = scenetree.findObject('SFX_birdcall_eagle' .. i)
				if sfx then sfx:play() end
			end
        end
    end

    -- Lichter schalten nach Tageszeit
    local lightsValue = false
    if tod.time > 0.24 and tod.time < 0.77 then
        lightsValue = true
    end

    if oldLightsValue == lightsValue then
        return
    end

    if scenetree.dynamic_lights then
        setLights(scenetree.dynamic_lights, lightsValue)
    end
    oldLightsValue = lightsValue
end

M.onUpdate = onUpdate

return M
