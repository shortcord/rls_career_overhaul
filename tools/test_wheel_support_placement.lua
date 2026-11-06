-- Run with luajit tools/test_wheel_support_placement.lua (or lua); no engine globals.
package.path = 'lua/ge/extensions/?.lua;lua/?.lua;' .. package.path
if not table.clear then
  function table.clear(t) for key in pairs(t) do t[key] = nil end end
end
local placement = require('overhaul/lib/vehicles/placement/wheelSupportPlacement')
local failures, count = 0, 0
local function test(name, body)
  count = count + 1
  local ok, err = pcall(body)
  if ok then print('PASS ' .. name) else
    failures = failures + 1
    print('FAIL ' .. name .. ': ' .. tostring(err))
  end
end
local function near(actual, expected, tolerance)
  assert(type(actual) == 'number' and actual == actual and
    math.abs(actual - expected) <= (tolerance or 1e-9),
    string.format('expected %.12g, got %s', expected, tostring(actual)))
end
local function multiply(a, b)
  return {
    x=a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
    y=a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
    z=a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,
    w=a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z,
  }
end
local function inverse(q) return {x=-q.x, y=-q.y, z=-q.z, w=q.w} end
local function rotate(q, x, y, z)
  local tx, ty, tz = 2*(q.y*z-q.z*y), 2*(q.z*x-q.x*z), 2*(q.x*y-q.y*x)
  return x+q.w*tx+q.y*tz-q.z*ty, y+q.w*ty+q.z*tx-q.x*tz, z+q.w*tz+q.x*ty-q.y*tx
end
local function identity() return {x=0, y=0, z=0, w=1} end
local function pose(rotation, position, refId)
  return {position=position or {x=0, y=0, z=0.35}, rotation=rotation or identity(), refId=refId or 1}
end
local function addNode(nodes, id, x, y, z)
  nodes[id] = {cid=id, pos={x=x, y=y, z=z}}
  return id
