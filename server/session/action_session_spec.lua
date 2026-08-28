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

-- override do welder check (real usa vetores CFX que o harness não tem)
_G.WELDER_NEAR = true
_G.VPChopWelderNearVehicle = function() return _G.WELDER_NEAR ~= false end

local function fresh()
    ChopSession._test.setEntityAPI(ENTITY_API); ChopSession._test.reset()
    ActionSession._test.setEntityAPI(ENTITY_API); ActionSession._test.reset()
    TyreEntitlement._test.reset()
    for k in pairs(FAKE_VEH) do FAKE_VEH[k] = nil end
    CLK, domainCalls = 0, 0
    _G._TOOL_CONSUMED, _G._REWARD_COUNT, _G._PART_CHOPPED = 0, 0, 0
    _G.NEAR, _G.HAS_TOOL, _G.HAS_DRILL, _G.WELDER_NEAR = true, true, true, true
    _G._ADV_REWARD = 0
    _G.ServerWelders = {}
    Config.ChopSession.Enable = true
    Config.ChopSession.PartLockTtlMs = nil
    Config.ActionSession.Enable = true
    Config.ActionSession.RequireBaseTyres = true
    Config.ActionSession.RequireAdvanced = true
    Config.AdvancedChop.Enable = true
    if VPChopAdv_test then VPChopAdv_test.clearCooldown() end
end

-- helper advanced: START + espera minDuration + COMPLETE via a rota real (StartAdvanced)
local function advFlow(src, sid, action)
    local st = ActionSession.StartAdvanced(src, sid, action)
    if not st.ok then return st end
    CLK = CLK + 3000
    return ActionSession.Complete(src, st.actionId), st.actionId
end

-- espelha o gate legacy adv:* (server/advanced_chop.lua → advActionRequired = predicate)
local function legacyAdvGate()
    return VPChopActionModeAdvanced() and 'action_required' or nil
end

-- Cria + levanta + participa (fluxo legítimo).
local function legitRaise(netId, src)
    local s = ChopSession.Create(netId, src)
    ChopSession.AddParticipant(s.id, src); ChopSession.MarkRaised(s.id, src)
    return s.id
end

