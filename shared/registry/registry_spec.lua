-- shared/registry/registry_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [SPIKE PR-I · schema v2] Self-test do PART REGISTRY + TOOL REGISTRY.
--  NÃO roda em produção (self-gated: convar vp_chopshop_selftest 1).
--
--  Prova que os registries INERTES são consistentes E que a projeção legada é
--  byte-idêntica ao contrato atual (ChopParts + metadados hardcoded do advanced).
--  Se este spec passa, a FASE B (chop_parts.lua → projeção) é 0-bit de comportamento.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local function run()

local P = _G.VPChopPartRegistry
local T = _G.VPChopToolRegistry

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[registry/spec] PASS  ' .. name)
    else fail = fail + 1; print('[registry/spec] FAIL  ' .. name) end
end
local function sameSet(a, b)
    if #a ~= #b then return false end
    local s = {}; for _, v in ipairs(a) do s[v] = true end
    for _, v in ipairs(b) do if not s[v] then return false end end
    return true
end

-- ═══ CONTRATO ATUAL (embutido — é exatamente o que o repo tem @ 99371e4) ═════

local CHOP_PARTS = {  -- shared/chop_parts.lua
    bonnet       = { labelKey = 'part_bonnet',       kind = 'door', index = 4 },
    boot         = { labelKey = 'part_boot',         kind = 'door', index = 5 },
    door_dside_f = { labelKey = 'part_door_dside_f', kind = 'door', index = 0 },
    door_pside_f = { labelKey = 'part_door_pside_f', kind = 'door', index = 1 },
    door_dside_r = { labelKey = 'part_door_dside_r', kind = 'door', index = 2 },
    door_pside_r = { labelKey = 'part_door_pside_r', kind = 'door', index = 3 },
    wheel_lf     = { labelKey = 'part_wheel_lf',     kind = 'tyre', index = 0 },
    wheel_rf     = { labelKey = 'part_wheel_rf',     kind = 'tyre', index = 1 },
    wheel_lr     = { labelKey = 'part_wheel_lr',     kind = 'tyre', index = 4 },
    wheel_rr     = { labelKey = 'part_wheel_rr',     kind = 'tyre', index = 5 },
}
local CHOP_PART_ORDER = {
    'bonnet', 'boot',
    'door_dside_f', 'door_pside_f', 'door_dside_r', 'door_pside_r',
    'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr',
}
-- server/action/advanced_chop.lua (+ Config.ActionSession.MinDurationMs). Chave = id de PEÇA.
local ADV_CONTRACT = {
    bonnet       = { kind = 'adv_door',    minDurationMs = 1500, distance = 6.0, requires = {},              toolClass = 'cut'  },
    door_pside_r = { kind = 'adv_door',    minDurationMs = 1500, distance = 6.0, requires = {},              toolClass = 'cut'  },
    adv_engine   = { kind = 'adv_engine',  minDurationMs = 2000, distance = 6.0, requires = { 'bonnet' },    toolClass = 'screw' },
    adv_carcass  = { kind = 'adv_carcass', minDurationMs = 2500, distance = 8.0, requires = { 'adv_engine' }, toolClass = nil    },
}

-- ═══ 1. TOOL REGISTRY ═══════════════════════════════════════════════════════

check('tool registry loaded', type(T) == 'table' and type(T.defs) == 'table')
do
    local ok = true
    for id, d in pairs(T.defs) do
        if d.id ~= id then ok = false end
        if d.class ~= 'cut' and d.class ~= 'screw' then ok = false end
        if type(d.maxUses) ~= 'number' or d.maxUses < 1 then ok = false end
        if type(d.uxSpeed) ~= 'number' or d.uxSpeed <= 0 then ok = false end
        for _, k in ipairs({ 'noise', 'dispatchChance', 'breakChance' }) do
            if type(d[k]) ~= 'number' or d[k] < 0 or d[k] > 1 then ok = false end
        end
    end
    check('every ToolDefinition well-formed', ok)
end
check('only the 3 runtime tools present', T.get('saw_cheap') and T.get('saw_pro') and T.get('mechanic_drill'))
check('dead config NOT modeled (metal_saw/screwdriver)', T.get('metal_saw') == nil and T.get('screwdriver') == nil)
check('gates NOT modeled as tools (welder/jackstand)', T.get('welder') == nil and T.get('chopshop_jackstand') == nil)
check('R.forClass(cut) → serras', sameSet(T.forClass('cut'), { 'saw_cheap', 'saw_pro' }))
check('R.forClass(screw) → drill', sameSet(T.forClass('screw'), { 'mechanic_drill' }))
check('maxUses parity (2/6/10 == VPChopConsumeTool)',
    T.get('saw_cheap').maxUses == 2 and T.get('saw_pro').maxUses == 6 and T.get('mechanic_drill').maxUses == 10)
check('R.CLASSES derived from defs (cut+screw only)', T.CLASSES.cut and T.CLASSES.screw and not T.CLASSES.weld)
check('R.wantDrill: screw→true, cut→false, nil→nil',
    T.wantDrill('screw') == true and T.wantDrill('cut') == false and T.wantDrill(nil) == nil)

-- ═══ 2. PART REGISTRY ═══════════════════════════════════════════════════════

