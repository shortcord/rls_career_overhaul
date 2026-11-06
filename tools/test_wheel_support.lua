-- Run with luajit tools/test_wheel_support.lua (or lua); no engine globals required.
package.path = 'lua/?.lua;' .. package.path
local support = require('ge/extensions/overhaul/lib/vehicles/wheelSupport')
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
local function solve(points, options)
  local result, reason = support.solve(points, options)
  assert(result, tostring(reason))
  return result
end
local function rejected(points, options)
  local result, reason = support.solve(points, options)
  assert(result == nil and type(reason) == 'string' and #reason > 0, 'expected nil, reason')
end
local function ranger()
  return {
    {x=-0.815, y=1.257, z=0.0101, groundZ=0},
    {x=0.815, y=1.257, z=0.0101, groundZ=0},
    {x=-0.815, y=-1.463, z=0.06, groundZ=0},
    {x=0.815, y=-1.463, z=0.06, groundZ=0},
  }
end
-- Independent quaternion sandwich, rather than the solver's rotation helper.
local function multiply(a, b)
  return {
    x=a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
    y=a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
    z=a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,
    w=a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z,
  }
end
local function transformed(t, p)
  local q, c = t.rotation, t.pivot
  local v = {x=p.x-c.x, y=p.y-c.y, z=p.z-c.z, w=0}
  local r = multiply(multiply(q, v), {x=-q.x, y=-q.y, z=-q.z, w=q.w})
  return {x=c.x+r.x+t.translation.x, y=c.y+r.y+t.translation.y,
    z=c.z+r.z+t.translation.z}
end
local function onGround(points, t, height, clearance, tolerance)
  for _, p in ipairs(points) do
    local r = transformed(t, p)
    near(r.z - height(r.x, r.y), clearance or 0.0002, tolerance)
  end
  near(t.translation.x, 0)
  near(t.translation.y, 0)
  local q = t.rotation
  near(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w, 1)
end

test('actual Park Ranger rake is removed without a fixed police angle', function()
  local points = ranger()
  local t = solve(points)
  near(t.angle * 180 / math.pi, 1.051, 0.001)
  near(t.pivot.x, 0); near(t.pivot.y, -0.103); near(t.pivot.z, 0.03505)
  near(t.translation.z, -0.03485)
  onGround(points, t, function() return 0 end)
end)

test('already level supports retain their orientation and need only clearance', function()
  local points = ranger()
  for _, p in ipairs(points) do p.z = 0 end
  local t = solve(points)
  near(t.angle, 0); near(t.rotation.w, 1)
  near(t.translation.z, 0.0002)
  onGround(points, t, function() return 0 end)
end)

test('90 degree yaw rotates the correction axis, not the vehicle heading', function()
  local points = ranger()
  for _, p in ipairs(points) do p.x, p.y = -p.y, p.x end
  local t = solve(points)
  near(t.rotation.x, 0); near(t.rotation.z, 0)
  assert(math.abs(t.rotation.y) > 0.009)
  onGround(points, t, function() return 0 end)
end)

test('grade and bank use the fitted ground at the rotated XY', function()
  local points = ranger()
  local function height(x, y) return 0.012*x + 0.009*y + 0.02 end
  for _, p in ipairs(points) do p.groundZ = height(p.x, p.y) end
  local t = solve(points)
  onGround(points, t, height)
  -- Minimal normal mapping has its axis perpendicular to both plane normals.
  near(t.rotation.x * 0 + t.rotation.y * (0.0499/2.72) + t.rotation.z, 0)
  near(-0.012*t.rotation.x - 0.009*t.rotation.y + t.rotation.z, 0)
end)

test('centered fits remain stable at large world coordinates', function()
  local points = ranger()
  local ox, oy, oz = 1e8, -2e8, 3e7
  local function height(x, y) return oz + 0.012*(x-ox) + 0.009*(y-oy) + 0.02 end
  for _, p in ipairs(points) do
    p.x, p.y, p.z = p.x+ox, p.y+oy, p.z+oz
    p.groundZ = height(p.x, p.y)
  end
  onGround(points, solve(points), height, 0.0002, 2e-8)
end)

test('three noncollinear points define a usable support plane', function()
  local points = ranger(); table.remove(points)
  onGround(points, solve(points), function() return 0 end)
end)

test('small residuals use the maximum required gap, never the average', function()
  local points = ranger()
  points[1].z = points[1].z + 0.004
  local t = solve(points)
  local minimum = math.huge
  for _, p in ipairs(points) do minimum = math.min(minimum, transformed(t, p).z) end
  near(minimum, 0.0002)
end)

test('missing, nonnumeric and nonfinite samples are rejected', function()
  rejected(nil); rejected({}); rejected({{}, {}})
  for _, field in ipairs({'x', 'y', 'z', 'groundZ'}) do
    for _, bad in ipairs({false, '0', 0/0, math.huge, -math.huge}) do
      local points = ranger(); points[1][field] = bad; rejected(points)
    end
    local points = ranger(); points[1][field] = nil; rejected(points)
  end
end)

test('collinear or coincident XY samples have no safe plane', function()
  rejected({{x=0,y=0,z=0,groundZ=0}, {x=1,y=1,z=0,groundZ=0}, {x=2,y=2,z=0,groundZ=0}})
  rejected({{x=1,y=1,z=0,groundZ=0}, {x=1,y=1,z=0,groundZ=0}, {x=1,y=1,z=0,groundZ=0}})
end)

test('a missing interior sample cannot silently truncate the footprint', function()
  local points = ranger()
  for _, p in ipairs(points) do p.z = 0 end
  points[5] = points[4]
  points[4] = nil
  rejected(points)
end)

test('steps and nonplanar source support are rejected', function()
  for _, field in ipairs({'z', 'groundZ'}) do
    local points = ranger(); points[1][field] = points[1][field] + 0.08
    rejected(points)
  end
end)

test('excessive angle and both signs of excessive translation are rejected', function()
  local points = ranger()
  for _, p in ipairs(points) do p.z = 0.1*p.y end
  rejected(points)
  for _, z in ipairs({-0.21, 0.21}) do
    points = ranger()
    for _, p in ipairs(points) do p.z = z end
    rejected(points)
  end
end)

test('named limits and clearance can be tightened by the caller', function()
  local points = ranger()
  rejected(points, {maxAngle=0.01})
  rejected(points, {maxTranslation=0.01})
  points[1].z = points[1].z + 0.004
  rejected(points, {maxResidual=0.0001})
  points = ranger()
  onGround(points, solve(points, {clearance=0.002}), function() return 0 end, 0.002)
end)

test('invalid options fail closed', function()
  for _, name in ipairs({'clearance', 'maxAngle', 'maxTranslation', 'maxResidual'}) do
    for _, value in ipairs({-1, math.huge, 0/0, 'bad'}) do
      rejected(ranger(), {[name]=value})
    end
  end
  rejected(ranger(), false)
end)

test('solving does not mutate samples or options', function()
  local points, snapshot = ranger(), ranger()
  local options = {clearance=0.001}
  solve(points, options)
  for i, p in ipairs(points) do
    for k, v in pairs(snapshot[i]) do assert(p[k] == v) end
    local n = 0; for _ in pairs(p) do n = n + 1 end; assert(n == 4)
  end
  assert(options.clearance == 0.001 and next(options, 'clearance') == nil)
end)

print(string.format('%d/%d tests passed', count-failures, count))
os.exit(failures == 0 and 0 or 1)
