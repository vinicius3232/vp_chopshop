-- server/session/advanced_state_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Self-test da migração ADVANCED CHOP → ChopSession (PR-C). NÃO roda em produção.
--  Ativar: setr vp_chopshop_selftest 1
--
--  Testa VPChopAdvancedState.* + a COMPOSIÇÃO do fluxo advanced (gate → resolve →
--  wasRemoved → lock → recheck → commit → unlock) sobre a ChopSession real.
--  `simAdvFlow` espelha o commit-point dos callbacks de server/advanced_chop.lua.
--  Os callbacks completos (lib.callback + tools + rewards + PART_CHOPPED) ficam no
--  TEST_PLAN de servidor.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[advanced_state/spec] PASS  ' .. name)
    else fail = fail + 1; print('[advanced_state/spec] FAIL  ' .. name) end
end

local ENTITY_API = {
    get    = function(netId) return FAKE_VEH[netId] and (netId + 70000) or 0 end,
    exists = function(h) return h ~= nil and h ~= 0 end,
    model  = function(h) local n = (h or 0) - 70000; return FAKE_VEH[n] and FAKE_VEH[n].model or 0 end,
    plate  = function() return 'PLATE' end,
    owned  = function() return nil end,
    tag    = function(h, vsid) local n = h - 70000; if FAKE_VEH[n] then FAKE_VEH[n].mark = vsid end; return FAKE_VEH[n] and FAKE_VEH[n].mark == vsid end,
    marker = function(h) local n = h - 70000; return FAKE_VEH[n] and FAKE_VEH[n].mark or nil end,
}
local function spawn(netId, model) FAKE_VEH[netId] = { model = model or 111 } end
local function despawn(netId) FAKE_VEH[netId] = nil end
local function fresh()
    ChopSession._test.setEntityAPI(ENTITY_API)
    ChopSession._test.reset()
    for k in pairs(FAKE_VEH) do FAKE_VEH[k] = nil end
    Config.ChopSession.Enable = true
    Config.ChopSession.EnforceRaised = true
end

-- Levanta um carro pelo fluxo legítimo (Create + AddParticipant + MarkRaised).
local function legitRaise(netId, src)
    local s = ChopSession.Create(netId, src)
    if not s then return nil end
    ChopSession.AddParticipant(s.id, src); ChopSession.MarkRaised(s.id, src)
    return s
end

-- Espelha o commit-point dos callbacks adv:* (após gate, entidade e distância já OK).
-- Retorna { ok, err }.
local function simAdvFlow(src, netId, partKey, deps)
    local okS, errS, sessionId = VPChopAdvRequireRaisedSession(src, netId)
    if not okS then return { ok = false, err = errS } end
    -- (entidade/distância validadas no callback real — aqui assumidas OK)
    sessionId = sessionId or VPChopAdvancedState.ensureSession(netId, src)
    if not sessionId then return { ok = false, err = 'session' } end
    for _, dep in ipairs(deps or {}) do
        if not VPChopAdvancedState.wasRemoved(sessionId, dep.key) then return { ok = false, err = dep.err } end
    end
    if VPChopAdvancedState.wasRemoved(sessionId, partKey) then return { ok = false, err = 'done' } end
    local locked, token = VPChopAdvancedState.lockPart(sessionId, partKey)
    if not locked then return { ok = false, err = 'processing' } end
    local function done(res) VPChopAdvancedState.unlockPart(sessionId, partKey, token); return res end
    if VPChopAdvancedState.wasRemoved(sessionId, partKey) then return done({ ok = false, err = 'done' }) end
    local mOk, mDup = VPChopAdvancedState.markPart(sessionId, src, partKey)
    if not mOk then return done({ ok = false, err = 'session' }) end
    if mDup then return done({ ok = false, err = 'done' }) end
    return done({ ok = true, sessionId = sessionId })
end