end
-- Park Ranger geometry: rear axle z=0.4101, front z=0.46, radius 0.4.
local function ranger()
  local nodes, wheels, id = {}, {}, 10
  addNode(nodes, 1, 0, 0, 0.35) -- reference node
  local function wheel(name, wheelID, x, y, z)
    local a = addNode(nodes, id, x, y, z); id = id + 1
    local b = addNode(nodes, id, x, y, z); id = id + 1
    wheels[#wheels+1] = {name=name, wheelID=wheelID, node1=a, node2=b, radius=0.4, hasTire=true}
    return a, b
  end
  wheel('RL', 1, 0.815, 1.257, 0.4101)
  wheel('RR', 2, -0.815, 1.257, 0.4101)
  wheel('FL', 3, 0.815, -1.463, 0.46)
  wheel('FR', 4, -0.815, -1.463, 0.46)
  return {nodes=nodes, wheels=wheels, refNodes={[0]={ref=1}}}
end
local function apply(transform, point)
  local q, c, t = transform.rotation, transform.pivot, transform.translation
  local x, y, z = rotate(q, point.x-c.x, point.y-c.y, point.z-c.z)
  return {x=c.x+x+t.x, y=c.y+y+t.y, z=c.z+z+t.z}
end

test('support samples use axle midpoint minus actual wheel radius', function()
  local points = assert(placement.supportPoints(ranger(), pose()))
  assert(#points == 4)
  local lows, highs = 0, 0
  for _, p in ipairs(points) do
    if math.abs(p.z - 0.0101) < 1e-9 then lows = lows + 1 end
    if math.abs(p.z - 0.06) < 1e-9 then highs = highs + 1 end
  end
  assert(lows == 2 and highs == 2, 'expected two rear and two front support heights')
end)

test('untired hubs and duplicate axles do not pollute the support plane', function()
  local data = ranger()
  data.wheels[#data.wheels+1] = {
    name='spare', wheelID=9, node1=11, node2=12, radius=0.4, hasTire=false,
  }
  local points = assert(placement.supportPoints(data, pose()))
  assert(#points == 4)
end)

test('flat ground produces the measured 1.051 degree rake correction', function()
  local data = ranger()
  local plan = assert(placement.plan(data, pose(), function() return 0 end))
  near(plan.angle * 180 / math.pi, 1.051, 0.001)
  for _, p in ipairs(plan.points) do
    local moved = apply(plan.transform, p)
    near(moved.z, 0.0002, 1e-9)
  end
end)

test('candidate reference pose follows the same rigid transform', function()
  local data = ranger()
  local original = pose(identity(), {x=100, y=-200, z=300})
  local plan = assert(placement.plan(data, original, function() return 299.65 end))
  local expected = {}
  local q, c, t = plan.transform.rotation, plan.transform.pivot, plan.transform.translation
  local x, y, z = rotate(q, original.position.x-c.x, original.position.y-c.y, original.position.z-c.z)
  expected.x, expected.y, expected.z = c.x+x+t.x, c.y+y+t.y, c.z+z+t.z
  near(plan.position.x, expected.x); near(plan.position.y, expected.y); near(plan.position.z, expected.z)
  near(plan.rotation.w, plan.transform.rotation.w * original.rotation.w, 1e-9)
end)

test('yawed placement keeps the correction axis aligned to the vehicle', function()
  local angle = math.pi/2
  local yaw = {x=0, y=0, z=math.sin(angle/2), w=math.cos(angle/2)}
  local plan = assert(placement.plan(ranger(), pose(yaw), function() return 0 end))
  near(plan.angle * 180 / math.pi, 1.051, 0.001)
  for _, p in ipairs(plan.points) do near(apply(plan.transform, p).z, 0.0002, 1e-9) end
end)

test('local geometry follows the engine conjugated rotation convention', function()
  local angle = math.pi/2
  local yaw = {x=0, y=0, z=math.sin(angle/2), w=math.cos(angle/2)}
  local points = assert(placement.supportPoints(ranger(), pose(yaw)))
  local found = false
  for _, p in ipairs(points) do
    if math.abs(p.x - 1.257) < 1e-6 and math.abs(p.y + 0.815) < 1e-6
        and math.abs(p.z - 0.0101) < 1e-6 then
      found = true
    end
  end
  assert(found, 'expected a wheel at the engine-conjugate yaw position')
end)

test('missing ground samples fail closed', function()
  local plan, reason = placement.plan(ranger(), pose(), function() return nil end)
  assert(plan == nil and type(reason) == 'string')
  plan, reason = placement.plan(ranger(), pose(), function() return 0/0 end)
  assert(plan == nil and type(reason) == 'string')
end)

test('fewer than three road wheels fail closed', function()
  local data = ranger()
  table.remove(data.wheels, 4); table.remove(data.wheels, 3)
  local plan, reason = placement.supportPoints(data, pose())
  assert(plan == nil and type(reason) == 'string')
end)

test('validation accepts a clear candidate and rejects a static sweep', function()
  local data = ranger()
  local original = pose()
  local plan = assert(placement.plan(data, original, function() return 0 end))
  local ok, reason = placement.validate(data, original, plan,
    function() return 0 end, function() return false end)
  assert(ok, tostring(reason))
  ok, reason = placement.validate(data, original, plan,
    function() return 0 end, function() return true end)
  assert(not ok and type(reason) == 'string')
end)

test('near-surface nodes rely on clearance, not a ground sweep', function()
  local data = ranger()
  addNode(data.nodes, 21, 0, 0, 0.001) -- low node
  local original = pose()
  local plan = {transform={
    rotation=identity(), pivot={x=0, y=0, z=0}, translation={x=0, y=0, z=-0.002},
  }}
  local function blocked(from)
    return from.z < 0.01 -- would flag the low node's downward sweep
  end
  local ok, reason = placement.validate(data, original, plan,
    function() return 0 end, blocked)
  assert(ok, tostring(reason))
end)

test('validation rejects burying a collision node beyond tolerance', function()
  local data = ranger()
  addNode(data.nodes, 20, 0, -1.8, 0.005) -- low front body node
  local original = pose()
  local plan = {transform={
    rotation=identity(), pivot={x=0, y=0, z=0}, translation={x=0, y=0, z=-0.02},
  }}
  local ok, reason = placement.validate(data, original, plan,
    function() return 0 end, function() return false end)
  assert(not ok and reason:find('bury'), tostring(reason))
end)

test('cluster delta composes on the right, as the engine expects', function()
  local current = {x=0.1, y=0.2, z=0.3, w=0.92736184954957}
  local desired = multiply({x=0.2, y=-0.1, z=0.1, w=0.96824583655185}, current)
  local delta = placement.clusterDelta(current, desired)
  local composed = multiply(current, delta)
  near(composed.x, desired.x); near(composed.y, desired.y)
  near(composed.z, desired.z); near(composed.w, desired.w)
end)

test('apply sends the relative delta and the absolute original transform', function()
  _G.quat = function(x, y, z, w) return {x=x, y=y, z=z, w=w} end
  local current = {x=0, y=0, z=0, w=1}
  local desired = {x=0.009166, y=0, z=0, w=0.999958}
  local calls = {}
  local fake = {
    getOriginalRotation = function() return current end,
    setClusterPosRelRot = function(_, ref, x, y, z, qx, qy, qz, qw)
      calls.cluster = {ref=ref, x=x, y=y, z=z, q={x=qx, y=qy, z=qz, w=qw}}
    end,
    applyClusterVelocityScaleAdd = function(_, ref) calls.velocity = ref end,
    setOriginalTransform = function(_, x, y, z, qx, qy, qz, qw)
      calls.original = {x=x, y=y, z=z, q={x=qx, y=qy, z=qz, w=qw}}
    end,
  }
  local plan = {position={x=1, y=2, z=3}, rotation=desired}
  assert(placement.apply(fake, plan))
  assert(calls.cluster.ref == -1 and calls.velocity == -1)
  local composed = multiply(current, calls.cluster.q)
  near(composed.x, desired.x, 1e-6); near(composed.w, desired.w, 1e-6)
  near(calls.original.q.x, desired.x); near(calls.original.x, 1)
end)

test('only non-player AI police are eligible', function()
  local police = {isAi=true, role={name='police'}}
  assert(placement.isAiPolice(7, police, 1))
  assert(not placement.isAiPolice(7, police, 7))
  assert(not placement.isAiPolice(7, {isAi=false, role={name='police'}}, 1))
  assert(not placement.isAiPolice(7, {isAi=true, role={name='suspect'}}, 1))
  assert(not placement.isAiPolice(7, nil, 1))
end)

test('correct() applies engine geometry and records one corrected MP pose', function()
  placement.clear()
  _G.quat = function(x, y, z, w) return {x=x, y=y, z=z, w=w} end
  _G.vec3 = function(x, y, z) return {x=x, y=y, z=z} end
  _G.castRayStatic = function(origin, direction, distance)
    -- Ground at z=0 for vertical rays; no static sweep hits otherwise.
    if direction.x == 0 and direction.y == 0 and direction.z == -1 then return origin.z end
    return distance
  end
  _G.core_vehicle_manager = {getVehicleData=function() return {vdata=ranger()} end}
  local data = ranger()
  local applied = {}
  local fake = {
    getId=function() return 42 end,
    getOriginalPosition=function() return {x=0, y=0, z=0.35} end,
    getOriginalRotation=function() return identity() end,
    getRefNodeId=function() return 1 end,
    setClusterPosRelRot=function(_, ref) applied.ref = ref end,
    applyClusterVelocityScaleAdd=function() end,
    setOriginalTransform=function(_, x, y, z) applied.pos = {x=x, y=y, z=z} end,
  }
  local ok, plan = placement.correct(fake)
  assert(ok, tostring(plan))
  assert(applied.ref == -1 and type(applied.pos) == 'table')
  local captured = placement.takeCorrectedPose(42)
  assert(type(captured) == 'table' and captured.x == plan.position.x)
  assert(placement.takeCorrectedPose(42) == nil, 'MP pose must be consumed once')
end)

test('native placement runs on a forwarding proxy and captures its final pose', function()
  local stored
  local real = {
    getId=function() return 5 end,
    setPosRot=function() end,
    setOriginalTransform=function(_, x, y, z, qx, qy, qz, qw)
      stored = {x=x, y=y, z=z, q={x=qx, y=qy, z=qz, w=qw}}
    end,
  }
  local function native(proxy, pos, rot)
    assert(proxy:getId() == 5)
    proxy:setPosRot(1, 2, 3, 0, 0, 0, 1)
    proxy:setOriginalTransform(10, 20, 30, 0, 0, 0, 1)
    return 'result'
  end
  local result, captured = placement.placeWithCapture(native, real, {}, {})
  assert(result == 'result')
  assert(captured.position.x == 10 and captured.position.y == 20 and captured.position.z == 30)
  assert(stored.x == 10 and stored.q.w == 1)
end)

test('correctIfPolice returns the plan on success, not the boolean', function()
  placement.clear()
  _G.quat = function(x, y, z, w) return {x=x, y=y, z=z, w=w} end
  _G.vec3 = function(x, y, z) return {x=x, y=y, z=z} end
  _G.castRayStatic = function(origin, direction, distance)
    if direction.x == 0 and direction.y == 0 and direction.z == -1 then return origin.z end
    return distance
  end
  _G.core_vehicle_manager = {getVehicleData=function() return {vdata=ranger()} end}
  _G.gameplay_traffic = {getTrafficData=function()
    return {[42]={isAi=true, role={name='police'}}}
  end}
  _G.be = {getPlayerVehicleID=function() return 1 end}
  local fake = {
    getId=function() return 42 end,
    getOriginalPosition=function() return {x=0, y=0, z=0.35} end,
    getOriginalRotation=function() return identity() end,
    getRefNodeId=function() return 1 end,
    setClusterPosRelRot=function() end,
    applyClusterVelocityScaleAdd=function() end,
    setOriginalTransform=function() end,
  }
  local ok, plan = placement.correctIfPolice(fake)
  assert(ok == true, tostring(plan))
  assert(type(plan) == 'table' and plan.transform, 'expected the applied plan')
end)

test('correct() falls back when the ground cannot be sampled', function()
  placement.clear()
  _G.core_vehicle_manager = {getVehicleData=function() return {vdata=ranger()} end}
  _G.castRayStatic = function(origin, direction, distance) return distance end
  local fake = {
    getId=function() return 43 end,
    getOriginalPosition=function() return {x=0, y=0, z=0.35} end,
    getOriginalRotation=function() return identity() end,
    getRefNodeId=function() return 1 end,
    setClusterPosRelRot=function() error('must not move') end,
  }
  local ok, reason = placement.correct(fake)
  assert(not ok and type(reason) == 'string')
end)

print(string.format('%d/%d tests passed', count-failures, count))
os.exit(failures == 0 and 0 or 1)
