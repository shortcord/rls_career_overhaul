-- Aligns ambient AI police with their actual wheel-support plane after stock placement.
-- Stock spawn grounds the collidable-node bounding-box floor, not the wheel bottoms
-- (lua/ge/spawn.lua moveBBToGround/getBBOnGround), so models whose wheel-support
-- plane is not parallel to that floor can spawn with one axle in the air.
-- This adapter keeps the stock placement and obstacle checks, then applies a small,
-- bounded rigid correction only when every support sample and safety check agrees.
local wheelSupport = require("overhaul/lib/vehicles/wheelSupport")

local M = {}

local defaults = {
  clearance = 0.0002,
  maxResidual = 0.02,
  maxAngle = 3 * math.pi / 180,
  maxTranslation = 0.2,
  -- Do not allow the correction to push a collision node further than this
  -- below the surface it was already penetrating.
  nodePenetration = 0.005,
  -- Ignore sub-millimetre sweeps; they cannot reveal a new obstruction.
  sweepMin = 0.002,
  -- Near the surface, a downward sweep hits the ground itself. The clearance
  -- check owns that case; only sweep nodes that stay clearly above it.
  sweepClearance = 0.02,
}

local correctedPoses = {}

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function copyPosition(value)
  if not value or not finite(value.x) or not finite(value.y) or not finite(value.z) then return nil end
  return {x=value.x, y=value.y, z=value.z}
end

local function copyRotation(value)
  if not value or not finite(value.x) or not finite(value.y) or not finite(value.z) or not finite(value.w) then
    return nil
  end
  return {x=value.x, y=value.y, z=value.z, w=value.w}
end

-- Hamilton product. BeamNG quats are {x,y,z,w}.
local function multiply(a, b)
  return {
    x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
    y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
    z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
    w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,
  }
end

local function inverse(q)
  return {x=-q.x, y=-q.y, z=-q.z, w=q.w}
end

local function rotate(q, x, y, z)
  local tx, ty, tz = 2*(q.y*z-q.z*y), 2*(q.z*x-q.x*z), 2*(q.x*y-q.y*x)
  return x + q.w*tx + q.y*tz - q.z*ty,
    y + q.w*ty + q.z*tx - q.x*tz,
    z + q.w*tz + q.x*ty - q.y*tx
end

local function optionsWith(overrides)
  local result = {}
  for key, value in pairs(defaults) do result[key] = value end
  if overrides then
    for key in pairs(defaults) do
      if overrides[key] ~= nil then result[key] = overrides[key] end
    end
  end
  return result
end

local function validOptions(options)
  if options ~= nil and type(options) ~= 'table' then return nil, 'invalid options' end
  local result = optionsWith(options)
  for key, value in pairs(result) do
    if not finite(value) or value < 0 then return nil, 'invalid ' .. key end
  end
  return result
end

-- vdata refNodes[0] and the runtime ref node agree for stock vehicles. Prefer the
-- runtime id so the transform uses the same reference as getOriginalPosition().
local function referenceNode(vdata, pose)
  local id = pose.refId
  if id == nil and vdata.refNodes and vdata.refNodes[0] then id = vdata.refNodes[0].ref end
  local node = id ~= nil and vdata.nodes and vdata.nodes[id] or nil
  if not node or not node.pos then return nil, nil, 'missing reference node' end
  return node.pos, id
end

-- BeamNG's vec3:rotated(q) applies the conjugate of the Hamilton rotation
-- represented by q. Local JBeam geometry must use that engine convention.
local function engineRotate(q, x, y, z)
  return rotate(inverse(q), x, y, z)
end

-- World position of a JBeam-local point: position + engineRotate(q, point - refNode).
local function localToWorld(pose, refPos, x, y, z)
  local rx, ry, rz = engineRotate(pose.rotation, x-refPos.x, y-refPos.y, z-refPos.z)
  return pose.position.x + rx, pose.position.y + ry, pose.position.z + rz
end

local function worldPoint(pose, refPos, localPoint)
  local x, y, z = localToWorld(pose, refPos, localPoint.x, localPoint.y, localPoint.z)
  return {x=x, y=y, z=z}
end

local function applyTransform(transform, point)
  local q, pivot, translation = transform.rotation, transform.pivot, transform.translation
  local rx, ry, rz = rotate(q, point.x-pivot.x, point.y-pivot.y, point.z-pivot.z)
  return {
    x = pivot.x + rx + translation.x,
    y = pivot.y + ry + translation.y,
    z = pivot.z + rz + translation.z,
  }
