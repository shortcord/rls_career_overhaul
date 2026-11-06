-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local speedUnit = 2.2369362920544

local function setAllLightsEnabled(group, value)
    for i = 0, group.obj:getCount(), 1 do
        local id = group.obj:idAt(i)
        local obj = scenetree.findObjectById(id)
        if obj and obj.obj:isSubClassOf('LightBase') then
            obj.obj:setLightEnabled( value )
        end
    end
end

local lastValue = nil



--mystuff

local startotrack = false
local startdragr = false
local startdragl = false
local startac = false
local in_race_time = 0
local in_drag_timer = 0
local in_drag_timel = 0
local in_ac_time = 0

local function displayMessage(message, duration)
    ui_message(message, duration)
end



--green light trigger
local function Greenlight(data)
    if data.event == "enter" then
        --displayMessage("go!", 10)
        scenetree.findObject('startlight1'):setHidden(false)
        scenetree.findObject('startlight2'):setHidden(false)
        scenetree.findObject('startlight3'):setHidden(false)
        scenetree.findObject('waitlight'):setHidden(false)
        startotrack = true
        displayMessage("Off Road Track: Timer Started, GO! " ,10)
    end
end


--yellow light trigger
local function Yellowlight1 (data)
  if data.event == "enter" then--turns on yellow light
    scenetree.findObject('readylight1'):setHidden(false)
    --scenetree.findObject('startlight'):setHidden(true)
    --displayMessage(" Staged, go when ready. " ,10)
   end
 -- if data.event == "enter" then--turns off green light
    
  -- end
  if data.event == "exit" then--turns off yellow light
    scenetree.findObject('readylight1'):setHidden(true)
    end
end

--yellow light trigger
local function Yellowlight2 (data)
    if data.event == "enter" then--turns on yellow light
      scenetree.findObject('readylight2'):setHidden(false)
      --scenetree.findObject('startlight'):setHidden(true)
      --displayMessage(" Staged, go when ready. " ,10)
     end
   -- if data.event == "enter" then--turns off green light
      
    -- end
    if data.event == "exit" then--turns off yellow light
      scenetree.findObject('readylight2'):setHidden(true)
      end
  end

  --yellow light trigger
local function Yellowlight3 (data)
    if data.event == "enter" then--turns on yellow light
      scenetree.findObject('readylight3'):setHidden(false)
      --scenetree.findObject('startlight'):setHidden(true)
      displayMessage(" Off Road Track: Staged, go when ready. " ,10)
     end
   -- if data.event == "enter" then--turns off green light
      
    -- end
    if data.event == "exit" then--turns off yellow light
      scenetree.findObject('readylight3'):setHidden(true)
      end
  end


  --reset stage
local function resetstage (data)
	if data.event == "enter" then
    scenetree.findObject('startlight1'):setHidden(true)
    scenetree.findObject('startlight2'):setHidden(true)
    scenetree.findObject('startlight3'):setHidden(true)
    scenetree.findObject('waitlight'):setHidden(true)
    scenetree.findObject('readylight1'):setHidden(true)
    scenetree.findObject('readylight2'):setHidden(true)
    scenetree.findObject('readylight3'):setHidden(true)
   startotrack = false
    end
 end

 --Finishline
  local function Finishline(data) 
    if data.event == "enter" then
        scenetree.findObject('startlight1'):setHidden(true)
        scenetree.findObject('startlight2'):setHidden(true)
        scenetree.findObject('startlight3'):setHidden(true)
        scenetree.findObject('waitlight'):setHidden(true)
        scenetree.findObject('readylight1'):setHidden(true)
        scenetree.findObject('readylight2'):setHidden(true)
        scenetree.findObject('readylight3'):setHidden(true)
   displayMessage("Off Road Track: Time: " .. string.format("%.2f", in_race_time),10)

    end
 end









 --autocross

