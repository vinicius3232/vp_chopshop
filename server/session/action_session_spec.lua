-- server/session/action_session_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-F] Self-test da ActionSession + vertical slice BASE TYRE. NÃO roda em
--  produção (self-gated na convar vp_chopshop_selftest 1).
--
--  Testa ActionSession.* diretamente + um executor 'tyre' que espelha o domínio
--  real (VPChopChopPartCommit): VPChopServerTryPart (commit) + TyreEntitlement.Issue
--  + contadores de reward/tool/PART_CHOPPED. O fluxo completo com natives/eventos
--  (InvAdd, breakPart broadcast, ambush, evidence, alarm) fica no TEST_PLAN de servidor.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[action_session/spec] PASS  ' .. name)
    else fail = fail + 1; print('[action_session/spec] FAIL  ' .. name) end
end

-- ─── Relógio controlado ──────────────────────────────────────────────────────
local CLK = 0
ActionSession._test.setClock(function() return CLK end)

-- ─── Seam de entidade da ChopSession + ActionSession ─────────────────────────
local ENTITY_API = {
    get    = function(netId) return FAKE_VEH[netId] and (netId + 70000) or 0 end,
    exists = function(h) return h ~= nil and h ~= 0 end,
    model  = function(h) local n = (h or 0) - 70000; return FAKE_VEH[n] and FAKE_VEH[n].model or 0 end,
    plate  = function() return 'PLATE' end,
    owned  = function() return nil end,
    tag    = function(h, vsid) local n = h - 70000; if FAKE_VEH[n] then FAKE_VEH[n].mark = vsid end; return FAKE_VEH[n] and FAKE_VEH[n].mark == vsid end,
    marker = function(h) local n = h - 70000; return FAKE_VEH[n] and FAKE_VEH[n].mark or nil end,
}

-- ─── Executor 'tyre' de teste (espelha VPChopChopPartCommit) ─────────────────
local domainCalls = 0
ActionSession.RegisterExecutor('tyre', function(act)
    domainCalls = domainCalls + 1
    local okC, errC = VPChopServerTryPart(act.src, act.netId, act.action)
    if not okC then return { ok = false, err = errC } end
    _G._TOOL_CONSUMED = (_G._TOOL_CONSUMED or 0) + 1
    _G._REWARD_COUNT  = (_G._REWARD_COUNT or 0) + 1
    _G._PART_CHOPPED  = (_G._PART_CHOPPED or 0) + 1
    local s = ChopSession.GetByVehicle(act.netId)
    local teId = s and TyreEntitlement.Issue(s.id, act.src, act.action) or nil
    return { ok = true, result = { tyreEntitlementId = teId } }
end)

local function spawn(netId, model) FAKE_VEH[netId] = { model = model or 111 } end

local function fresh()
    ChopSession._test.setEntityAPI(ENTITY_API); ChopSession._test.reset()
    ActionSession._test.setEntityAPI(ENTITY_API); ActionSession._test.reset()
    TyreEntitlement._test.reset()
    for k in pairs(FAKE_VEH) do FAKE_VEH[k] = nil end
    CLK, domainCalls = 0, 0
    _G._TOOL_CONSUMED, _G._REWARD_COUNT, _G._PART_CHOPPED = 0, 0, 0
    _G.NEAR, _G.HAS_TOOL = true, true
    Config.ChopSession.Enable = true
    Config.ActionSession.Enable = true
    Config.ActionSession.RequireBaseTyres = true
end

-- Cria + levanta + participa (fluxo legítimo).
local function legitRaise(netId, src)
    local s = ChopSession.Create(netId, src)
    ChopSession.AddParticipant(s.id, src); ChopSession.MarkRaised(s.id, src)
    return s.id
end

-- Espelha o gate do callback legacy vp_chopshop:chopPart (server/main.lua).
local function legacyTyreGate(partKey)
    if Config.ActionSession and Config.ActionSession.Enable ~= false
       and Config.ActionSession.RequireBaseTyres ~= false then
        local pdef = ChopParts and ChopParts[partKey]
        if pdef and pdef.kind == 'tyre' then return 'action_required' end
    end
    return nil
