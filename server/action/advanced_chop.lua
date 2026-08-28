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

-- ─── adv_door ────────────────────────────────────────────────────────────────
ActionSession.RegisterKind('adv_door', {
    minDurKey = 'door',
    distance  = 6.0,
    validate  = function(v)
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