--green light trigger
local function Greenlightac(data)
  if data.event == "enter" then
      --displayMessage("go!", 10)
      scenetree.findObject('startlight1ac'):setHidden(false)
      scenetree.findObject('startlight2ac'):setHidden(false)
      scenetree.findObject('startlight3ac'):setHidden(false)
      scenetree.findObject('waitlightac'):setHidden(false)
      startac = true
      displayMessage("Autocross: Timer Started, GO! " ,10)
  end
end


--yellow light trigger
local function Yellowlight1ac (data)
if data.event == "enter" then--turns on yellow light
  scenetree.findObject('readylight1ac'):setHidden(false)
  --scenetree.findObject('startlight'):setHidden(true)
  --displayMessage(" Staged, go when ready. " ,10)
 end
-- if data.event == "enter" then--turns off green light
  
-- end
if data.event == "exit" then--turns off yellow light
  scenetree.findObject('readylight1ac'):setHidden(true)
  end
end

--yellow light trigger
local function Yellowlight2ac (data)
  if data.event == "enter" then--turns on yellow light
    scenetree.findObject('readylight2ac'):setHidden(false)
    --scenetree.findObject('startlight'):setHidden(true)
    --displayMessage(" Staged, go when ready. " ,10)
   end
 -- if data.event == "enter" then--turns off green light
    
  -- end
  if data.event == "exit" then--turns off yellow light
    scenetree.findObject('readylight2ac'):setHidden(true)
    end
end

--yellow light trigger
local function Yellowlight3ac (data)
  if data.event == "enter" then--turns on yellow light
    scenetree.findObject('readylight3ac'):setHidden(false)
    --scenetree.findObject('startlight'):setHidden(true)
    displayMessage(" Off Road Track: Staged, go when ready. " ,10)
   end
 -- if data.event == "enter" then--turns off green light
    
  -- end
  if data.event == "exit" then--turns off yellow light
    scenetree.findObject('readylight3ac'):setHidden(true)
    end
end


--reset stage
local function resetstageac (data)
if data.event == "enter" then
  scenetree.findObject('startlight1ac'):setHidden(true)
  scenetree.findObject('startlight2ac'):setHidden(true)
  scenetree.findObject('startlight3ac'):setHidden(true)
  scenetree.findObject('waitlightac'):setHidden(true)
  scenetree.findObject('readylight1ac'):setHidden(true)
  scenetree.findObject('readylight2ac'):setHidden(true)
  scenetree.findObject('readylight3ac'):setHidden(true)
 startac = false
  end
end

--Finishline
local function Finishlineac(data) 
  if data.event == "enter" then
      scenetree.findObject('startlight1ac'):setHidden(true)
      scenetree.findObject('startlight2ac'):setHidden(true)
      scenetree.findObject('startlight3ac'):setHidden(true)
      scenetree.findObject('waitlightac'):setHidden(true)
      scenetree.findObject('readylight1ac'):setHidden(true)
      scenetree.findObject('readylight2ac'):setHidden(true)
      scenetree.findObject('readylight3ac'):setHidden(true)
 displayMessage("Autocross: Time: " .. string.format("%.2f", in_ac_time),10)

  end
end





--drag race r
local function dragrgreenlight(data)
    if data.event == "enter" then
        scenetree.findObject('dragrgo'):setHidden(false)       
        startdragr = true
        displayMessage(" Right Lane Drag Race Started, GO! " ,1)
    end
end

local function dragrstage1light (data)
  if data.event == "enter" then
    scenetree.findObject('dragrstage1'):setHidden(false)
    scenetree.findObject('dragrstage2'):setHidden(false)
    --displayMessage(" Pull Forward " ,5)
   end
   if data.event == "exit" then
    scenetree.findObject('dragrstage1'):setHidden(true)
    scenetree.findObject('dragrstage2'):setHidden(true)
    --displayMessage(" Pull Back " ,5)
   end
end