CreateThread(function()
    Wait(1000)

    -- C1) base wheel + advanced bonnet → MESMA ChopSession
    fresh(); spawn(10, 111)
    legitRaise(10, 1)
    VPChopServerTryPart(1, 10, 'wheel_lf')             -- base
    local baseSid = ChopSession.GetByVehicle(10).id
    local r = simAdvFlow(1, 10, 'bonnet')
    check('C1 advanced bonnet ok', r.ok == true)
    check('C1 mesma ChopSession p/ base e advanced', r.sessionId == baseSid)

    -- C2) origin: wheel=base, bonnet=advanced
    local sess = ChopSession._test._sessions()[baseSid]
    check('C2 wheel_lf origin=base', sess.parts.wheel_lf and sess.parts.wheel_lf.origin == 'base')
    check('C2 bonnet origin=advanced', sess.parts.bonnet and sess.parts.bonnet.origin == 'advanced')

    -- C3 / C18) VPChopGetPartCount conta SÓ base
    simAdvFlow(1, 10, 'boot')                          -- +1 advanced door
    check('C3 partCount = 1 (só wheel_lf base; bonnet/boot advanced não contam)', VPChopGetPartCount(10) == 1)
    VPChopServerTryPart(1, 10, 'wheel_rf')             -- +1 base
    check('C18 advanced part não altera base-only partCount', VPChopGetPartCount(10) == 2)
    check('C18 CountParts total (base+advanced) = 4', ChopSession.CountParts(baseSid) == 4)

    -- C4) mesma advanced part 2× → done
    check('C4 bonnet de novo → done', simAdvFlow(1, 10, 'bonnet').err == 'done')

    -- C5) dois players MESMA advanced part → no máximo um commit
    fresh(); spawn(20, 111); legitRaise(20, 1); ChopSession.AddParticipant(ChopSession.GetByVehicle(20).id, 2)
    local a = simAdvFlow(1, 20, 'bonnet')
    local b = simAdvFlow(2, 20, 'bonnet')
    check('C5 um sucesso, outro done', (a.ok and not b.ok and b.err == 'done'))

    -- C6) dois players PEÇAS DIFERENTES → locks independentes
    fresh(); spawn(20, 111); legitRaise(20, 1); ChopSession.AddParticipant(ChopSession.GetByVehicle(20).id, 2)
    check('C6 A bonnet + B boot → ambos ok', simAdvFlow(1, 20, 'bonnet').ok and simAdvFlow(2, 20, 'boot').ok)

    -- C7) wrong lock token → não unlock
    fresh(); spawn(20, 111); local s7 = legitRaise(20, 1)
    local ok7, tok7 = VPChopAdvancedState.lockPart(s7.id, 'bonnet')
    check('C7 lock ok', ok7 and tok7)
    check('C7 unlock com token errado → false', VPChopAdvancedState.unlockPart(s7.id, 'bonnet', 'xxx') == false)
    check('C7 2º lock ainda recusado', (VPChopAdvancedState.lockPart(s7.id, 'bonnet')) == false)
    check('C7 unlock com token certo → true', VPChopAdvancedState.unlockPart(s7.id, 'bonnet', tok7) == true)

    -- C8/C9) bonnet → engine dependency
    fresh(); spawn(10, 111); legitRaise(10, 1)
    check('C8 engine sem bonnet → hood_first', simAdvFlow(1, 10, 'adv_engine', { { key = 'bonnet', err = 'hood_first' } }).err == 'hood_first')
    simAdvFlow(1, 10, 'bonnet')
    check('C9 engine com bonnet REMOVED → ok', simAdvFlow(1, 10, 'adv_engine', { { key = 'bonnet', err = 'hood_first' } }).ok == true)

    -- C10/C11) engine → carcass dependency
    check('C10 carcass sem engine (netId novo) → engine_first', (function()
        fresh(); spawn(11, 111); legitRaise(11, 1)
        return simAdvFlow(1, 11, 'adv_carcass', { { key = 'adv_engine', err = 'engine_first' } }).err == 'engine_first'
    end)())
    fresh(); spawn(10, 111); legitRaise(10, 1)
    simAdvFlow(1, 10, 'bonnet'); simAdvFlow(1, 10, 'adv_engine', { { key = 'bonnet', err = 'hood_first' } })
    check('C11 carcass com engine REMOVED → ok', simAdvFlow(1, 10, 'adv_carcass', { { key = 'adv_engine', err = 'engine_first' } }).ok == true)

    -- C12) EnforceRaised=true + session não-raised → DENY
    fresh(); spawn(10, 111)
    ChopSession.Create(10, 1)                          -- criada, NÃO levantada
    check('C12 não-raised → not_raised', simAdvFlow(1, 10, 'bonnet').err == 'not_raised')

    -- C13) EnforceRaised=true + não-participante → DENY
    fresh(); spawn(10, 111); legitRaise(10, 1)
    check('C13 não-participante → not_participant', simAdvFlow(999, 10, 'bonnet').err == 'not_participant')

    -- C14) EnforceRaised=false → compat funciona MAS state vai p/ ChopSession
    fresh(); spawn(10, 111)
    Config.ChopSession.EnforceRaised = false
    local r14 = simAdvFlow(1, 10, 'bonnet')            -- sem sessão prévia
    check('C14 compat: bonnet ok sem jackstand', r14.ok == true)
    check('C14 state foi p/ ChopSession (não paralelo)', ChopSession.GetByVehicle(10) ~= nil and VPChopAdvancedState.wasRemoved(ChopSession.GetByVehicle(10).id, 'bonnet'))
    check('C14 origin=advanced mesmo em compat', ChopSession._test._sessions()[ChopSession.GetByVehicle(10).id].parts.bonnet.origin == 'advanced')

    -- C15) Enable=false sobre sessão existente → advanced mutation DENY
    fresh(); spawn(10, 111); local s15 = legitRaise(10, 1)
    Config.ChopSession.Enable = false
    check('C15 markPart advanced com Enable=false → false', (VPChopAdvancedState.markPart(s15.id, 1, 'bonnet')) == false)
    check('C15 nada foi registrado', VPChopAdvancedState.wasRemoved(s15.id, 'bonnet') == false)
    -- C15b) o gate barra 'disabled' ANTES de qualquer consumo de ferramenta
    check('C15b fluxo advanced com Enable=false → disabled no gate', simAdvFlow(1, 10, 'bonnet').err == 'disabled')
    Config.ChopSession.Enable = true

    -- C17) entityRemoved → todo session state some; nenhum AdvState/AdvMutex residual
    fresh(); spawn(10, 111); legitRaise(10, 1)
    local s17 = ChopSession.GetByVehicle(10).id
    simAdvFlow(1, 10, 'bonnet'); simAdvFlow(1, 10, 'adv_engine', { { key = 'bonnet', err = 'x' } })
    despawn(10); ChopSession.CleanupVehicle(10)
    check('C17 sessão some', ChopSession._test._sessions()[s17] == nil and ChopSession.GetByVehicle(10) == nil)

    -- C20) committed advanced session → Cancel = committed DENY
    fresh(); spawn(10, 111); legitRaise(10, 1)
    local s20 = ChopSession.GetByVehicle(10).id
    simAdvFlow(1, 10, 'bonnet')
    check('C20 Cancel de sessão com peça advanced → false,committed', (function()
        local o, e = ChopSession.Cancel(s20, 'x'); return o == false and e == 'committed'
    end)())
    check('C20 bonnet continua REMOVED', VPChopAdvancedState.wasRemoved(s20, 'bonnet') == true)

    -- C16/C19: fluxo completo (rewards, inventory-full, PART_CHOPPED 1×) → TEST_PLAN de servidor.

    print(('[advanced_state/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then print('[advanced_state/spec] \27[31mHÁ FALHAS.\27[0m') end
end)