-- Espelha o gate do callback legacy vp_chopshop:chopPart (server/main.lua).
local function legacyTyreGate(partKey)
    if VPChopActionModeTyre() then
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

    -- AS-C1 · COMMITTING preso além de PartLockTtl + COMMIT_MAX_MS → FAIL-CLOSED:
    -- continua COMMITTING, commitStalled=true, lock ocupado, outro player → processing
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    Config.ChopSession.PartLockTtlMs = 5000
    local stC1 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    -- simula entrada em COMMITTING (com pin, como no fluxo real)
    ChopSession.PinPartLock(sid, 'wheel_lf', stC1.actionId and ActionSession._test._all()[stC1.actionId].lockToken)
    ActionSession._test._all()[stC1.actionId].status = 'COMMITTING'
    ActionSession._test._all()[stC1.actionId].committingAt = 0
    CLK = 5000 + 61000
    ActionSession._test.sweep()
    check('AS-C1 stall → continua COMMITTING (NÃO libera)', ActionSession._test._all()[stC1.actionId].status == 'COMMITTING')
    check('AS-C1 commitStalled=true', ActionSession._test._all()[stC1.actionId].commitStalled == true)
    check('AS-C1 lock ainda ocupado (pinned, além do TTL)', (ChopSession.LockPart(sid, 'wheel_lf')) == false)
    ChopSession.AddParticipant(sid, 2)
    check('AS-C1 outro player mesma peça → processing', ActionSession.StartBaseTyre(2, sid, 'wheel_lf').err == 'processing')

    -- AS-C2 · mesmo src tenta outra peça enquanto a 1ª COMMITTING → busy
    check('AS-C2 src ocupado em COMMITTING → busy p/ outra peça', ActionSession.StartBaseTyre(1, sid, 'wheel_rf').err == 'busy')

    -- AS-C3 · executor volta depois do stall → COMPLETED 1×, lock liberado, replay
    local realTok = ActionSession._test._all()[stC1.actionId].lockToken
    ChopSession.UnlockPart(sid, 'wheel_lf', realTok)   -- simula releaseAction(COMPLETED) do executor
    ActionSession._test._all()[stC1.actionId].status = 'COMPLETED'
    ActionSession._test._all()[stC1.actionId].result = { tyreEntitlementId = 'te:x' }
    ActionSession._test._all()[stC1.actionId].terminalAt = CLK
    check('AS-C3 lock liberado no terminal', (ChopSession.LockPart(sid, 'wheel_lf')) == true)
    check('AS-C3 replay do COMPLETE → mesmo result', ActionSession.Complete(1, stC1.actionId).result.tyreEntitlementId == 'te:x')
    Config.ChopSession.PartLockTtlMs = nil

    -- AS-C4 · PinPartLock com token errado → false, lock original intacto
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local stC4 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    check('AS-C4 PinPartLock token errado → false', ChopSession.PinPartLock(sid, 'wheel_lf', 'xxx') == false)
    check('AS-C4 lock original ainda válido (destrava com token certo)',
        ChopSession.UnlockPart(sid, 'wheel_lf', ActionSession._test._all()[stC4.actionId].lockToken) == true)

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

    -- ═══ ADVANCED (PR-G) ══════════════════════════════════════════════════════
    -- ADV1 · door START válido → OPEN kind=adv_door
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local a1 = ActionSession.StartAdvanced(1, sid, 'bonnet')
    check('ADV1 door START → OPEN', a1.ok == true
        and ActionSession._test._all()[a1.actionId].kind == 'adv_door')

    -- ADV2 · door COMPLETE → peça REMOVED (origin advanced) + reward
    local r2 = ActionSession.Complete(1, a1.actionId)  -- CLK ainda 0 → too_fast
    CLK = 2000
    r2 = ActionSession.Complete(1, a1.actionId)
    check('ADV2 door COMPLETE ok', r2.ok == true)
    check('ADV2 bonnet REMOVED (advanced)', ChopSession.GetPartState(sid, 'bonnet') == 'REMOVED'
        and ChopSession.GetPartOrigin(sid, 'bonnet') == 'advanced')
    check('ADV2 reward dado 1×', _G._ADV_REWARD == 1)
    check('ADV2 PART_CHOPPED emitido', (function()
        for _, e in ipairs(_TRIGGERED) do
            if e.evt == VPChopEvt.PART_CHOPPED and e.args[3] == 'bonnet' and e.args[4] == 2 then return true end
        end
        return false
    end)())

    -- ADV3 · door replay → sem repetir reward / commit
    local dc3 = _G._ADV_REWARD
    local rep3 = ActionSession.Complete(1, a1.actionId)
    check('ADV3 replay → mesmo ok, sem repetir reward', rep3.ok == true and rep3.replay == true and _G._ADV_REWARD == dc3)

    -- ADV4 · engine START sem bonnet → hood_first
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    check('ADV4 engine sem capô → hood_first', ActionSession.StartAdvanced(1, sid, 'adv_engine').err == 'hood_first')

    -- ADV5 · engine com bonnet removido → START + COMPLETE ok
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    ChopSession.MarkPart(sid, 'bonnet', 1, { origin = 'advanced' })
    local a5, a5Id = advFlow(1, sid, 'adv_engine')
    check('ADV5 engine com capô → COMPLETE ok', a5.ok == true and ChopSession.GetPartState(sid, 'adv_engine') == 'REMOVED')

    -- ADV6 · carcass sem engine → engine_first
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    check('ADV6 carcass sem motor → engine_first', ActionSession.StartAdvanced(1, sid, 'adv_carcass').err == 'engine_first')

    -- ADV7 · carcass com engine mas SEM welder → no_welder_adv
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    ChopSession.MarkPart(sid, 'bonnet', 1, { origin = 'advanced' })
    ChopSession.MarkPart(sid, 'adv_engine', 1, { origin = 'advanced' })
    _G.WELDER_NEAR = false
    check('ADV7 carcass sem welder → no_welder_adv', ActionSession.StartAdvanced(1, sid, 'adv_carcass').err == 'no_welder_adv')
    _G.WELDER_NEAR = true

    -- ADV8 · carcass com engine + welder → COMPLETE ok
    local a8, a8Id = advFlow(1, sid, 'adv_carcass')
    check('ADV8 carcass com engine+welder → ok', a8.ok == true and ChopSession.GetPartState(sid, 'adv_carcass') == 'REMOVED')

    -- ADV9 · door sem serra → no_saw
    fresh(); spawn(10, 111); sid = legitRaise(10, 1); _G.HAS_TOOL = false
    check('ADV9 door sem serra → no_saw', ActionSession.StartAdvanced(1, sid, 'boot').err == 'no_saw')

    -- ADV10 · engine sem chave de fenda (tem serra) → no_screwdriver
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    ChopSession.MarkPart(sid, 'bonnet', 1, { origin = 'advanced' })
    _G.HAS_DRILL = false
    check('ADV10 engine sem chave → no_screwdriver', ActionSession.StartAdvanced(1, sid, 'adv_engine').err == 'no_screwdriver')

    -- ADV11 · tool sumiu DURANTE a UX → complete deny
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local a11 = ActionSession.StartAdvanced(1, sid, 'bonnet')
    CLK = 2000; _G.HAS_TOOL = false
    check('ADV11 serra sumiu no COMPLETE → no_saw', ActionSession.Complete(1, a11.actionId).err == 'no_saw')
    check('ADV11 bonnet NÃO removido', ChopSession.GetPartState(sid, 'bonnet') == nil and _G._ADV_REWARD == 0)

    -- ADV12 · dependência revalidada no COMPLETE: capô re-colocado? (n/a) — mas outro
    -- player remove adv_engine antes → carcass complete deny done
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    ChopSession.MarkPart(sid, 'bonnet', 1, { origin = 'advanced' })
    ChopSession.MarkPart(sid, 'adv_engine', 1, { origin = 'advanced' })
    local a12 = ActionSession.StartAdvanced(1, sid, 'adv_carcass'); CLK = 3000
    ChopSession.MarkPart(sid, 'adv_carcass', 2, { origin = 'advanced' })   -- outro player
    check('ADV12 peça já removida → done', ActionSession.Complete(1, a12.actionId).err == 'done')

    -- ADV13 · legacy adv:* gate quando RequireAdvanced=true
    fresh()
    check('ADV13 RequireAdvanced=true → legacy adv deny action_required', legacyAdvGate() == 'action_required')
    Config.ActionSession.RequireAdvanced = false
    check('ADV13 RequireAdvanced=false → legacy adv liberado', legacyAdvGate() == nil)
    Config.ActionSession.RequireAdvanced = true

    -- ADV14 · 1 action OPEN por jogador cobre tyre + advanced juntos
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    ActionSession.StartAdvanced(1, sid, 'bonnet')
    check('ADV14 door OPEN → tyre START do mesmo jogador → busy', ActionSession.StartBaseTyre(1, sid, 'wheel_lf').err == 'busy')

    -- ADV15 · router do callback: bonnet → StartAdvanced (kind adv_door), não tyre
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local a15 = ActionSession.StartAdvanced(1, sid, 'door_dside_f')
    check('ADV15 door_dside_f → adv_door', a15.ok == true and ActionSession._test._all()[a15.actionId].kind == 'adv_door')

    -- ADV16 · AdvCooldown (3s) preservado: completar door → START imediato → processing
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    local a16 = ActionSession.StartAdvanced(1, sid, 'bonnet'); CLK = CLK + 2000
    check('ADV16 door completou', ActionSession.Complete(1, a16.actionId).ok == true)
    check('ADV16 START advanced imediato → processing (cooldown)', ActionSession.StartAdvanced(1, sid, 'boot').err == 'processing')

    -- ═══ [P1.4 / FASE D] TODAS as peças avançadas validam via Part Registry ══════
    -- Paridade byte-a-byte com o hardcode legado — a bateria ADV1..ADV16 já cobre
    -- adv_door/adv_engine/adv_carcass; estes ADV-D fixam os casos novos.
    -- ADV-D1 · bonnet sem serra → no_saw (registry toolClass='cut'). Antes só `boot`.
    fresh(); spawn(10, 111); sid = legitRaise(10, 1); _G.HAS_TOOL = false
    check('ADV-D1 bonnet sem serra → no_saw (registry)', ActionSession.StartAdvanced(1, sid, 'bonnet').err == 'no_saw')
    _G.HAS_TOOL = true

    -- ADV-D2 · door_pside_r (variante que nunca teve teste dedicado) → no_saw via registry
    fresh(); spawn(10, 111); sid = legitRaise(10, 1); _G.HAS_TOOL = false
    check('ADV-D2 door_pside_r sem serra → no_saw (registry)', ActionSession.StartAdvanced(1, sid, 'door_pside_r').err == 'no_saw')
    _G.HAS_TOOL = true

    -- ADV-D3 · adv_engine via registry: sem bonnet → hood_first (requires=[bonnet])
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    check('ADV-D3 adv_engine sem capô → hood_first (registry)', ActionSession.StartAdvanced(1, sid, 'adv_engine').err == 'hood_first')

    -- ADV-D4 · adv_carcass via registry: engine ok mas sem welder → no_welder_adv (gates.welder)
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    ChopSession.MarkPart(sid, 'bonnet', 1, { origin = 'advanced' })
    ChopSession.MarkPart(sid, 'adv_engine', 1, { origin = 'advanced' })
    _G.WELDER_NEAR = false
    check('ADV-D4 adv_carcass sem welder → no_welder_adv (registry)', ActionSession.StartAdvanced(1, sid, 'adv_carcass').err == 'no_welder_adv')
    _G.WELDER_NEAR = true

    -- ADV-D5 · registry OFF p/ adv_engine → fallback hardcode ainda dá hood_first
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    VPChopPartRegistry.defs.adv_engine.enabled = false
    check('ADV-D5 registry OFF → adv_engine fallback → hood_first',
        ActionSession.StartAdvanced(1, sid, 'adv_engine').err == 'hood_first')
    VPChopPartRegistry.defs.adv_engine.enabled = true

    -- ADV-D6 · registry OFF p/ bonnet → fallback hardcode → START ok
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    VPChopPartRegistry.defs.bonnet.enabled = false
    local ad6 = ActionSession.StartAdvanced(1, sid, 'bonnet')
    check('ADV-D6 registry OFF → bonnet fallback → START ok',
        ad6.ok == true and ActionSession._test._all()[ad6.actionId].kind == 'adv_door')
    VPChopPartRegistry.defs.bonnet.enabled = true

    -- ═══ RATE-LIMIT REAL (500ms) NÃO QUEBRA REPLAY ════════════════════════════
    Config.ActionSession.StartRateLimitMs = 500
    Config.ActionSession.CompleteRateLimitMs = 500

    -- AS-R1 · START válido t=0 + MESMO START t=0 → mesmo actionId, replay, NÃO processing
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    Config.ActionSession.StartRateLimitMs = 500
    Config.ActionSession.CompleteRateLimitMs = 500
    CLK = 0
    local rr1 = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    local rr1b = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')   -- <500ms
    check('AS-R1 retry idêntico <500ms → replay, NÃO processing',
        rr1b.ok == true and rr1b.replay == true and rr1b.actionId == rr1.actionId)

    -- AS-R3 · COMPLETE sucesso + MESMO COMPLETE imediato → ok, replay, mesmo result
    fresh(); spawn(10, 111); sid = legitRaise(10, 1)
    Config.ActionSession.StartRateLimitMs = 500; Config.ActionSession.CompleteRateLimitMs = 500
    CLK = 0
    local rr3s = ActionSession.StartBaseTyre(1, sid, 'wheel_lf')
    CLK = 2000
    local rr3c = ActionSession.Complete(1, rr3s.actionId)
    local dcR = domainCalls
    local rr3c2 = ActionSession.Complete(1, rr3s.actionId)   -- imediato, sem avançar clock
    check('AS-R3 COMPLETE replay imediato → ok + replay', rr3c2.ok == true and rr3c2.replay == true)
    check('AS-R3 mesmo result', rr3c2.result.tyreEntitlementId == rr3c.result.tyreEntitlementId)
    check('AS-R4 replay NÃO chama executor de novo', domainCalls == dcR)
    Config.ActionSession.StartRateLimitMs = 0
    Config.ActionSession.CompleteRateLimitMs = 0

    -- ═══ EnforceRaised / kill-switch predicates ═══════════════════════════════
    -- ADV17 · EnforceRaised=true + RequireAdvanced=true → ActionSession obrigatória
    fresh()
    check('ADV17 predicate advanced = true', VPChopActionModeAdvanced() == true)
    check('ADV17 legacy adv gate = action_required', legacyAdvGate() == 'action_required')

    -- ADV18 · EnforceRaised=false → compat legacy p/ advanced
    fresh(); Config.ChopSession.EnforceRaised = false
    check('ADV18 predicate advanced = false (compat)', VPChopActionModeAdvanced() == false)
    check('ADV18 tyre predicate NÃO afetado', VPChopActionModeTyre() == true)
    spawn(10, 111); sid = legitRaise(10, 1)
    check('ADV18 StartAdvanced → action_disabled', ActionSession.StartAdvanced(1, sid, 'bonnet').err == 'action_disabled')
    Config.ChopSession.EnforceRaised = true

    -- ADV19 · RequireAdvanced=false → legacy; StartAdvanced DENY action_disabled
    fresh(); Config.ActionSession.RequireAdvanced = false
    check('ADV19 predicate advanced = false', VPChopActionModeAdvanced() == false)
    spawn(10, 111); sid = legitRaise(10, 1)
    check('ADV19 StartAdvanced → action_disabled', ActionSession.StartAdvanced(1, sid, 'bonnet').err == 'action_disabled')
    Config.ActionSession.RequireAdvanced = true

    -- ADV20 · RequireBaseTyres=false → StartBaseTyre DENY action_disabled
    fresh(); Config.ActionSession.RequireBaseTyres = false
    check('ADV20 predicate tyre = false', VPChopActionModeTyre() == false)
    spawn(10, 111); sid = legitRaise(10, 1)
    check('ADV20 StartBaseTyre → action_disabled', ActionSession.StartBaseTyre(1, sid, 'wheel_lf').err == 'action_disabled')
    check('ADV20 legacy tyre gate liberado', legacyTyreGate('wheel_lf') == nil)
    Config.ActionSession.RequireBaseTyres = true

    print(('[action_session/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then print('[action_session/spec] \27[31mHÁ FALHAS.\27[0m') end
end)
