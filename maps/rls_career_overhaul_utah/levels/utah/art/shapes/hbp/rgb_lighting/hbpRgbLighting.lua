-- Punisher Lighting Systems. Loaded by Utah's mainLevel.lua.
-- Assets remain in rgb_lighting; per-level preferences live in /settings/plsLighting/.
local M = {}
local root = '/levels/utah/art/shapes/hbp/rgb_lighting/'
-- User preferences live outside level/mod packages. Assets still use root.
local settingsDirectory='/settings/plsLighting/levels/'
local settingsReadError=nil
local function settingsPath()
  local mission=(getMissionFilename() or ''):gsub('\\','/')
  local level=mission:match('^/?levels/([^/]+)/')
  if not level or level=='.' or level=='..' then return nil end
  -- Encode unusual bytes instead of replacing them, avoiding filename collisions.
  level=level:lower():gsub('[^%w_-]',function(c)return string.format('%%%02X',string.byte(c))end)
  return settingsDirectory..level..'.json'
end
local function legacySettingsPath()
  local source=(FS:getFileRealPath(root..'hbpRgbLighting.lua') or ''):gsub('\\','/')
  local user=(FS:getUserPath() or ''):gsub('\\','/'):gsub('/+$','')..'/'
  if source:sub(1,#user):lower()~=user:lower() then return root..'hbp_rgb_zone.settings' end
  local relative=source:sub(#user+1)
  if not relative:lower():match('^mods/unpacked/') then return root..'hbp_rgb_zone.settings' end
  return '/'..relative:gsub('hbpRgbLighting%.lua$','hbp_rgb_zone.settings')
end
local function readSettingsFile(path)
  local ok,data=pcall(jsonReadFile,path)
  return ok and type(data)=='table' and data or nil
end
local function sameSettings(a,b)
  if type(a)~=type(b) then return false end
  if type(a)=='number' then return math.abs(a-b)<=1e-10*math.max(1,math.abs(a),math.abs(b)) end
  if type(a)~='table' then return a==b end
  for k,v in pairs(a) do if not sameSettings(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function writeSettings(path,data)
  local ok,result=pcall(function()
    if FS:directoryCreate(settingsDirectory,true)==false then return false end
    return jsonWriteFile(path,data,true)
  end)
  if not ok or result==false then return false,'Unable to save lighting settings: '..tostring(result) end
  if not sameSettings(data,readSettingsFile(path)) then return false,'Lighting settings could not be verified after saving' end
  return true
end
local function loadSettings(validateFields)
  settingsReadError=nil
  local path=settingsPath()
  if not path then return nil end
  if FS:fileExists(path) then
    local data=readSettingsFile(path)
    if data and validateFields(data.fields) then return data end
    settingsReadError='Cannot read lighting settings at '..path..'; existing file was left untouched.'
    log('E','PunisherLighting',settingsReadError)
    return nil
  end
  -- This controller's legacy save belongs to Utah only. Do not import it into
  -- another level when the lighting system is expanded in future.
  if path~=settingsDirectory..'utah.json' then return nil end
  local legacy=legacySettingsPath()
  if not FS:fileExists(legacy) then legacy=root..'hbp_rgb_zone.settings' end
  local data=FS:fileExists(legacy) and readSettingsFile(legacy) or nil
  if data and validateFields(data.fields) then
    local ok,err=writeSettings(path,data)
    if not ok then log('E','PunisherLighting','Legacy settings loaded; migration will need retry: '..tostring(err)) end
    -- Preserve the legacy file as a read-only fallback for older installs.
    return data
  end
  if FS:fileExists(legacy) then log('E','PunisherLighting','Invalid legacy lighting settings; migration skipped') end
  return nil
end

local materialName = 'hbp_rgb_star_diffuser'
local activeGroup='downstairs'
local groupNames={'downstairs','upstairs'}
local groupLabels={downstairs='Downstairs',upstairs='Upstairs'}
local groupStates,groupOriginal,groupApplied={},{},{}
local upstairsFixtures={}
local shapeBindings={}
local presets={}

local function copy(t)
  if type(t)~='table' then return t end
  local r={} for k,v in pairs(t) do r[k]=copy(v) end return r
end
local mode, original, applied = 'white', nil, nil
local panel, inside, dismissed, pollTime = false, false, false, 0
local zoneName='hbpRgbSwitchTrigger'
local extraZones={}
local brightness=3
local speed=1 -- multiplier; 1x is one rainbow cycle per 25 seconds
local restoring=false
local pattern='sweep'
local customColor={0,1,124/255}
local patterns={{'sweep','Sweep'},{'reverse','Reverse'},{'circular','Circular'},{'outward','Outward'},{'inward','Inward'},{'cycle','Color Cycle'}}
local function validPattern(value)
  for _,item in ipairs(patterns) do if item[1]==value then return true end end
  return false
end
local owned = {}

local fields = {'version','diffuseMap','diffuseColor','emissive','glow','animFlags',
  'scrollDir','scrollSpeed','rotSpeed','rotPivotOffset','sequenceFramePerSec','sequenceSegmentSize','baseColorFactor','emissiveFactor','emissiveIntensityNits',
  'emissiveMap','castShadows','glowFactor','baseColorMap','metallicFactor','roughnessFactor'}

local function material()
  return scenetree.findObject(materialName)
end
local function capture(mat)
  local t = {}
  for _,f in ipairs(fields) do t[f] = mat:getField(f,0) end
  return t
end
local function apply(mat, values)
  local changed=false
  for f,v in pairs(values) do
    local text=tostring(v)
    if mat:getField(f,0)~=text then mat:setField(f,0,text); changed=true end
  end
  -- Match Beam's material editor: reload locally without flushing material resources.
  if changed then mat:reload() end
end

-- Explicit scene-object membership: placement and scale remain owned by the map.
local fixtureSets={}
local fixtureStyles={downstairs='diamonds',upstairs='diamonds'}
local fixtureVisibility={}
local styleLabels={diamonds='Six Diamonds',triangles='Triangle Cluster',cairo='Cairo Grid',honeycomb='Honeycomb Grid',hextrails='Hex Trails',rhombus='Rhombus Grid',petal='Petal Cluster',arrowline='Arrowline'}
local styleShapes={diamonds='hbp_rgb_six_diamond_star',triangles='hbp_rgb_triangle_cluster',cairo='hbp_rgb_cairo_grid',honeycomb='hbp_rgb_honeycomb_grid',hextrails='hbp_rgb_hex_trails',rhombus='hbp_rgb_rhombus_grid',petal='hbp_rgb_petal_cluster',arrowline='hbp_rgb_arrowline'}
local function findFixture(entry)
  if type(entry)=='string' then return scenetree.findObject(entry) end
  if type(entry)~='table' or type(entry.position)~='table' or #entry.position~=3 then return nil end
  local match=nil
  for _,id in ipairs(scenetree.findClassObjects('TSStatic')) do
    local obj=scenetree.findObject(id)
    if obj and obj:getField('shapeName',0)==entry.shape then
      local p=obj:getPosition()
      local d=(p.x-entry.position[1])^2+(p.y-entry.position[2])^2+(p.z-entry.position[3])^2
      if d<.0001 then
        if match then return nil end -- Ambiguous placements must not hide arbitrary objects.
        match=obj
      end
    end
  end
  return match
end
local function fixtureObjects(group,style)
  local names=fixtureSets[group] and fixtureSets[group][style]
  if type(names)~='table' or #names==0 then return nil end
  local result={}
  for _,entry in ipairs(names) do
    local obj=findFixture(entry)
    if not obj or obj:getClassName()~='TSStatic' then return nil end
    local shape=obj:getField('shapeName',0)
    local base=styleShapes[style]
    if not base then return nil end
    if shape~=root..base..'.dae' and shape~=root..base..'_upstairs.dae' then return nil end
    result[#result+1]={name=obj:getId(),obj=obj}
  end
  return result
end
local function applyFixtureStyle(group,style)
  if not groupLabels[group] or not styleLabels[style] or not fixtureObjects(group,style) then
    return false,'This style is not placed on this floor yet.'
  end
  -- Resolve every registered object before changing visibility: no partial swap.
  local sets={}
  for key in pairs(fixtureSets[group]) do
    if styleLabels[key] then
      sets[key]=fixtureObjects(group,key)
      if not sets[key] then return false,'A registered fixture is missing. Check its map placement.' end
    end
  end
  for key,objects in pairs(sets) do
    for _,entry in ipairs(objects) do
      if not fixtureVisibility[entry.name] then fixtureVisibility[entry.name]={hidden=entry.obj:isHidden()} end
      entry.obj:setHidden(key~=style)
    end
  end
  fixtureStyles[group]=style
  return true
end
local function loadFixtureStyles(data)
  local config=jsonReadFile(root..'hbp_rgb_fixture_styles.json')
  fixtureSets=type(config)=='table' and type(config.groups)=='table' and config.groups or {}
  for _,group in ipairs(groupNames) do
    local requested=data and type(data.fixtureStyles)=='table' and data.fixtureStyles[group] or 'diamonds'
    if not styleLabels[requested] then requested='diamonds' end
    if fixtureSets[group] then
      local ok,err=applyFixtureStyle(group,requested)
      if not ok then log('W','PunisherLighting',err) end
    end
  end
end
local function fixtureStyleStatus()
  local result={}
  for _,group in ipairs(groupNames) do
    result[group]={selected=fixtureStyles[group],options={}}
    for _,key in ipairs({'diamonds','triangles','cairo','honeycomb','hextrails','rhombus','petal','arrowline'}) do
      result[group].options[#result[group].options+1]={id=key,label=styleLabels[key],available=fixtureObjects(group,key)~=nil}
    end
  end
  return result
end
local function restoreFixtureVisibility()
  for name,state in pairs(fixtureVisibility) do
    local obj=scenetree.findObject(name)
    if obj then obj:setHidden(state.hidden) end
  end
  fixtureVisibility={}
end
function M.selectFixtureStyle(group,style)
  local previous=fixtureStyles[group]
  local ok,err=applyFixtureStyle(group,style)
  if not ok then return false,err end
  ok,err=M.saveZone()
  if not ok then applyFixtureStyle(group,previous) end
  return ok,err
end

local function fixtureNits(value) return value*10*24 end
local function currentState()
  return {mode=mode,pattern=pattern,color=copy(customColor),brightness=brightness,speed=speed}
end
local function validState(t)
  if type(t)~='table' then return false end
  if t.mode~='white' and t.mode~='rainbow' and t.mode~='custom' and t.mode~='off' then return false end
  if not validPattern(t.pattern) then return false end
  if type(t.brightness)~='number' or t.brightness~=t.brightness or t.brightness<.0001 or t.brightness>10 then return false end
  if type(t.speed)~='number' or t.speed~=t.speed or t.speed<.125 or t.speed>8 then return false end
  if type(t.color)~='table' then return false end
  for i=1,3 do local v=t.color[i]; if type(v)~='number' or v~=v or v<0 or v>1 then return false end end
  return true
end
local function storeGroup()
  groupStates[activeGroup]=currentState()
  groupOriginal[activeGroup]=original; groupApplied[activeGroup]=applied
end
function M.selectGroup(value)
  if not groupLabels[value] then return false,'Unknown lighting group' end
  if value==activeGroup then return true end
  storeGroup()
  local state=groupStates[value] or currentState()
  activeGroup=value
  materialName=value=='upstairs' and 'hbp_rgb_star_diffuser_upstairs' or 'hbp_rgb_star_diffuser'
  mode=state.mode; pattern=state.pattern; customColor=copy(state.color); brightness=state.brightness; speed=math.max(.5,math.min(8,math.floor(state.speed*2+.5)/2))
  original=groupOriginal[value]; applied=groupApplied[value]
  return true
end
local function setupFixtures()
  local target=root..'hbp_rgb_six_diamond_star_upstairs.dae'
  for _,name in ipairs(upstairsFixtures) do
    local obj=scenetree.findObject(name)
    if obj and obj:getClassName()=='TSStatic' then
      local old=obj:getField('shapeName',0)
      if old==root..'hbp_rgb_six_diamond_star.dae' or old==target then
        if not shapeBindings[name] then shapeBindings[name]=old end
        if old~=target then obj:setField('shapeName',0,target); obj:postApply() end
      end
    end
  end
end
function M.assignUpstairs(names)
  if type(names)~='table' then return false,'Expected fixture names' end
  local unique={}; local result={}
  for _,name in ipairs(names) do
    local obj=type(name)=='string' and scenetree.findObject(name)
    if not obj or obj:getClassName()~='TSStatic' then return false,'Unknown fixture' end
    local path=obj:getField('shapeName',0)
    if path~=root..'hbp_rgb_six_diamond_star.dae' and path~=root..'hbp_rgb_six_diamond_star_upstairs.dae' then return false,'Not a PLS star fixture' end
    if not unique[name] then unique[name]=true; result[#result+1]=name end
  end
  for name,old in pairs(shapeBindings) do
    if not unique[name] then
      local obj=scenetree.findObject(name)
      if obj and obj:getField('shapeName',0)==root..'hbp_rgb_six_diamond_star_upstairs.dae' then obj:setField('shapeName',0,old); obj:postApply() end
      shapeBindings[name]=nil
    end
  end
  upstairsFixtures=result; setupFixtures()
  return M.saveZone()
end
function M.savePreset(name)
  if type(name)~='string' then return false,'Enter a preset name' end
  name=name:match('^%s*(.-)%s*$')
  if name=='' then return false,'Enter a preset name first.' end
  if #name>32 or name:find('[%c]') then return false,'Use 1-32 characters, without control characters' end
  local count=0 for _ in pairs(presets) do count=count+1 end
  if not presets[name] and count>=16 then return false,'Up to 16 presets can be saved' end
  presets[name]=currentState()
  return M.saveZone()
end
function M.loadPreset(name)
  local state=presets[name]
  if not validState(state) then return false,'Preset not found or invalid' end
  customColor=copy(state.color); brightness=state.brightness; speed=math.max(.5,math.min(8,math.floor(state.speed*2+.5)/2)); pattern=state.pattern
  return M.setMode(state.mode)
end
function M.deletePreset(name)
  if not presets[name] then return false,'Preset not found' end
  local previous=presets[name]
  presets[name]=nil
  local ok,err=M.saveZone()
  if not ok then presets[name]=previous end
  return ok,err
end
function M.setMode(value)
  if value ~= 'white' and value ~= 'rainbow' and value ~= 'off' and value ~= 'custom' then
    return false, 'Use white, rainbow, custom, or off'
  end
  local mat = material()
  if not mat then return false, 'Place a six-diamond fixture first so its material is loaded.' end
  if not original then original = capture(mat) end
  if value == 'white' or value == 'rainbow' or value == 'custom' then
    -- Legacy material UV animation runs in the renderer, not a Lua frame loop.
    -- Only this diffuser changes; the housing and garage lights are untouched.
    local strength=string.format('%g %g %g',brightness,brightness,brightness)
    local values={version='1',diffuseMap='',diffuseColor='1 1 1 1',
      emissive='1',glow='1',glowFactor=strength,animFlags='0',scrollDir='1 0',scrollSpeed='0',
      rotSpeed='0',rotPivotOffset='-0.5 -0.5',sequenceFramePerSec='0',sequenceSegmentSize='1',castShadows='0'}
    if value=='rainbow' then
      if pattern=='sweep' or pattern=='reverse' then
        values.diffuseMap=root..'hbp_rainbow_legacy.png'
        values.animFlags='1'; values.scrollDir=pattern=='reverse' and '-1 0' or '1 0'
        values.scrollSpeed=tostring(.04*speed)
      elseif pattern=='circular' then
        values.diffuseMap=root..'hbp_rainbow_circular.png'
        values.animFlags='2'; values.rotSpeed=tostring(2*math.pi/25*speed)
      elseif pattern=='cycle' then
        values.diffuseMap=root..'hbp_rainbow_cycle.png'
        values.animFlags='24'; values.sequenceSegmentSize=tostring(1/256)
        values.sequenceFramePerSec=tostring(256/25*speed)
      else
        values.diffuseMap=root..'hbp_rainbow_'..pattern..'.png'
        values.animFlags='24'; values.sequenceSegmentSize=tostring(1/128)
        values.sequenceFramePerSec=tostring(128/25*speed)
      end
    end
    if value=='custom' then values.diffuseColor=string.format('%.8g %.8g %.8g 1',customColor[1],customColor[2],customColor[3]) end
    -- UV animation applies to the PBR emissive map as well as the base map.
    values.version='1.5'
    values.baseColorMap=''
    values.baseColorFactor='0 0 0 1'
    values.metallicFactor='0'; values.roughnessFactor='1'
    values.emissiveMap=value=='rainbow' and values.diffuseMap or ''
    values.emissiveFactor=value=='custom' and string.format('%.8g %.8g %.8g',customColor[1],customColor[2],customColor[3]) or '1 1 1'
    values.emissiveIntensityNits=tostring(fixtureNits(brightness))
    values.diffuseMap=''; values.diffuseColor='0 0 0 1'
    values.emissive='0'; values.glow='0'; values.glowFactor='0 0 0'
    apply(mat,values)
  else
    local values={version='1.5',baseColorMap='',baseColorFactor='0 0 0 1',
      metallicFactor='0',roughnessFactor='1',diffuseMap='',diffuseColor='0 0 0 1',
      emissiveMap='',emissiveFactor='0 0 0',emissiveIntensityNits='0',
      emissive='0',glow='0',glowFactor='0 0 0',castShadows='0',
      animFlags='0',scrollDir='1 0',scrollSpeed='0',rotSpeed='0',
      rotPivotOffset='-0.5 -0.5',sequenceFramePerSec='0',sequenceSegmentSize='1'}
    apply(mat,values)
  end
  applied=capture(mat); mode=value
  storeGroup()
  if not restoring and M.saveZone and scenetree.findObject(zoneName) then return M.saveZone() end
  return true,mode
end
function M.setColor(r,g,b)
  local c={tonumber(r),tonumber(g),tonumber(b)}
  for i=1,3 do
    local v=c[i]
    if not v or v~=v or v<0 or v>1 then return false,'Color components must be between 0 and 1' end
  end
  customColor=c
  return M.setMode('custom')
end
function M.setPattern(value)
  if not validPattern(value) then return false,'Unknown lighting pattern' end
  if pattern==value and mode=='rainbow' then return true,mode end
  pattern=value
  return M.setMode('rainbow')
end
function M.toggle() return M.setMode(mode == 'rainbow' and 'white' or 'rainbow') end
function M.show(value) dismissed=value==false; panel=inside and not dismissed end
function M.setBrightness(value)
  value=tonumber(value)
  if not value or value~=value or value<0.0001 or value>10 then return false,'Brightness must be between 0.0001 and 10' end
  if brightness==value then return true,mode end
  brightness=value
  return M.setMode(mode)
end
function M.status()
  return {fixtureStyles=fixtureStyleStatus(),group=activeGroup,groups=copy(groupStates),presets=copy(presets),upstairsFixtures=copy(upstairsFixtures),mode=mode,pattern=pattern,color={customColor[1],customColor[2],customColor[3]},materialLoaded=material() ~= nil,panel=panel,inside=inside,zoneName=zoneName,brightness=brightness,speed=speed,
    triggerCount=1+#extraZones,triggerPresent=scenetree.findObject(zoneName) ~= nil}
end
function M.setSpeed(value)
  value=tonumber(value)
  if not value or value~=value or value<0.5 or value>8 then return false,'Speed must be between 0.5x and 8x' end
  value=math.floor(value*2+.5)/2
  if speed==value then return true,mode end
  speed=value
  if mode=='rainbow' then return M.setMode(mode) end
  if not restoring and scenetree.findObject(zoneName) then return M.saveZone() end
  return true
end
-- Runtime-only grouping: trigger transforms remain in hbp_rgb_zone.settings.
local function lightingControlGroup()
  local parent=scenetree.findObject('punisherHeroHouse') or scenetree.MissionGroup
  if not parent then return nil end
  local name='hbpPlsLightingControls'
  local group=scenetree.findObject(name)
  if group and group:getClassName()~='SimGroup' then
    log('W','PunisherLighting','Lighting group name is occupied by another object; keeping triggers in their current group.')
    return nil
  end
  if not group then
    group=createObject('SimGroup')
    group.canSave=false
    group:setField('internalName',0,'PLS Lighting Controls')
    group:registerObject(name)
  end
  parent:addObject(group)
  return group
end
local function organizeLightingTriggers()
  local group=lightingControlGroup()
  if not group then return end
  local primary=scenetree.findObject(zoneName)
  if primary then group:addObject(primary) end
  for _,name in ipairs(extraZones) do
    local trigger=scenetree.findObject(name)
    if trigger then group:addObject(trigger) end
  end
end

local function remember(obj,name)
  obj.canSave=false
  obj:registerObject(name)
  local parent=lightingControlGroup() or scenetree.MissionGroup
  if parent then parent:addObject(obj) end
  owned[name]=obj:getID()
end
local function remove(name)
  local obj=scenetree.findObject(name)
  if obj and owned[name] == obj:getID() then obj:delete() end
  owned[name]=nil
end
function M.removeZone()
  for _,name in ipairs(extraZones) do remove(name) end
  extraZones={}
  remove('hbpRgbSwitchTrigger')
  panel=false; inside=false; dismissed=false
end
function M.createZoneAtCamera(savedFields,name)
  name=name or 'hbpRgbSwitchTrigger'
  local existing=scenetree.findObject(name)
  if existing and owned[name] ~= existing:getID() then
    return false,'Use setZone to connect your existing trigger instead of replacing it.'
  end
  remove(name)
  if name=='hbpRgbSwitchTrigger' then zoneName=name end
  local trigger=createObject('BeamNGTrigger')
  trigger.loadMode=1
  trigger:setField('triggerType',0,'Box'); trigger:setField('TriggerMode',0,'Overlaps')
  trigger:setField('TriggerTestType',0,'Bounding box')
  trigger:setField('luaFunction',0,'onBeamNGTrigger')
  trigger:setField('ticking',0,'0')
  if savedFields then
    for _,f in ipairs({'position','rotation','scale'}) do trigger:setField(f,0,savedFields[f]) end
  else
    trigger:setPosition(core_camera.getPosition()-vec3(0,0,0.7)); trigger:setScale(vec3(1.5,1.5,2.4))
  end
  trigger.debug=false; trigger.debugInEditor=true
  trigger:setField('internalName',0,name=='hbpRgbSwitchTrigger' and 'PLS - Downstairs Controls' or 'PLS - Upstairs Controls')
  remember(trigger,name)
  if name~=zoneName then
    local known=false
    for _,n in ipairs(extraZones) do if n==name then known=true end end
    if not known then extraZones[#extraZones+1]=name end
  end
  return true,'Move/resize the zone in the editor. saveZone() stores it in the per-level user settings file.'
end
function M.addZoneAtPlayer()
  local player=be:getPlayerVehicle(0)
  if not player then return false,'No player position available' end
  local index=2
  while scenetree.findObject('hbpRgbSwitchTrigger'..index) do index=index+1 end
  local name='hbpRgbSwitchTrigger'..index
  local p=player:getPosition()
  local fields={position=string.format('%.9g %.9g %.9g',p.x,p.y,p.z+0.7),rotation='0 0 1 0',scale='1.5 1.5 2.4'}
  local ok,err=M.createZoneAtCamera(fields,name)
  if not ok then return false,err end
  local saved,saveError=M.saveZone()
  if not saved then return false,saveError end
  return true,name
end
function M.setZone(name)
  local obj=scenetree.findObject(name)
  if not obj or obj:getClassName()~='BeamNGTrigger' or obj:getField('triggerType',0)~='Box' then
    return false,'Choose a named Box BeamNGTrigger'
  end
  zoneName=name; inside=false; panel=false; dismissed=false
  return true
end
function M.containsPoint(point,name)
  local obj=scenetree.findObject(name or zoneName)
  if not obj then return false end
  local transform=obj:getTransform()
  local delta=point-obj:getPosition()
  local p=vec3(delta:dot(transform:getColumn(0):normalized()),delta:dot(transform:getColumn(1):normalized()),delta:dot(transform:getColumn(2):normalized()))
  local s=obj:getScale()
  return math.abs(p.x)<=math.abs(s.x)*0.5 and math.abs(p.y)<=math.abs(s.y)*0.5 and math.abs(p.z)<=math.abs(s.z)*0.5
end
local function updateZone()
  local player=be:getPlayerVehicle(0)
  local now=false
  local enteredGroup=nil
  if player then
    local p=player:getPosition()
    now=M.containsPoint(p)
    if now then enteredGroup='downstairs' end
    if not now then for _,name in ipairs(extraZones) do if M.containsPoint(p,name) then now=true; enteredGroup='upstairs'; break end end end
  end
  if now~=inside then
    if now and enteredGroup then M.selectGroup(enteredGroup) end
    inside=now; dismissed=false; panel=false
  end
  if not inside then panel=false end
end
function M.saveZone()
  local obj=scenetree.findObject(zoneName)
  if not obj then return false,'No zone to save' end
  storeGroup()
  local data={version=6,fixtureStyles=copy(fixtureStyles),groups=copy(groupStates),presets=copy(presets),upstairsFixtures=copy(upstairsFixtures),activeGroup=activeGroup,zones={},color=customColor,brightness=brightness,speed=speed,mode=mode,pattern=pattern,fields={}}
  for _,f in ipairs({'position','rotation','scale'}) do data.fields[f]=obj:getField(f,0) end
  for _,name in ipairs(extraZones) do
    local zone=scenetree.findObject(name)
    if not zone then return false,'Missing lighting trigger: '..name end
    local fields={}
    for _,f in ipairs({'position','rotation','scale'}) do fields[f]=zone:getField(f,0) end
    data.zones[#data.zones+1]={name=name,fields=fields}
  end
  local path=settingsPath()
  if settingsReadError then return false,settingsReadError end
  if not path then return false,'No active level for lighting settings.' end
  local ok,err=writeSettings(path,data)
  if not ok then return false,err end
  local saved=jsonReadFile(path)
  if not saved or not saved.fixtureStyles or saved.fixtureStyles.downstairs~=fixtureStyles.downstairs or saved.fixtureStyles.upstairs~=fixtureStyles.upstairs then return false,'Fixture style was not saved' end
  if not saved or type(saved.brightness)~='number' or math.abs(saved.brightness-brightness)>0.0000001 or type(saved.speed)~='number' or math.abs(saved.speed-speed)>0.0000001 or saved.mode~=mode or saved.pattern~=pattern then
    return false,'Lighting settings could not be verified after saving'
  end
  for i=1,3 do
    if not saved.color or type(saved.color[i])~='number' or math.abs(saved.color[i]-customColor[i])>0.0000001 then return false,'Color settings could not be verified after saving' end
  end
  if not saved.zones or #saved.zones~=#data.zones then return false,'Trigger list was not saved' end
  for i,zone in ipairs(data.zones) do
    if saved.zones[i].name~=zone.name then return false,'Trigger name was not saved' end
    for f,v in pairs(zone.fields) do if not saved.zones[i].fields or saved.zones[i].fields[f]~=v then return false,'Trigger placement was not saved' end end
  end
  for f,v in pairs(data.fields) do if not saved.fields or saved.fields[f]~=v then return false,'Zone placement was not saved' end end
  return true
end
-- Persist runtime preferences in the user settings folder when the level is saved.
-- The map scene contains no generated trigger entry.
function M.onEditorBeforeSaveLevel()
  if scenetree.findObject(zoneName) then
    local ok,err=M.saveZone()
    if not ok then log('E','PunisherLighting',tostring(err)) end
  end
end
local function finite(v)
  v=tonumber(v)
  return v and v==v and math.abs(v)<math.huge and v or nil
end
local function validFields(fields)
  if type(fields)~='table' then return false end
  for name,count in pairs({position=3,rotation=4,scale=3}) do
    if type(fields[name])~='string' then return false end
    local n=0
    for value in fields[name]:gmatch('%S+') do
      n=n+1; local v=finite(value)
      if not v or (name=='scale' and v<=0) then return false end
    end
    if n~=count then return false end
  end
  return true
end
function M.onExtensionLoaded()
  if not (getMissionFilename() or ''):match('^/levels/utah/') then return false end
  restoring=true
  if loadJsonMaterialsFile then loadJsonMaterialsFile(root..'hbp_rgb_upstairs.materials.json') end
  local data=loadSettings(validFields)
  if data and validFields(data.fields) then
    local existing=scenetree.findObject(zoneName)
    local ok,err
    if existing then ok,err=M.setZone(zoneName) else ok,err=M.createZoneAtCamera(data.fields) end
    if not ok then log('E','PunisherLighting',tostring(err)) end
    local b=finite(data.brightness); if b then brightness=math.max(0.0001,math.min(10,b)) end
    local v=finite(data.speed); if v then speed=math.max(.5,math.min(8,math.floor(v*2+.5)/2)) end
  elseif data then
    log('E','PunisherLighting','Invalid saved zone; not creating a trigger at an arbitrary location')
  end
  if data and type(data.zones)=='table' then
    local seen={}
    for _,zone in ipairs(data.zones) do
      if type(zone)=='table' and type(zone.name)=='string' and zone.name:match('^hbpRgbSwitchTrigger%d+$') and not seen[zone.name] and validFields(zone.fields) then
        seen[zone.name]=true
        local existing=scenetree.findObject(zone.name)
        if existing and existing:getClassName()=='BeamNGTrigger' and existing:getField('triggerType',0)=='Box' then
          extraZones[#extraZones+1]=zone.name
        else
          local ok,err=M.createZoneAtCamera(zone.fields,zone.name)
          if not ok then log('E','PunisherLighting',tostring(err)) end
        end
      else log('E','PunisherLighting','Invalid extra trigger entry; skipped') end
    end
  end
  if data and type(data.color)=='table' then
    local c=data.color
    if finite(c[1]) and finite(c[2]) and finite(c[3]) and c[1]>=0 and c[1]<=1 and c[2]>=0 and c[2]<=1 and c[3]>=0 and c[3]<=1 then customColor={c[1],c[2],c[3]} end
  end
  pattern=data and validPattern(data.pattern) and data.pattern or 'sweep'
  local savedMode=data and data.mode or 'white'
  if savedMode~='off' and savedMode~='rainbow' and savedMode~='custom' then savedMode='white' end
  local ok,err=M.setMode(savedMode)
  if not ok then log('E','PunisherLighting',tostring(err)) end
  local initial=currentState()
  if data and type(data.upstairsFixtures)=='table' then
    upstairsFixtures={}
    for _,name in ipairs(data.upstairsFixtures) do if type(name)=='string' then upstairsFixtures[#upstairsFixtures+1]=name end end
  end
  setupFixtures()
  presets={}
  if data and type(data.presets)=='table' then
    local count=0
    for name,state in pairs(data.presets) do
      if type(name)=='string' and #name>0 and #name<=32 and not name:find('[%c]') and validState(state) and count<16 then presets[name]=copy(state); count=count+1 end
    end
  end
  for _,group in ipairs(groupNames) do
    M.selectGroup(group)
    local state=data and type(data.groups)=='table' and data.groups[group] or initial
    if not validState(state) then state=initial end
    mode=state.mode; pattern=state.pattern; customColor=copy(state.color); brightness=state.brightness; speed=math.max(.5,math.min(8,math.floor(state.speed*2+.5)/2))
    local ok,err=M.setMode(mode)
    if not ok then log('E','PunisherLighting',tostring(err)) end
  end
  M.selectGroup(data and groupLabels[data.activeGroup] and data.activeGroup or 'downstairs')
  loadFixtureStyles(data)
  organizeLightingTriggers()
  restoring=false
  be:queueJS("import(new URL('/ui/modModules/plsLighting.js?v=2026101903',window.location.href).href).then(function(m){m.install()}).catch(function(e){console.error('PLS UI load failed',e)})")
end
-- Reserve Xbox buttons only while near the panel; thumb axes stay in gameplay.
local padInputMode='off'
local padColorEditing=false
local padFilterGroup='hbpPlsControllerButtons'
local function updatePadInput(forceOff)
  if forceOff or not inside or not panel then padColorEditing=false end
  local wanted=not forceOff and inside and (panel and (padColorEditing and 'color' or 'panel') or 'prompt') or 'off'
  if wanted==padInputMode then return end
  local filter=core_input_actionFilter
  if filter then filter.addAction(0,padFilterGroup,false) end
  if Input and Input.setForwardRawEvents then Input.setForwardRawEvents(wanted~='off') end
  padInputMode=wanted
  if wanted=='off' or not filter then return end
  local blocked,keep={},{}
  for _,device in pairs(core_input_bindings and core_input_bindings.bindings or {}) do
    if (device.devname or ''):match('^xinput') then
      for _,binding in pairs(device.contents and device.contents.bindings or {}) do
        local control=binding.control or ''
        if control:match('^thumb[lr][xy]$') and not (wanted=='color' and control:match('^thumbl[xy]$')) then keep[binding.action]=true
        elseif (wanted~='prompt' or control=='btn_a') and binding.action then blocked[binding.action]=true end
      end
    end
  end
  local actions={}
  for action in pairs(blocked) do if not keep[action] then actions[#actions+1]=action end end
  filter.setGroup(padFilterGroup,actions)
  filter.addAction(0,padFilterGroup,true)
end
function M.onInputBindingsChanged() padInputMode='refresh';updatePadInput() end

-- CEF controller bridge. Only recognized commands can alter lighting.
local function publishUi(err)
  updatePadInput()
  local data=M.status()
  data.error=err
  guihooks.trigger('PLSLightingState',data)
end
function M.uiCommand(data)
  if type(data)~='table' then return false end
  local action=data.action
  if action=='status' then publishUi(); return true end
  if action=='close' then panel=false; dismissed=true; publishUi(); return true end
  if not inside then publishUi('Walk up to the wall panel to use the controller.'); return false end
  if action=='open' then panel=true; dismissed=false; publishUi(); return true end
  if not panel then return false end
  if action=='colorAdjust' then
    padColorEditing=data.active==true;updatePadInput();return true
  elseif action=='commit' then
    local state=data.state
    if not groupLabels[data.group] or not validState(state) then publishUi('Invalid lighting settings.'); return false end
    state=copy(state);state.speed=math.max(.5,math.min(8,math.floor(state.speed*2+.5)/2))
    local ok,err=M.selectGroup(data.group)
    if ok then
      brightness=state.brightness;speed=state.speed;pattern=state.pattern;customColor=copy(state.color)
      ok,err=M.setMode(state.mode)
    end
    publishUi(not ok and tostring(err) or nil);return ok
  elseif action=='fixtureStyle' then
    local ok,err=M.selectFixtureStyle(data.group,data.style);publishUi(not ok and tostring(err) or nil);return ok
  elseif action=='group' then
    local ok,err=M.selectGroup(data.group);publishUi(not ok and tostring(err) or nil);return ok
  elseif action=='save' then
    local ok,err=M.savePreset(data.name);publishUi(not ok and tostring(err) or nil);return ok
  elseif action=='delete' then
    local ok,err=M.deletePreset(data.name);publishUi(not ok and tostring(err) or nil);return ok
  end
  publishUi('Unknown lighting command.');return false
end
local lastUiSignature=''
function M.onUpdate(dtReal)
  pollTime=pollTime+(dtReal or 0)
  if pollTime<.2 then return end
  pollTime=0;updateZone();updatePadInput()
  local signature=tostring(inside)..':'..tostring(panel)..':'..activeGroup
  if signature~=lastUiSignature then lastUiSignature=signature;publishUi() end
end

function M.onExtensionUnloaded()
  restoreFixtureVisibility()
  updatePadInput(true)
  storeGroup()
  for _,group in ipairs(groupNames) do
    M.selectGroup(group)
    local mat=material()
    if mat and original and applied then
      local restore={}
      for _,f in ipairs(fields) do if mat:getField(f,0)==applied[f] then restore[f]=original[f] end end
      apply(mat,restore)
    end
  end
  for name,old in pairs(shapeBindings) do
    local obj=scenetree.findObject(name)
    if obj and obj:getField('shapeName',0)==root..'hbp_rgb_six_diamond_star_upstairs.dae' then obj:setField('shapeName',0,old); obj:postApply() end
  end
  shapeBindings={}
  M.removeZone(); guihooks.trigger('PLSLightingState',{inside=false,panel=false}); original=nil; applied=nil; groupOriginal={}; groupApplied={}
end
function M.onClientEndMission() M.onExtensionUnloaded(); original=nil; applied=nil; mode='white'; panel=false end
return M

