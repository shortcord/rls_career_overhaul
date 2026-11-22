local now = 0
local entries = {}
local timing = dofile('lua/ge/extensions/overhaul/lib/perf/luaTiming.lua').new({
  clock = function() return now end,
  log = function(level, tag, message) entries[#entries + 1] = {level, tag, message} end,
  interval = 10,
})

local calls = 0
local wrapped = timing.wrap('sample.onUpdate', function(a, b)
  calls = calls + 1
  now = now + (calls == 1 and 0.002 or 0.004)
  return a, nil, b
end)

local a, missing, b = wrapped('first', 'last')
assert(a == 'first' and missing == nil and b == 'last', 'wrapped hooks must preserve all returns')
now = 10
wrapped('first', 'last')
assert(calls == 2 and #entries == 1, 'timing must report once per interval')
assert(entries[1][1] == 'I' and entries[1][2] == 'overhaul.luaTiming', 'report should be an info log')
assert(entries[1][3]:find('sample.onUpdate', 1, true), 'report must identify the hook')
assert(entries[1][3]:find('calls=2', 1, true), 'report must aggregate calls')
assert(entries[1][3]:find('max_ms=4.000', 1, true), 'report must include the worst call')

timing.setEnabled(false)
now = 20
wrapped('first', 'last')
assert(calls == 3 and #entries == 1, 'disabled timing must not report')

timing.setEnabled(true)
now = 31
wrapped('first', 'last')
assert(#entries == 1, 're-enabled timing must start a fresh interval')
now = 41
wrapped('first', 'last')
assert(#entries == 2 and entries[2][3]:find('calls=2', 1, true), 're-enabled timing must not include old calls')

for _, path in ipairs({
  'lua/ge/extensions/overhaul/events/host.lua',
  'lua/ge/extensions/overhaul/events/fre/host.lua',
  'lua/ge/extensions/overhaul/career/saveSystem.lua',
  'lua/ge/extensions/overhaul/career/parts/partInventory.lua',
}) do
  local file = assert(io.open(path, 'r'))
  local source = file:read('*a')
  file:close()
  assert(source:find('luaTiming.wrap', 1, true), path .. ' must report its hook timing')
end

print('lua timing tests passed')
