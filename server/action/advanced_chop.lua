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
--  [v1.16 P1.5 / FASE E] O `validate` de cada kind (roda no START e na revalidação
--  do COMPLETE) é DERIVADO DO PART REGISTRY, sem fallback hardcoded. O registry é
--  obrigatório — se não carregar, este arquivo aborta o resource (igual a
--  shared/chop_parts.lua). Mapeamento de erro idêntico ao antigo hardcode; parity
--  garantida por registry_spec + a bateria ADV-* do action_session_spec.
--    adv_door    → serra                        (registry: toolClass='cut')
--    adv_engine  → capô removido + chave de fenda (registry: requires=bonnet, toolClass='screw')
--    adv_carcass → motor removido + soldadora     (registry: requires=adv_engine, gates.welder)
--
--  Carregado DEPOIS de server/main.lua e server/advanced_chop.lua — ver fxmanifest.
-- ═══════════════════════════════════════════════════════════════════════════════

if not (ActionSession and ActionSession.RegisterKind) then return end

if not (VPChopPartRegistry and VPChopPartRegistry.get) then
    error('[vp_chopshop] server/action/advanced_chop.lua exige VPChopPartRegistry — '
        .. 'conferir a ordem no fxmanifest (shared/registry/parts.lua ANTES).')
end

-- ═══ Validação derivada do Part Registry (shared/registry/parts.lua) ══════════
--  Deriva de VPChopPartRegistry.get(action):
--    d.enabled ~= true                                              → 'part' (peça desligada)
--    requires[] → VPChopAdvancedState.wasRemoved(sessionId, part)   (hood_first / engine_first)
--    toolClass  → VPChopHasTool(src, wantDrill)                     (no_saw / no_screwdriver)
--    gates.welder→ VPChopWelderNearVehicle(netId)                   (no_welder_adv)
---@param v { src:integer, sessionId:string, netId:integer, action:string }
---@return string|nil err
local function registryValidate(v)
    local d = VPChopPartRegistry.get(v.action)
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
-- adv_door tem 2 invariantes NÃO delegados ao registryValidate genérico:
--   · guard de tipo — StartAdvanced só roteia parts door-kind p/ cá, mas o COMPLETE
--     revalida por act.action e o registryValidate não checa gtaClass;
--   · porta SEMPRE exige serra — última linha de defesa se um def door vier com
--     toolClass ausente/errado (registryValidate só checa quando toolClass=='cut').
-- adv_engine/adv_carcass dispensam ambos (kind casado por nome exato; tool/deps/welder
-- são justamente o que o registry descreve por peça).
ActionSession.RegisterKind('adv_door', {
    minDurKey = 'door',
    distance  = 6.0,
    validate  = function(v)
        if VPChopPartGtaClass(v.action) ~= 'door' then return 'part' end
        if not VPChopHasTool(v.src, false) then return 'no_saw' end
        return registryValidate(v)
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
    validate  = registryValidate,   -- requires=[bonnet] · toolClass='screw'
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
    validate  = registryValidate,   -- requires=[adv_engine] · gates.welder=true · toolClass=nil
})
ActionSession.RegisterExecutor('adv_carcass', function(act)
    if type(VPChopAdvCarcassCommit) ~= 'function' then return { ok = false, err = 'internal' } end
    local r = VPChopAdvCarcassCommit(act.src, act.netId, act.sessionId)
    if not r.ok then return { ok = false, err = r.err or 'domain' } end
    return { ok = true, result = { phase = 4, part = 'adv_carcass' } }
end)