local function dragrstage2light (data)
    if data.event == "enter" then
      scenetree.findObject('dragrstage3'):setHidden(false)
      scenetree.findObject('dragrstage4'):setHidden(false)
      displayMessage(" Right Lane Staged, go when ready. " ,1)
     end
     if data.event == "exit" then
        scenetree.findObject('dragrstage3'):setHidden(true)
        scenetree.findObject('dragrstage4'):setHidden(true)
        --displayMessage(" Pull Back " ,5)
       end
  end


local function dragresetrstage (data)
	if data.event == "enter" then
    scenetree.findObject('dragrgo'):setHidden(true)
    scenetree.findObject('dragrstop'):setHidden(true)
    scenetree.findObject('dragrstage3'):setHidden(true)
    scenetree.findObject('dragrstage4'):setHidden(true)
    scenetree.findObject('dragrstage1'):setHidden(true)
    scenetree.findObject('dragrstage2'):setHidden(true)
    startdragr = false
    end
 end


  local function quarterdragrfinishline(data) 
    if data.event == "enter" then
    scenetree.findObject('dragrgo'):setHidden(true)
    scenetree.findObject('dragrstop'):setHidden(true)
    displayMessage(" Right Lane 1/4 Mile Time: " .. string.format("%.2f", in_drag_timer),10)
    print(in_drag_timer)
    end
 end

 local function eightdragrfinishline(data) 
    if data.event == "enter" then
    scenetree.findObject('dragrstage3'):setHidden(true)
    scenetree.findObject('dragrstage4'):setHidden(true)
    scenetree.findObject('dragrstage1'):setHidden(true)
    scenetree.findObject('dragrstage2'):setHidden(true)
    displayMessage(" Right Lane 1/8 Mile Time: " .. string.format("%.2f", in_drag_timer),1)
    print(in_drag_timer)
    end
 end

 local function sixdragrfinishline(data) 
    if data.event == "enter" then
    scenetree.findObject('dragrstop'):setHidden(false)
    displayMessage(" Right Lane 60 Foot Time: " .. string.format("%.2f", in_drag_timer),1)
    print(in_drag_timer)
    end
 end






 --drag race l
local function draglgreenlight(data)
    if data.event == "enter" then
        scenetree.findObject('draglgo'):setHidden(false)       
        startdragl = true
        displayMessage(" Left Lane Drag Race Started, GO! " ,1)
    end
end

local function draglstage1light (data)
  if data.event == "enter" then
    scenetree.findObject('draglstage1'):setHidden(false)
    scenetree.findObject('draglstage2'):setHidden(false)
    --displayMessage(" Pull Forward " ,5)
   end
   if data.event == "exit" then
    scenetree.findObject('draglstage1'):setHidden(true)
    scenetree.findObject('draglstage2'):setHidden(true)
    --displayMessage(" Pull Back " ,5)
   end
end

local function draglstage2light (data)
    if data.event == "enter" then
      scenetree.findObject('draglstage3'):setHidden(false)
      scenetree.findObject('draglstage4'):setHidden(false)
      displayMessage(" Left Lane Staged, go when ready. " ,1)
     end
     if data.event == "exit" then
        scenetree.findObject('draglstage3'):setHidden(true)
        scenetree.findObject('draglstage4'):setHidden(true)
        --displayMessage(" Pull Back " ,5)
       end
  end


