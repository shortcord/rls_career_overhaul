-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Loaner revenue shares for one payout.
-- Resolve each organisation's cut once, then cap the combined deduction so loaner
-- equipment alone can never turn a delivery into a negative payout.
local M = {}

local DEFAULT_CUT = 0.5

local function resolveGetOrganization(opts)
  if opts.getOrganization then return opts.getOrganization end
  local organizations = rawget(_G, "overhaul_world_organizations")
  return organizations and organizations.getOrganization
end

local function resolveReputationAmount(spec, organizationId)
  if type(spec) == "function" then return spec(organizationId) end
  return spec
end

-- Returns rows ordered by organisation id, and the total money deduction (<= 0).
-- opts.getOrganization: optional resolver, defaults to the world organisations extension.
-- opts.skipOrganizationIds: optional set of organisation ids to leave out.
-- opts.reputationAmount: number or function(organizationId) copied to each row untouched.
function M.compute(loanerOrganisations, grossMoney, opts)
  opts = opts or {}
  local rows = {}
  if type(loanerOrganisations) ~= "table" then return rows, 0 end

  local organizationIds = {}
  for organizationId, _ in pairs(loanerOrganisations) do
    if not (opts.skipOrganizationIds and opts.skipOrganizationIds[organizationId]) then
      organizationIds[#organizationIds + 1] = organizationId
    end
  end
  table.sort(organizationIds, function(a, b) return tostring(a) < tostring(b) end)

  local getOrganization = resolveGetOrganization(opts)
  local gross = tonumber(grossMoney) or 0
  local cap = math.max(gross, 0)
  local totalDeduction = 0

  for _, organizationId in ipairs(organizationIds) do
    local organization = getOrganization and getOrganization(organizationId)
    local level = organization and organization.reputation and organization.reputation.level
    local levelInfo = level and organization.reputationLevels and organization.reputationLevels[level+2]
    local cut = (levelInfo and levelInfo.loanerCut and levelInfo.loanerCut.value or DEFAULT_CUT)

    local deduction = cut * gross
    -- A zero or negative gross must not turn the cut into a positive payout.
    if deduction < 0 then deduction = 0 end

    rows[#rows + 1] = {
      organizationId = organizationId,
      cut = cut,
      money = -deduction,
      reputationAmount = resolveReputationAmount(opts.reputationAmount, organizationId),
    }
    totalDeduction = totalDeduction + deduction
  end

  -- Trim the last rows first so a single organisation keeps exactly today's amount.
  local excess = totalDeduction - cap
  if excess > 0 then
    for i = #rows, 1, -1 do
      local row = rows[i]
      local deduction = -row.money
      if deduction > 0 then
        local reduction = math.min(deduction, excess)
        row.money = row.money + reduction
        excess = excess - reduction
        if excess <= 0 then break end
      end
    end
  end

  local totalMoney = 0
  for _, row in ipairs(rows) do totalMoney = totalMoney + row.money end
  return rows, totalMoney
end

return M
