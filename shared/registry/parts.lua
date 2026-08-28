-- shared/registry/parts.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [SPIKE PR-I · schema v2] PART REGISTRY — fonte ÚNICA de definição de peça.
--
--  Hoje shared/chop_parts.lua é THIN ({labelKey,kind,index}) e o advanced hardcoda
--  kind/tool/deps em server/action/advanced_chop.lua. Este módulo descreve a peça
--  por completo. INERTE — 0 call sites até a FASE C (ver PART_REGISTRY_SPIKE_REVIEW.md).
--
--  server-authoritative: client manda SÓ { sessionId, action }. Servidor deriva
--  daqui: action.kind, toolClass, minDurationMs, distance, requires, gates, reward.
--
--  Contrato de PARIDADE (registry_spec prova):
--    gtaClass == ChopParts[id].kind   ·   gtaIndex == ChopParts[id].index
--    R.projectChopParts() == ChopParts + ChopPartOrder, byte a byte
--    R.actionSpec(id) == metadados hardcoded em server/action/advanced_chop.lua
--
--  Carregar como shared_script DEPOIS de shared/registry/tools.lua.
-- ═══════════════════════════════════════════════════════════════════════════════

---@class PartRequire            -- predicado tipado do Part Graph (I5)
---@field part string
---@field state 'REMOVED'        -- futuro: 'OPEN'|'DISCONNECTED'

---@class PartActionSpec
---@field type 'remove'|'install'|'inspect'
---@field kind string                     -- kind de ActionSession
---@field minDurationMs integer           -- PISO server-authoritative. Independente de ferramenta (I1).
---@field distance number
---@field minigame 'bolt'|'cut'|'wiring'|'mechanical'|'skillcheck'|nil  -- UX (client)

---@class PartGates                       -- requisitos NÃO-inventário (I7)
---@field raised boolean                  -- ChopSession.raised
---@field welder boolean                  -- VPChopWelderNearVehicle
---@field hoodOpen boolean                -- futuro: capô ABERTO (≠ removido)