local function dragresetlstage (data)
	if data.event == "enter" then
    scenetree.findObject('draglgo'):setHidden(true)
    scenetree.findObject('draglstop'):setHidden(true)
    scenetree.findObject('draglstage3'):setHidden(true)
    scenetree.findObject('draglstage4'):setHidden(true)
    scenetree.findObject('draglstage1'):setHidden(true)
    scenetree.findObject('draglstage2'):setHidden(true)
    startdragl = false
    end
 end


  local function quarterdraglfinishline(data) 
    if data.event == "enter" then
    scenetree.findObject('draglgo'):setHidden(true)
    scenetree.findObject('draglstop'):setHidden(true)
    displayMessage(" Left Lane 1/4 Mile Time: " .. string.format("%.2f", in_drag_timel),10)
    print(in_drag_timel)
    end
 end

 local function eightdraglfinishline(data) 
    if data.event == "enter" then
    scenetree.findObject('draglstage3'):setHidden(true)
    scenetree.findObject('draglstage4'):setHidden(true)
    scenetree.findObject('draglstage1'):setHidden(true)
    scenetree.findObject('draglstage2'):setHidden(true)
    displayMessage(" Left Lane 1/8 Mile Time: " .. string.format("%.2f", in_drag_timel),1)
    print(in_drag_timel)
    end
 end

 local function sixdraglfinishline(data) 
    if data.event == "enter" then
    scenetree.findObject('draglstop'):setHidden(false)
    displayMessage(" Left Lane 60 Foot Time: " .. string.format("%.2f", in_drag_timel),1)
    print(in_drag_timel)
    end
 end








 local function onUpdate(dtReal, dtSim, dtRaw)
    -- Light settings update
    local tod = scenetree.tod
    if tod then
        local value = false
        if tod.time > 0.21 and tod.time < 0.77 then
            value = true
        end

        if lastValue ~= value then
            lastValue = value
            if scenetree.night_light then
                setAllLightsEnabled(scenetree.night_light, value)
            end
        end
    end

    -- Race time calculation
    if startotrack == true then
        in_race_time = in_race_time + dtSim
    else
        in_race_time = 0
    end
    if startdragr == true then
        in_drag_timer = in_drag_timer + dtSim
    else
        in_drag_timer = 0
    end
    if startdragl == true then
        in_drag_timel = in_drag_timel + dtSim
    else
        in_drag_timel = 0
    end
    if startac == true then
      in_ac_time = in_ac_time + dtSim
  else
    in_ac_time = 0
  end
end

--Salt Flats
local function printTable(t, indent)
    indent = indent or 0
    local indentStr = string.rep("  ", indent)
  
    for key, value in pairs(t) do
      if type(value) == "table" then
        print(indentStr .. tostring(key) .. ":")
        printTable(value, indent + 1)
      else
        print(indentStr .. tostring(key) .. ": " .. tostring(value))
      end
    end
  end

local function onSpeedTrapTriggered(data)

    local veh = getPlayerVehicle(0)
    if data.event == "enter" then
        print("gl")
        local speed = math.abs(be:getObjectVelocityXYZ(data.subjectID)) * speedUnit
        
        print(speed)
        printTable(data)
        displayMessage(data["triggerName"] .. " Speed: " .. string.format("%.1f", speed) .." mph",5)

    end
end




M.onSpeedTrapTriggered = onSpeedTrapTriggered
M.displayMessage = displayMessage
M.Finishline = Finishline
M.resetstage = resetstage
M.Greenlight = Greenlight
M.Yellowlight1 = Yellowlight1
M.Yellowlight2 = Yellowlight2
M.Yellowlight3 = Yellowlight3
M.onUpdate = onUpdate

M.dragrgreenlight = dragrgreenlight
M.dragrstage1light = dragrstage1light
M.dragrstage2light = dragrstage2light
M.dragresetrstage = dragresetrstage
M.quarterdragrfinishline = quarterdragrfinishline
M.eightdragrfinishline = eightdragrfinishline
M.sixdragrfinishline = sixdragrfinishline

M.draglgreenlight = draglgreenlight
M.draglstage1light = draglstage1light
M.draglstage2light = draglstage2light
M.dragresetlstage = dragresetlstage
M.quarterdraglfinishline = quarterdraglfinishline
M.eightdraglfinishline = eightdraglfinishline
M.sixdraglfinishline = sixdraglfinishline

M.Finishlineac = Finishlineac
M.resetstageac = resetstageac
M.Greenlightac = Greenlightac
M.Yellowlight1ac = Yellowlight1ac
M.Yellowlight2ac = Yellowlight2ac
M.Yellowlight3ac = Yellowlight3ac


return M