end

-- START + espera minDuration + COMPLETE. Retorna o resultado do COMPLETE.
local function fullFlow(src, sid, partKey)
    local st = ActionSession.StartBaseTyre(src, sid, partKey)
    if not st.ok then return st end
    CLK = CLK + 2000
    return ActionSession.Complete(src, st.actionId), st.actionId
end

CreateThread(function()
    Wait(1000)

    -- ═══ START ══════════════════════════════════════════════════════════════
    fresh(); spawn(10, 111); local sid = legitRaise(10, 1)
    local r1 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    check('AS1 START válido → OPEN', r1.ok == true and type(r1.actionId) == 'string'
        and r1.replay ~= true and ActionSession._test._all()[r1.actionId].status == 'OPEN')

    local r2 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    check('AS2 mesmo START retry → mesmo actionId + replay', r2.ok == true and r2.replay == true and r2.actionId == r1.actionId)

    ChopSession.AddParticipant(sid, 2)
    check('AS3 outro player mesma peça → processing (LockPart)', ActionSession.StartBaseTyre(2, sid, 'wheel_lf').err == 'processing')

    fresh(); spawn(10, 111); legitRaise(10, 1)
    check('AS4 fake session → no_session', ActionSession.StartBaseTyre(1, 'cs:9999', 'wheel_lf').err == 'no_session')

    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    check('AS5 nonparticipant → not_participant', ActionSession.StartBaseTyre(999, sid, 'wheel_lf').err == 'not_participant')

    fresh(); spawn(10, 111)
    local s6 = ChopSession.Create(10, 1); ChopSession.AddParticipant(s6.id, 1)   -- NÃO levantado
    check('AS6 raised=false → not_raised', ActionSession.StartBaseTyre(1, s6.id, 'wheel_lf').err == 'not_raised')

    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    check('AS7 non-tyre (bonnet) → part', ActionSession.StartBaseTyre(1, sid, 'bonnet').err == 'part')

    fresh(); spawn(10, 111); sid = legitRaise(10, 1); _G.HAS_TOOL = false
    check('AS8 sem ferramenta → no_tool', ActionSession.StartBaseTyre(1, sid, 'wheel_lf').err == 'no_tool')

    fresh(); spawn(10, 111); sid = legitRaise(10, 1); _G.NEAR = false
    check('AS9 longe → distance', ActionSession.StartBaseTyre(1, sid, 'wheel_lf').err == 'distance')

    -- ═══ COMPLETE / TIMING ═════════════════════════════════════════════════
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    CLK = 500
    local c10 = ActionSession.Complete(1, st.actionId)
    check('AS10 COMPLETE < minDuration → too_fast', c10.err == 'too_fast' and c10.waitMs == 1000)
    check('AS10 action continua OPEN', ActionSession._test._all()[st.actionId].status == 'OPEN')

    CLK = 2000
    local c11 = ActionSession.Complete(1, st.actionId)
    check('AS11 COMPLETE após minDuration → COMPLETED', c11.ok == true and c11.replay ~= true
        and ActionSession._test._all()[st.actionId].status == 'COMPLETED')
    local dc = domainCalls
    local c12 = ActionSession.Complete(1, st.actionId)
    check('AS12 2º COMPLETE → replay=true', c12.ok == true and c12.replay == true)
    check('AS13 2º COMPLETE NÃO repete domain commit', domainCalls == dc)
    check('AS14 src diferente → owner', ActionSession.Complete(2, st.actionId).err == 'owner')

    -- AS15 expired
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st15 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    CLK = st15.expiresAt + 1
    check('AS15 expired → err', ActionSession.Complete(1, st15.actionId).err == 'expired')
    check('AS15 action EXPIRED + lock liberado', ActionSession._test._all()[st15.actionId].status == 'EXPIRED'
        and (ChopSession.LockPart(sid, 'wheel_lf')) == true)

    -- AS16 cancel
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st16 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    check('AS16 cancel → CANCELLED + unlock', ActionSession.Cancel(1, st16.actionId).ok == true
        and ActionSession._test._all()[st16.actionId].status == 'CANCELLED'
        and (ChopSession.LockPart(sid, 'wheel_lf')) == true)

    -- AS17 disconnect
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st17 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    ActionSession.CleanupPlayer(1)
    check('AS17 disconnect → CANCELLED + unlock', ActionSession._test._all()[st17.actionId].status == 'CANCELLED'
        and (ChopSession.LockPart(sid, 'wheel_lf')) == true)

    -- AS18 session desaparece
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st18 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    FAKE_VEH[10] = nil; ChopSession.CleanupVehicle(10)
    ActionSession._test.sweep()
    check('AS18 ChopSession sumiu → action FAILED (session_gone)',
        ActionSession._test._all()[st18.actionId].status == 'FAILED')

    -- AS19 READY_FOR_DISCARD (freeze) durante action OPEN
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st19 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    CLK = 2000
    ChopSession.SetState(sid, 'DISMANTLING'); ChopSession.SetState(sid, 'READY_FOR_DISCARD')
    check('AS19 READY_FOR_DISCARD → complete deny discarding', ActionSession.Complete(1, st19.actionId).err == 'discarding')
    check('AS19 action fechada + unlock', ActionSession._test._all()[st19.actionId].status ~= 'OPEN')

    -- AS22 · UMA action OPEN por jogador (retry com partKey diferente → busy)
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st22 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    check('AS22 start OK', st22.ok == true)
    check('AS22 2ª peça enquanto a 1ª OPEN → busy', ActionSession.StartBaseTyre(1, sid, 'wheel_rf').err == 'busy')
    ActionSession.Cancel(1, st22.actionId)
    check('AS22 após cancelar, 2ª peça libera', ActionSession.StartBaseTyre(1, sid, 'wheel_rf').ok == true)

    -- AS23 · TTL efetivo <= MinDuration → START recusado (misconfigured)
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    Config.ChopSession.PartLockTtlMs = 2000   -- clamp → 1000 <= minDuration 1500
    check('AS23 config ruim → misconfigured (não cria action doomed)',
        ActionSession.StartBaseTyre(1, sid, 'wheel_lf').err == 'misconfigured')
    Config.ChopSession.PartLockTtlMs = nil

    -- AS24 · backstop: action presa em COMMITTING além do máximo → sweeper destrava
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st24 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    ActionSession._test._all()[st24.actionId].status = 'COMMITTING'
    ActionSession._test._all()[st24.actionId].committingAt = 0
    CLK = 31000
    ActionSession._test.sweep()
    check('AS24 COMMITTING travado > 30s → FAILED + unlock',
        ActionSession._test._all()[st24.actionId].status == 'FAILED'
        and (ChopSession.LockPart(sid, 'wheel_lf')) == true)

    -- AS20 / AS21 legacy gate
    fresh()
    check('AS20 RequireBaseTyres=true → legacy wheel deny action_required', legacyTyreGate('wheel_lf') == 'action_required')
    check('AS20 legacy non-tyre não é barrado', legacyTyreGate('bonnet') == nil)
    Config.ActionSession.RequireBaseTyres = false
    check('AS21 RequireBaseTyres=false → legacy wheel liberado', legacyTyreGate('wheel_lf') == nil)
    Config.ActionSession.RequireBaseTyres = true

    -- ═══ VERTICAL SLICE (BASE TYRE) ═══════════════════════════════════════
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local at, atId = fullFlow(1, sid, 'wheel_lf')
    check('AT1 wheel complete → ChopSession part REMOVED', at.ok == true
        and ChopSession.GetPartState(sid, 'wheel_lf') == 'REMOVED')
    check('AT2 exatamente 1 TyreEntitlement', (function()
        local c = 0; for _ in pairs(TyreEntitlement._test._all()) do c = c + 1 end; return c == 1
    end)())
    local teId = at.result.tyreEntitlementId
    check('AT2 result carrega o tyreEntitlementId', type(teId) == 'string' and TyreEntitlement.State(teId) == 'REMOVED')

    local rc, tc, pc = _G._REWARD_COUNT, _G._TOOL_CONSUMED, _G._PART_CHOPPED
    local rep = ActionSession.Complete(1, atId)
    check('AT3 replay → mesmo entitlementId', rep.ok == true and rep.result.tyreEntitlementId == teId)
    check('AT4 replay → reward count não muda', _G._REWARD_COUNT == rc)
    check('AT5 replay → tool durability não muda 2ª vez', _G._TOOL_CONSUMED == tc)
    check('AT6 replay → PART_CHOPPED 1×', _G._PART_CHOPPED == pc and pc == 1)

    -- AT7 cancel minigame → peça não removida
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st7 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    ActionSession.Cancel(1, st7.actionId)
    check('AT7 cancel → peça NÃO removida', ChopSession.GetPartState(sid, 'wheel_lf') == nil and _G._REWARD_COUNT == 0)

    -- AT8 too_fast → peça não removida
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st8 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf'); CLK = 500
    ActionSession.Complete(1, st8.actionId)
    check('AT8 too_fast → peça NÃO removida, action OPEN', ChopSession.GetPartState(sid, 'wheel_lf') == nil
        and ActionSession._test._all()[st8.actionId].status == 'OPEN')

    -- AT9 player afasta durante UX
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st9 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf'); CLK = 2000; _G.NEAR = false
    check('AT9 afastou → complete deny distance', ActionSession.Complete(1, st9.actionId).err == 'distance')
    check('AT9 peça NÃO removida', ChopSession.GetPartState(sid, 'wheel_lf') == nil and _G._REWARD_COUNT == 0)

    -- AT10 tool removida durante UX
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st10 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf'); CLK = 2000; _G.HAS_TOOL = false
    check('AT10 tool sumiu → complete deny no_tool', ActionSession.Complete(1, st10.actionId).err == 'no_tool')

    -- AT11 outro player remove a peça antes
    fresh(); spawn(10, 111); sid = legitRaise(10, 1); ChopSession.AddParticipant(sid, 2)
    local st11 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf'); CLK = 2000
    VPChopServerTryPart(2, 10, 'wheel_lf')   -- player 2 commita a peça direto
    local c11b = ActionSession.Complete(1, st11.actionId)
    check('AT11 peça já removida → complete deny done', c11b.err == 'done')
    check('AT11 sem reward do fluxo do player 1', _G._REWARD_COUNT == 0)

    -- AT12 discard freeze durante UX
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local st12 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf'); CLK = 2000
    ChopSession.SetState(sid, 'DISMANTLING'); ChopSession.SetState(sid, 'READY_FOR_DISCARD')
    check('AT12 discard freeze → complete deny discarding', ActionSession.Complete(1, st12.actionId).err == 'discarding')

    -- AT13 entitlement response loss → replay mesmo id
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local at13, at13Id = fullFlow(1, sid, 'wheel_lf')
    local rep13 = ActionSession.Complete(1, at13Id)
    check('AT13 response loss → replay mesmo entitlementId',
        rep13.ok == true and rep13.result.tyreEntitlementId == at13.result.tyreEntitlementId)

    -- ═══ TTL vs PartLock ═══════════════════════════════════════════════════
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    Config.ChopSession.PartLockTtlMs = 20000   -- ActionTtlMs (45000) >= 20000 → clamp
    local st20 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    check('CLAMP ActionTtl clampado abaixo do PartLockTtl', (st20.expiresAt - st20.startedAt) < 20000)
    Config.ChopSession.PartLockTtlMs = nil

    print(('[action_session/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then print('[action_session/spec] \27[31mHÁ FALHAS.\27[0m') end
end)