---@class PartDefinition
---@field id string
---@field category 'wheel'|'door'|'panel'|'engine'|'drivetrain'|'electronic'|'exhaust'|'interior'
---@field gtaClass 'door'|'tyre'|nil      -- == ChopParts.kind (nil = peça sintética)
---@field gtaIndex integer|nil            -- == ChopParts.index (nil = sintética → fora da projeção legada)
---@field labelKey string
---@field bones string[]                  -- HINT; resolver cai em gtaIndex/offset
---@field toolClass 'cut'|'screw'|nil     -- família de ITEM exigida (nil = nenhum item)
---@field gates PartGates
---@field requires PartRequire[]
---@field action PartActionSpec
---@field carry { enabled:boolean, prop:string|nil, animation:string|nil }
---@field rewardProfile string            -- id opaco; RewardResolver mapeia (PR #16). Registry NÃO faz economia (I6).
---@field provenance 'commodity'|'component'|nil
---@field noise number                    -- 0..1 part-inerente (Heat V2)
---@field enabled boolean

_G.VPChopPartRegistry = _G.VPChopPartRegistry or {}
local R = _G.VPChopPartRegistry

local function gates(t) return { raised = t.raised or false, welder = t.welder or false, hoodOpen = t.hoodOpen or false } end

local function wheel(id, idx, label)
    return {
        id = id, category = 'wheel', gtaClass = 'tyre', gtaIndex = idx, labelKey = label,
        bones = { id },
        toolClass = 'cut',
        gates = gates({ raised = true }),
        requires = {},
        action = { type = 'remove', kind = 'tyre', minDurationMs = 1500, distance = 7.0, minigame = 'bolt' },
        carry = { enabled = true, prop = 'prop_wheel_01', animation = 'carry' },
        rewardProfile = 'wheel_commodity',
        provenance = 'commodity',
        noise = 0.4,
        enabled = true,
    }
end

local function bodyDoor(id, idx, label, bone)
    return {
        id = id, category = 'door', gtaClass = 'door', gtaIndex = idx, labelKey = label,
        bones = { bone },
        toolClass = 'cut',
        gates = gates({}),
        requires = {},
        action = { type = 'remove', kind = 'adv_door', minDurationMs = 1500, distance = 6.0, minigame = 'cut' },
        carry = { enabled = false, prop = nil, animation = nil },
        rewardProfile = 'door_commodity',
        provenance = 'commodity',
        noise = 0.5,
        enabled = true,
    }
end

R.defs = {
    wheel_lf = wheel('wheel_lf', 0, 'part_wheel_lf'),
    wheel_rf = wheel('wheel_rf', 1, 'part_wheel_rf'),
    wheel_lr = wheel('wheel_lr', 4, 'part_wheel_lr'),
    wheel_rr = wheel('wheel_rr', 5, 'part_wheel_rr'),

    bonnet       = bodyDoor('bonnet',       4, 'part_bonnet',       'bonnet'),
    boot         = bodyDoor('boot',         5, 'part_boot',         'boot'),
    door_dside_f = bodyDoor('door_dside_f', 0, 'part_door_dside_f', 'door_dside_f'),
    door_pside_f = bodyDoor('door_pside_f', 1, 'part_door_pside_f', 'door_pside_f'),
    door_dside_r = bodyDoor('door_dside_r', 2, 'part_door_dside_r', 'door_dside_r'),
    door_pside_r = bodyDoor('door_pside_r', 3, 'part_door_pside_r', 'door_pside_r'),

    -- ─── AVANÇADO — peças SINTÉTICAS (gtaClass/gtaIndex = nil) ────────────────
    adv_engine = {
        id = 'adv_engine', category = 'engine', gtaClass = nil, gtaIndex = nil,
        labelKey = 'part_engine',
        bones = { 'engine' },
        toolClass = 'screw',                                    -- VPChopHasTool(src, true)
        gates = gates({}),
        requires = { { part = 'bonnet', state = 'REMOVED' } },  -- hood_first
        action = { type = 'remove', kind = 'adv_engine', minDurationMs = 2000, distance = 6.0, minigame = 'mechanical' },
        carry = { enabled = false, prop = nil, animation = nil },
        rewardProfile = 'engine_bulk',                          -- hoje: 5× car_parts (RewardResolver PR #16)
        provenance = nil,                                       -- PR #17: 'component' → vehicle_part
        noise = 0.5,
        enabled = true,
    },
    adv_carcass = {
        id = 'adv_carcass', category = 'panel', gtaClass = nil, gtaIndex = nil,
        labelKey = 'part_carcass',
        bones = { 'chassis' },
        toolClass = nil,                                        -- o validate de carcass NÃO checa serra hoje
        gates = gates({ welder = true }),                       -- VPChopWelderNearVehicle
        requires = { { part = 'adv_engine', state = 'REMOVED' } },  -- engine_first
        action = { type = 'remove', kind = 'adv_carcass', minDurationMs = 2500, distance = 8.0, minigame = 'cut' },
        carry = { enabled = false, prop = nil, animation = nil },
        rewardProfile = 'carcass_mixed',
        provenance = nil,
        noise = 0.8,
        enabled = true,
    },
}

-- ordem estável (== ChopPartOrder + advanced no fim). I4: peça nova ANEXA, nunca insere.
R.order = {
    'bonnet', 'boot',
    'door_dside_f', 'door_pside_f', 'door_dside_r', 'door_pside_r',
    'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr',
    'adv_engine', 'adv_carcass',
}

R.CATEGORIES = {
    wheel = true, door = true, panel = true, engine = true,
    drivetrain = true, electronic = true, exhaust = true, interior = true,
}

---@param id string
---@return PartDefinition|nil
function R.get(id) return R.defs[id] end

---@param id string
---@return boolean
function R.isEnabled(id) local d = R.defs[id]; return d ~= nil and d.enabled == true end

--- Projeção EXATA do ChopParts legado (só peças com gtaIndex; campos originais).
--- FASE B: shared/chop_parts.lua → return isto.
---@return table<string, { labelKey:string, kind:string, index:integer }>, string[]
function R.projectChopParts()
    local parts, order = {}, {}
    for _, id in ipairs(R.order) do
        local d = R.defs[id]
        if d and d.gtaIndex ~= nil then
            parts[id] = { labelKey = d.labelKey, kind = d.gtaClass, index = d.gtaIndex }
            order[#order + 1] = id
        end
    end
    return parts, order
end

--- Metadados que server/action/advanced_chop.lua hardcoda hoje — o spec cruza.
---@param id string
---@return { kind:string, minDurationMs:integer, distance:number, requires:string[], toolClass:string|nil }|nil
function R.actionSpec(id)
    local d = R.defs[id]
    if not d then return nil end
    local reqIds = {}
    for _, r in ipairs(d.requires) do reqIds[#reqIds + 1] = r.part end
    return {
        kind = d.action.kind, minDurationMs = d.action.minDurationMs, distance = d.action.distance,
        requires = reqIds, toolClass = d.toolClass,
    }
end

return R
