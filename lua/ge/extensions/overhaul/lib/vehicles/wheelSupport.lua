local M = {}

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

-- Evaluate relative to the centroid, never an intercept at the world origin.
local function fit(points, field, cx, cy, mean)
  local xx, xy, yy, xz, yz = 0, 0, 0, 0, 0
  for _, p in ipairs(points) do
    local x, y, z = p.x-cx, p.y-cy, p[field]-mean
    xx, xy, yy = xx+x*x, xy+x*y, yy+y*y
    xz, yz = xz+x*z, yz+y*z
  end
  local determinant = xx*yy-xy*xy
  if not finite(determinant) or determinant <= 1e-12*xx*yy or xx <= 0 or yy <= 0 then
    return nil, 'degenerate support footprint'
  end
  local a, b = (xz*yy-yz*xy)/determinant, (yz*xx-xz*xy)/determinant
  if not finite(a) or not finite(b) then return nil, 'nonfinite plane' end
  local residual = 0
  for _, p in ipairs(points) do
    residual = math.max(residual, math.abs((p[field]-mean)-a*(p.x-cx)-b*(p.y-cy)))
  end
  local length = math.sqrt(a*a+b*b+1)
  if not finite(length) or not finite(residual) then return nil, 'nonfinite plane' end
  return {a=a, b=b, residual=residual, x=-a/length, y=-b/length, z=1/length}
end

local function rotate(q, x, y, z)
  local tx, ty, tz = 2*(q.y*z-q.z*y), 2*(q.z*x-q.x*z), 2*(q.x*y-q.y*x)
  return x+q.w*tx+q.y*tz-q.z*ty,
    y+q.w*ty+q.z*tx-q.x*tz,
    z+q.w*tz+q.x*ty-q.y*tx
end

-- points are actual initial WORLD wheel-bottom samples with static-ray groundZ.
-- angle/maxAngle use radians; all other limits use metres. No engine globals.
-- Apply: pivot + rotate(rotation, point - pivot) + translation.
function M.solve(points, options)
  if type(points) ~= 'table' or #points < 3 then return nil, 'need at least three support points' end
  local count = #points
  -- Lua's length operator is ambiguous for sparse tables; do not fit a prefix.
  for key in pairs(points) do
    if type(key) == 'number' and (key < 1 or key > count or key % 1 ~= 0) then
      return nil, 'invalid support array'
    end
  end
  if options ~= nil and type(options) ~= 'table' then return nil, 'invalid options' end
  options = options or {}
  local limits = {clearance=0.0002, maxResidual=0.01, maxAngle=3*math.pi/180, maxTranslation=0.2}
  for key, default in pairs(limits) do
    local value = options[key]
    if value == nil then value = default end
    if not finite(value) or value < 0 then return nil, 'invalid ' .. key end
    limits[key] = value
  end
  for i = 1, count do
    local p = points[i]
    if type(p) ~= 'table' or not finite(p.x) or not finite(p.y) or
        not finite(p.z) or not finite(p.groundZ) then
      return nil, 'invalid support sample'
    end
  end

  -- Offset before summing to retain precision at large map coordinates.
  local first = points[1]
  local cx, cy, cz, cg = 0, 0, 0, 0
  for _, p in ipairs(points) do
    cx, cy = cx+(p.x-first.x), cy+(p.y-first.y)
    cz, cg = cz+(p.z-first.z), cg+(p.groundZ-first.groundZ)
  end
  cx, cy, cz, cg = first.x+cx/count, first.y+cy/count, first.z+cz/count, first.groundZ+cg/count
  local source, reason = fit(points, 'z', cx, cy, cz)
  if not source then return nil, reason end
  local ground
  ground, reason = fit(points, 'groundZ', cx, cy, cg)
  if not ground then return nil, reason end
  if source.residual > limits.maxResidual or ground.residual > limits.maxResidual then
    return nil, 'nonplanar support or ground'
  end

  local dot = math.max(-1, math.min(1, source.x*ground.x+source.y*ground.y+source.z*ground.z))
  local angle = math.acos(dot)
  if angle > limits.maxAngle then return nil, 'excessive correction angle' end
  -- Shortest-arc quaternion maps the upward source normal onto the ground normal.
  local q = {
    x=source.y*ground.z-source.z*ground.y,
    y=source.z*ground.x-source.x*ground.z,
    z=source.x*ground.y-source.y*ground.x,
    w=1+dot,
  }
  local length = math.sqrt(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w)
  if not finite(length) or length <= 1e-12 then return nil, 'unsafe rotation' end
  q.x, q.y, q.z, q.w = q.x/length, q.y/length, q.z/length, q.w/length

  local translation = -math.huge
  for _, p in ipairs(points) do
    local x, y, z = rotate(q, p.x-cx, p.y-cy, p.z-cz)
    local required = (cg-cz)+ground.a*x+ground.b*y-z+limits.clearance
    if not finite(required) then return nil, 'nonfinite correction' end
    translation = math.max(translation, required)
  end
  if math.abs(translation) > limits.maxTranslation then return nil, 'excessive correction translation' end
  return {
    rotation=q, pivot={x=cx, y=cy, z=cz},
    translation={x=0, y=0, z=translation}, angle=angle,
  }
end

return M
