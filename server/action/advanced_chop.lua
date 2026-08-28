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
--  Cada `validate` do kind roda no START e na REVALIDAÇÃO do COMPLETE:
--    adv_door    → serra
--    adv_engine  → capô removido (hood_first) + chave de fenda
--    adv_carcass → motor removido (engine_first) + soldadora perto
--
--  Carregado DEPOIS de server/main.lua e server/advanced_chop.lua — ver fxmanifest.
-- ═══════════════════════════════════════════════════════════════════════════════

if not (ActionSession and ActionSession.RegisterKind) then return end

-- ═══ [v1.16 P1.3 / FASE C] Validação derivada do Part Registry ════════════════
--  Vertical slice: só `bonnet` valida por aqui nesta fase. Os demais adv_door
--  (boot / door_*), adv_engine e adv_carcass seguem no hardcode abaixo até a
--  FASE D generalizar. A paridade byte-a-byte (registry == hardcode p/ bonnet) é
--  garantida por shared/registry/registry_spec.lua + os asserts ADV-C do
--  action_session_spec. Mapeamento de erro IDÊNTICO ao hardcode.
--
--  Deriva de VPChopPartRegistry.get(action):
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

-- ─── adv_door ────────────────────────────────────────────────────────────────
ActionSession.RegisterKind('adv_door', {
    minDurKey = 'door',
    distance  = 6.0,
    validate  = function(v)
        -- [P1.3 / FASE C] fast-path do registry só p/ bonnet; hardcode é o fallback
        -- (boot / door_*, e bonnet também se o registry não estiver carregado).
        if v.action == 'bonnet' and VPChopPartRegistry and VPChopPartRegistry.isEnabled('bonnet') then
            return registryValidate(v)
        end
        local pdef = ChopParts and ChopParts[v.action]
        if not pdef or pdef.kind ~= 'door' then return 'part' end
        if not VPChopHasTool(v.src, false) then return 'no_saw' end
    end,
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
    validate  = function(v)
        if not VPChopAdvancedState.wasRemoved(v.sessionId, 'bonnet') then return 'hood_first' end
        if not VPChopHasTool(v.src, true) then return 'no_screwdriver' end
    end,
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
    validate  = function(v)
        if not VPChopAdvancedState.wasRemoved(v.sessionId, 'adv_engine') then return 'engine_first' end
        if not VPChopWelderNearVehicle(v.netId) then return 'no_welder_adv' end
    end,
})
ActionSession.RegisterExecutor('adv_carcass', function(act)
    if type(VPChopAdvCarcassCommit) ~= 'function' then return { ok = false, err = 'internal' } end
    local r = VPChopAdvCarcassCommit(act.src, act.netId, act.sessionId)
    if not r.ok then return { ok = false, err = r.err or 'domain' } end
    return { ok = true, result = { phase = 4, part = 'adv_carcass' } }
end)