check('part registry loaded', type(P) == 'table' and type(P.defs) == 'table')
do
    local ok = true
    for id, d in pairs(P.defs) do
        if d.id ~= id then ok = false end
        if not P.CATEGORIES[d.category] then ok = false end
        if not (d.gtaClass == nil or d.gtaClass == 'door' or d.gtaClass == 'tyre') then ok = false end
        if not (d.toolClass == nil or T.CLASSES[d.toolClass]) then ok = false; print('  ↳ toolClass inválida em ' .. id) end
        if type(d.bones) ~= 'table' or #d.bones == 0 then ok = false end
        if type(d.gates) ~= 'table' or type(d.gates.raised) ~= 'boolean' then ok = false end
        if type(d.action) ~= 'table' or d.action.type ~= 'remove' then ok = false end
        if type(d.action.minDurationMs) ~= 'number' or d.action.minDurationMs <= 0 then ok = false end
        if type(d.rewardProfile) ~= 'string' then ok = false end
        for _, r in ipairs(d.requires) do
            if type(r) ~= 'table' or type(r.part) ~= 'string' or r.state ~= 'REMOVED' then ok = false end
        end
    end
    check('every PartDefinition well-formed (v2)', ok)
end
do  -- nenhuma peça usa classe RESERVADA (weld/lift/scan/hack) como toolClass
    local ok = true
    for id, d in pairs(P.defs) do
        if d.toolClass ~= nil and T.RESERVED[d.toolClass] then ok = false; print('  ↳ ' .. id .. ' usa RESERVED ' .. d.toolClass) end
    end
    check('no part uses a RESERVED tool class', ok)
end
do  -- toda dependência aponta p/ peça real; sem self-dep
    local ok = true
    for id, d in pairs(P.defs) do
        for _, r in ipairs(d.requires) do
            if not P.get(r.part) then ok = false; print('  ↳ dep inexistente: ' .. tostring(r.part)) end
            if r.part == id then ok = false end
        end
    end
    check('every requires.part resolves; no self-dependency', ok)
end
do  -- todo action.kind com toolClass != nil é servido por >=1 item daquela classe (A8)
    local ok = true
    for id, d in pairs(P.defs) do
        if d.toolClass ~= nil and #T.forClass(d.toolClass) == 0 then
            ok = false; print('  ↳ ' .. id .. ' exige toolClass ' .. d.toolClass .. ' sem nenhum item')
        end
    end
    check('every part.toolClass has >=1 tool item', ok)
end

-- ═══ 3. PROJEÇÃO LEGADA == ChopParts ════════════════════════════════════════

do
    local proj, projOrder = P.projectChopParts()
    local n = 0; for _ in pairs(proj) do n = n + 1 end
    check('projection has exactly 10 legacy parts', n == 10)
    local ok = true
    for id, expect in pairs(CHOP_PARTS) do
        local got = proj[id]
        if not got or got.labelKey ~= expect.labelKey or got.kind ~= expect.kind or got.index ~= expect.index then
            ok = false; print('  ↳ divergência em ' .. id)
        end
    end
    check('projection matches ChopParts field-by-field', ok)
    check('synthetic parts NOT in legacy projection', proj.adv_engine == nil and proj.adv_carcass == nil)
    local sameOrder = #projOrder == #CHOP_PART_ORDER
    if sameOrder then for i = 1, #projOrder do if projOrder[i] ~= CHOP_PART_ORDER[i] then sameOrder = false end end end
    check('projection order == ChopPartOrder', sameOrder)
end

-- ═══ 4. METADADOS DO ADVANCED == server/action/advanced_chop.lua ═════════════

do
    local ok = true
    for id, expect in pairs(ADV_CONTRACT) do
        local got = P.actionSpec(id)
        if not got then
            ok = false; print('  ↳ actionSpec(' .. id .. ') = nil')
        else
            if got.kind ~= expect.kind then ok = false; print('  ↳ ' .. id .. ' kind ' .. tostring(got.kind)) end
            if got.minDurationMs ~= expect.minDurationMs then ok = false; print('  ↳ ' .. id .. ' minDur') end
            if got.distance ~= expect.distance then ok = false; print('  ↳ ' .. id .. ' dist') end
            if got.toolClass ~= expect.toolClass then ok = false; print('  ↳ ' .. id .. ' toolClass ' .. tostring(got.toolClass)) end
            if not sameSet(got.requires, expect.requires) then ok = false; print('  ↳ ' .. id .. ' requires') end
        end
    end
    check('advanced action metadata matches hardcoded executor', ok)
end
check('adv_engine requires bonnet REMOVED (hood_first)',
    #P.get('adv_engine').requires == 1 and P.get('adv_engine').requires[1].part == 'bonnet'
        and P.get('adv_engine').requires[1].state == 'REMOVED')
check('adv_carcass requires adv_engine REMOVED (engine_first)',
    #P.get('adv_carcass').requires == 1 and P.get('adv_carcass').requires[1].part == 'adv_engine')
check('adv_carcass gates.welder = true', P.get('adv_carcass').gates.welder == true)
check('wheels gates.raised (parity requiresRaised)', P.get('wheel_lf').gates.raised and P.get('wheel_rr').gates.raised)
check('doors do NOT gate raised (parity)', not P.get('bonnet').gates.raised and not P.get('door_pside_r').gates.raised)
check('only wheels carry today (parity w/ TyreEntitlement)',
    P.get('wheel_lf').carry.enabled and not P.get('bonnet').carry.enabled and not P.get('adv_engine').carry.enabled)
check('nothing provenance=component yet (engine still bulk car_parts)',
    P.get('adv_engine').provenance == nil and P.get('wheel_lf').provenance == 'commodity')
check('I1 — minDurationMs is tool-independent (no speed field on part)',
    P.get('wheel_lf').action.speed == nil and P.get('wheel_lf').action.uxSpeed == nil)

-- ═══ resumo ═════════════════════════════════════════════════════════════════
print(('[registry/spec] %d/%d PASS%s'):format(pass, total, fail > 0 and ('  (%d FAIL)'):format(fail) or ''))
if fail > 0 then error(('registry_spec: %d/%d failed'):format(fail, total)) end

end  -- run

if _G.CreateThread then CreateThread(run) else run() end
