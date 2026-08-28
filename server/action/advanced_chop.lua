-- server/action/advanced_chop.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-G] EXECUTORES + contratos de kind da ActionSession p/ o DESMANCHE
--  AVANÇADO: adv_door (bonnet/boot/door_*), adv_engine, adv_carcass.
--
--  ActionSession controla: lifecycle · ownership · timing · revalidação · action
--  lock · idempotência (replay).
--  ESTES executores delegam ao DOMÍNIO já existente (VPChopAdv{Door,Engine,Carcass}
--  Commit em server/advanced_chop.lua) — SEM duplicar gameplay/economia.
--
--  [v1.16 P1.4 / FASE D] Cada `validate` roda no START e na revalidação do
--  COMPLETE e agora é DERIVADO DO PART REGISTRY para TODAS as peças avançadas
--  (bonnet/boot/door_* · adv_engine · adv_carcass). Cada kind mantém um FALLBACK
--  hardcoded, usado só quando o registry não está carregado / a peça não consta
--  (fxmanifest fora de ordem, def removido). A FASE E remove os fallbacks.
--    adv_door    → serra                        (registry: toolClass='cut')
--    adv_engine  → capô removido + chave de fenda (registry: requires=bonnet, toolClass='screw')
--    adv_carcass → motor removido + soldadora     (registry: requires=adv_engine, gates.welder)
--
--  Carregado DEPOIS de server/main.lua e server/advanced_chop.lua — ver fxmanifest.
-- ═══════════════════════════════════════════════════════════════════════════════

if not (ActionSession and ActionSession.RegisterKind) then return end

-- ═══ Validação derivada do Part Registry (shared/registry/parts.lua) ══════════
--  Deriva de VPChopPartRegistry.get(action) — mapeamento de erro IDÊNTICO ao
--  hardcode legado (parity garantida por registry_spec + os asserts ADV-* do
--  action_session_spec):
--    requires[]  → VPChopAdvancedState.wasRemoved(sessionId, part)  (hood_first / engine_first)
--    toolClass   → VPChopHasTool(src, wantDrill)                    (no_saw / no_screwdriver)
--    gates.welder→ VPChopWelderNearVehicle(netId)                   (no_welder_adv)
---@param v { src:integer, sessionId:string, netId:integer, action:string }
---@return string|nil err
local function registryValidate(v)
    local d = VPChopPartRegistry and VPChopPartRegistry.get(v.action)
    if not d or d.enabled ~= true then return 'part' end

    for _, req in ipairs(d.requires or {}) do
        if req.state == 'REMOVED' and not VPChopAdvancedState.wasRemoved(v.sessionId, req.part) then
            return (req.part == 'bonnet') and 'hood_first' or 'engine_first'
        end
    end

    if d.toolClass == 'cut'   and not VPChopHasTool(v.src, false) then return 'no_saw' end
    if d.toolClass == 'screw' and not VPChopHasTool(v.src, true)  then return 'no_screwdriver' end

    if d.gates and d.gates.welder == true and not VPChopWelderNearVehicle(v.netId) then
        return 'no_welder_adv'
    end
    return nil
end

--- Envolve o `validate` de um kind: registry quando a peça está registrada+enabled,
--- senão o `fallback` hardcoded (registry ausente / def removido).
---@param fallback fun(v: table): string|nil
---@return fun(v: table): string|nil
local function withRegistry(fallback)
    return function(v)
        if VPChopPartRegistry and VPChopPartRegistry.isEnabled(v.action) then
            return registryValidate(v)
        end
        return fallback(v)
    end
end

-- ─── adv_door ────────────────────────────────────────────────────────────────
ActionSession.RegisterKind('adv_door', {
    minDurKey = 'door',
    distance  = 6.0,
    validate  = withRegistry(function(v)
        local pdef = ChopParts and ChopParts[v.action]
        if not pdef or pdef.kind ~= 'door' then return 'part' end
        if not VPChopHasTool(v.src, false) then return 'no_saw' end
    end),
})
ActionSession.RegisterExecutor('adv_door', function(act)
    if type(VPChopAdvDoorCommit) ~= 'function' then return { ok = false, err = 'internal' } end
    local r = VPChopAdvDoorCommit(act.src, act.netId, act.sessionId, act.action)
    if not r.ok then return { ok = false, err = r.err or 'domain' } end
    return { ok = true, result = { phase = 2, part = act.action } }
end)

-- ─── adv_engine ──────────────────────────────────────────────────────────────
ActionSession.RegisterKind('adv_engine', {
    minDurKey = 'engine',
    distance  = 6.0,
    validate  = withRegistry(function(v)
        if not VPChopAdvancedState.wasRemoved(v.sessionId, 'bonnet') then return 'hood_first' end
        if not VPChopHasTool(v.src, true) then return 'no_screwdriver' end
    end),
})
ActionSession.RegisterExecutor('adv_engine', function(act)
    if type(VPChopAdvEngineCommit) ~= 'function' then return { ok = false, err = 'internal' } end
    local r = VPChopAdvEngineCommit(act.src, act.netId, act.sessionId)
    if not r.ok then return { ok = false, err = r.err or 'domain' } end
    return { ok = true, result = { phase = 3, part = 'adv_engine' } }
end)

-- ─── adv_carcass ─────────────────────────────────────────────────────────────
ActionSession.RegisterKind('adv_carcass', {
    minDurKey = 'carcass',
    distance  = 8.0,
    validate  = withRegistry(function(v)
        if not VPChopAdvancedState.wasRemoved(v.sessionId, 'adv_engine') then return 'engine_first' end
        if not VPChopWelderNearVehicle(v.netId) then return 'no_welder_adv' end
    end),
})
ActionSession.RegisterExecutor('adv_carcass', function(act)
    if type(VPChopAdvCarcassCommit) ~= 'function' then return { ok = false, err = 'internal' } end
    local r = VPChopAdvCarcassCommit(act.src, act.netId, act.sessionId)
    if not r.ok then return { ok = false, err = r.err or 'domain' } end
    return { ok = true, result = { phase = 4, part = 'adv_carcass' } }
end)