end

-- One support sample per road wheel: axle midpoint lowered by the wheel radius.
-- vdata.wheels also carries rotators and untired hubs; require a real tire radius.
function M.supportPoints(vdata, pose)
  if type(vdata) ~= 'table' or type(pose) ~= 'table' then return nil, 'invalid input' end
  local position, rotation = copyPosition(pose.position), copyRotation(pose.rotation)
  if not position or not rotation then return nil, 'invalid original pose' end
  local refPos, _, reason = referenceNode(vdata, pose)
  if not refPos then return nil, reason end
  local points, seen = {}, {}
  for _, wheel in pairs(vdata.wheels or {}) do
    if type(wheel) == 'table' and wheel.hasTire ~= false then
      local n1, n2, radius = wheel.node1, wheel.node2, wheel.radius
      local a = type(n1) == 'number' and vdata.nodes[n1] or nil
      local b = type(n2) == 'number' and vdata.nodes[n2] or nil
      if a and b and a.pos and b.pos and finite(radius) and radius > 0 then
        local key = wheel.wheelID or (tostring(n1) .. ',' .. tostring(n2))
        if not seen[key] then
          seen[key] = true
          local mx = (a.pos.x + b.pos.x) * 0.5
          local my = (a.pos.y + b.pos.y) * 0.5
          local mz = (a.pos.z + b.pos.z) * 0.5 - radius
          local wx, wy, wz = localToWorld({position=position, rotation=rotation}, refPos, mx, my, mz)
          points[#points+1] = {x=wx, y=wy, z=wz, wheel=wheel.name}
        end
      end
    end
  end
  if #points < 3 then return nil, 'fewer than three road wheels' end
  return points
end

-- Move the whole vehicle by the solver transform: rotate about its pivot, then
-- translate. The reference node follows the same rigid transform.
function M.candidatePose(transform, pose)
  local q = transform.rotation
  local rx, ry, rz = rotate(q,
    pose.position.x - transform.pivot.x,
    pose.position.y - transform.pivot.y,
    pose.position.z - transform.pivot.z)
  -- Engine quats compose as q_current * relative, and relative = inverse(q).
  return {
    position = {
      x = transform.pivot.x + rx + transform.translation.x,
      y = transform.pivot.y + ry + transform.translation.y,
      z = transform.pivot.z + rz + transform.translation.z,
    },
    rotation = multiply(pose.rotation, inverse(q)),
  }
end

-- sampleGround(x, y, z) returns the surface height beneath that point, or nil.
function M.plan(vdata, pose, sampleGround, overrides)
  if type(sampleGround) ~= 'function' then return nil, 'missing ground sampler' end
  local options, reason = validOptions(overrides)
  if not options then return nil, reason end
  local points
  points, reason = M.supportPoints(vdata, pose)
  if not points then return nil, reason end
  for _, point in ipairs(points) do
    local ground = sampleGround(point.x, point.y, point.z)
    if not finite(ground) then return nil, 'no ground under support point' end
    point.groundZ = ground
  end
  local transform
  transform, reason = wheelSupport.solve(points, {
    clearance = options.clearance,
    maxResidual = options.maxResidual,
    maxAngle = options.maxAngle,
    maxTranslation = options.maxTranslation,
  })
  if not transform then return nil, reason end
  local candidate = M.candidatePose(transform, pose)
  return {
    transform = transform,
    pose = pose,
    points = points,
    position = candidate.position,
    rotation = candidate.rotation,
    angle = transform.angle,
  }
end

-- Reject a candidate that would bury a collision node or sweep through statics.
-- Static rays are sampled checks, so uncertainty falls back to the stock pose.
function M.validate(vdata, pose, plan, sampleGround, staticBlocked, overrides)
  local options, reason = validOptions(overrides)
  if not options then return false, reason end
  if type(sampleGround) ~= 'function' or type(staticBlocked) ~= 'function' then
    return false, 'missing safety sampler'
  end
  local refPos, _, refReason = referenceNode(vdata, pose)
  if not refPos then return false, refReason end
  local transform = plan.transform
  for _, node in pairs(vdata.nodes or {}) do
    if type(node) == 'table' and node.staticCollision ~= false and node.pos then
      local baseline = worldPoint(pose, refPos, node.pos)
      local candidate = applyTransform(transform, baseline)
      local baselineGround = sampleGround(baseline.x, baseline.y, baseline.z)
      local candidateGround = sampleGround(candidate.x, candidate.y, candidate.z)
      local candidateClearance = math.huge
      if baselineGround ~= nil or candidateGround ~= nil then
        if not finite(baselineGround) or not finite(candidateGround) then
          return false, 'ground lost beneath collision node'
        end
        local allowed = math.min(baseline.z - baselineGround, 0) - options.nodePenetration
        candidateClearance = candidate.z - candidateGround
        if candidateClearance < allowed then
          return false, 'correction would bury a collision node'
        end
      end
      if candidateClearance > options.sweepClearance
          and staticBlocked(baseline, candidate, options.sweepMin) then
        return false, 'correction would sweep through static geometry'
      end
    end
  end
  return true
end

-- Relative cluster delta that yields the desired absolute rotation.
-- setClusterPosRelRot composes current * delta (see spawn.lua and rigRecovery.lua).
function M.clusterDelta(current, desired)
  return multiply(inverse(current), desired)
end

function M.apply(veh, plan, current)
  current = copyRotation(current or (plan.pose and plan.pose.rotation))
  if not current then current = copyRotation(veh:getOriginalRotation()) end
  if not current or not plan.position or not plan.rotation then return false, 'invalid pose' end
  local desired = plan.rotation
  local delta = M.clusterDelta(current, desired)
  veh:setClusterPosRelRot(-1,
    plan.position.x, plan.position.y, plan.position.z,
    delta.x, delta.y, delta.z, delta.w)
  veh:applyClusterVelocityScaleAdd(-1, 0, 0, 0, 0)
  veh:setOriginalTransform(
    plan.position.x, plan.position.y, plan.position.z,
    desired.x, desired.y, desired.z, desired.w)
  return true
end

function M.sampleGround(x, y, z)
  if type(castRayStatic) ~= 'function' or type(vec3) ~= 'function' then return nil end
  local startZ = z + 1
  local distance = 8
  local hit = castRayStatic(vec3(x, y, startZ), vec3(0, 0, -1), distance)
  if not finite(hit) or hit >= distance - 1e-4 then return nil end
  return startZ - hit
end

function M.staticBlocked(from, to, minimum)
  if type(castRayStatic) ~= 'function' or type(vec3) ~= 'function' then return true end
  local dx, dy, dz = to.x-from.x, to.y-from.y, to.z-from.z
  local length = math.sqrt(dx*dx + dy*dy + dz*dz)
  if length < (minimum or defaults.sweepMin) then return false end
  local hit = castRayStatic(vec3(from.x, from.y, from.z), vec3(dx/length, dy/length, dz/length), length)
  return finite(hit) and hit < length - (minimum or defaults.sweepMin)
end

function M.poseFromVehicle(veh)
  local position = copyPosition(veh:getOriginalPosition())
  local rotation = copyRotation(veh:getOriginalRotation())
  if not position or not rotation then return nil, 'missing original pose' end
  return {position=position, rotation=rotation, refId=veh:getRefNodeId()}
end

-- Returns ok, plan-or-reason, and never throws for an ordinary rejection.
-- suppliedPose is the pose captured from the stock placement itself, avoiding
-- any dependence on physics-backed getters that may not have caught up yet.
function M.correct(veh, overrides, suppliedPose)
  if not veh then return false, 'no vehicle' end
  local id = veh:getId()
  local bundle = core_vehicle_manager and core_vehicle_manager.getVehicleData
    and core_vehicle_manager.getVehicleData(id) or nil
  local vdata = bundle and (bundle.vdata or bundle) or nil
  if not vdata or type(vdata.nodes) ~= 'table' or type(vdata.wheels) ~= 'table' then
    return false, 'vehicle geometry unavailable'
  end
  local pose, reason
  if suppliedPose then
    local position, rotation = copyPosition(suppliedPose.position), copyRotation(suppliedPose.rotation)
    if not position or not rotation then return false, 'invalid supplied pose' end
    pose = {position=position, rotation=rotation, refId=suppliedPose.refId or veh:getRefNodeId()}
  else
    pose, reason = M.poseFromVehicle(veh)
    if not pose then return false, reason end
  end
  local plan
  plan, reason = M.plan(vdata, pose, M.sampleGround, overrides)
  if not plan then return false, reason end
  local valid
  valid, reason = M.validate(vdata, pose, plan, M.sampleGround, M.staticBlocked, overrides)
  if not valid then return false, reason end
  local applied
  applied, reason = M.apply(veh, plan, pose.rotation)
  if not applied then return false, reason end
  correctedPoses[id] = {
    x = plan.position.x, y = plan.position.y, z = plan.position.z,
    rx = plan.rotation.x, ry = plan.rotation.y, rz = plan.rotation.z, rw = plan.rotation.w,
  }
  return true, plan
end

-- Run a native placement on a forwarding proxy and capture setOriginalTransform.
-- The capture proves placement succeeded and supplies the exact final pose.
function M.placeWithCapture(safeTeleport, veh, pos, rot, checkOnlyStatics, visibilityPoint,
    removeTraffic, centeredPosition, resetVehicle, player, unlimitedSafeSpawnRange)
  local captured
  local proxy = setmetatable({
    setOriginalTransform = function(_, x, y, z, qx, qy, qz, qw)
      captured = {position={x=x, y=y, z=z}, rotation={x=qx, y=qy, z=qz, w=qw}}
      return veh:setOriginalTransform(x, y, z, qx, qy, qz, qw)
    end,
  }, {__index = function(_, name)
    local member = veh[name]
    if type(member) == 'function' then return function(_, ...) return member(veh, ...) end end
    return member
  end})
  local result = safeTeleport(proxy, pos, rot, checkOnlyStatics, visibilityPoint, removeTraffic,
    centeredPosition, resetVehicle, player, unlimitedSafeSpawnRange)
  return result, captured
end

-- Pure classification; runtime supplies the traffic entry and player id.
function M.isAiPolice(id, data, playerId)
  return type(data) == 'table' and data.isAi == true
    and type(data.role) == 'table' and data.role.name == 'police'
    and id ~= playerId
end

local function trafficEntry(id)
  local traffic = rawget(_G, 'gameplay_traffic')
  if not traffic or type(traffic.getTrafficData) ~= 'function' then return nil end
  local ok, data = pcall(traffic.getTrafficData)
  return ok and type(data) == 'table' and data[id] or nil
end

local function playerVehicleId()
  local player = rawget(_G, 'be')
  if not player or type(player.getPlayerVehicleID) ~= 'function' then return nil end
  local ok, id = pcall(player.getPlayerVehicleID, player, 0)
  return ok and id or nil
end

local function logApplied(id, plan)
  if type(plan) ~= 'table' or not plan.transform then return end
  if type(log) == 'function' then
    log('I', 'wheelSupport', string.format(
      'vehicle %d wheel support aligned: %.3f deg, dz %.4f m',
      id, math.deg(plan.angle), plan.transform.translation.z))
  end
end

local function logSkipped(id, reason)
  if type(log) == 'function' and reason ~= 'not ai police' then
    log('D', 'wheelSupport', string.format('vehicle %s support correction skipped: %s', tostring(id), tostring(reason)))
  end
end

-- Recycling and forceTeleport path: the traffic entry already exists.
function M.correctIfPolice(veh, suppliedPose)
  if not veh then return false, 'no vehicle' end
  local validId, id = pcall(function() return veh:getId() end)
  if not validId then return false, 'invalid vehicle' end
  if not M.isAiPolice(id, trafficEntry(id), playerVehicleId()) then return false, 'not ai police' end
  local called, corrected, plan = pcall(M.correct, veh, nil, suppliedPose)
  if not called then
    if type(log) == 'function' then log('W', 'wheelSupport', 'support correction error: ' .. tostring(corrected)) end
    return false, corrected
  end
  if not corrected then
    logSkipped(id, plan)
    return false, plan
  end
  logApplied(id, plan)
  return true, plan
end

-- Initial provider spawn path: only entries explicitly marked by the police provider.
function M.correctMarked(veh)
  if not veh then return false, 'no vehicle' end
  local called, ok, plan = pcall(M.correct, veh)
  if not called then
    if type(log) == 'function' then log('W', 'wheelSupport', 'support correction error: ' .. tostring(ok)) end
    return false, ok
  end
  if not ok then
    logSkipped(veh:getId(), plan)
    return false, plan
  end
  logApplied(veh:getId(), plan)
  return true, plan
end

-- MP pose capture consumes the stock (pre-correction) pose. Substitute the
-- corrected pose while preserving consume-on-read and clearing on the next teleport.
function M.takeCorrectedPose(id)
  local pose = correctedPoses[id]
  correctedPoses[id] = nil
  return pose
end

function M.forget(id)
  correctedPoses[id] = nil
end

function M.clear()
  table.clear(correctedPoses)
end

M.defaults = defaults

return M
