-- server/session/adv_gate_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Self-test do gate P1-1 (VPChopAdvRequireRaisedSession). NÃO roda em produção.
--  Ativar:  setr vp_chopshop_selftest 1  · Saída: [adv_gate/spec] PASS/FAIL.
--
--  Testa a COMPOSIÇÃO (sessão ativa + raised + participante + kill-switch) sobre
--  a ChopSession real. Os callbacks adv:* completos (lib.callback + tools +
--  rewards) ficam no TEST_PLAN de servidor.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[adv_gate/spec] PASS  ' .. name)
    else fail = fail + 1; print('[adv_gate/spec] FAIL  ' .. name) end
end

local FAKE = {}
local ENTITY_API = {
    get    = function(netId) return FAKE[netId] and (netId + 100000) or 0 end,
    exists = function(h) return h ~= nil and h ~= 0 end,
    model  = function(h) local n = h - 100000; return FAKE[n] and FAKE[n].model or 0 end,
    plate  = function(h) return 'AAA' end,
    owned  = function() return nil end,
    tag    = function(h, vsid) local n = h - 100000; if FAKE[n] then FAKE[n].mark = vsid end; return FAKE[n] and FAKE[n].mark == vsid end,
    marker = function(h) local n = h - 100000; return FAKE[n] and FAKE[n].mark or nil end,
}
local function spawnFake(netId, model) FAKE[netId] = { model = model or 111 } end
-- Re-instala o EntityAPI (o spec da ChopSession também o hijacka no load).
local function fresh()
    ChopSession._test.setEntityAPI(ENTITY_API)
    ChopSession._test.reset(); FAKE = {}; Config.ChopSession.EnforceRaised = true
end

-- Levanta um carro pelo fluxo legítimo (Create + AddParticipant + MarkRaised),
-- espelhando server/session/jackstand.lua requestRaise.
local function legitRaise(netId, src)
    local s = ChopSession.Create(netId, src)
    if not s then return nil end
    ChopSession.AddParticipant(s.id, src)
    ChopSession.MarkRaised(s.id, src)
    return s
end

local function gate(src, netId) local ok, err = VPChopAdvRequireRaisedSession(src, netId); return ok, err end

CreateThread(function()
    Wait(1000)

    -- 1) sem ChopSession → DENY not_raised
    fresh(); spawnFake(10, 111)
    check('1 sem sessão → DENY not_raised', (function() local o,e = gate(1, 10); return o == false and e == 'not_raised' end)())

    -- 2) sessão existe mas raised=false → DENY not_raised
    fresh(); spawnFake(10, 111)
    local s = ChopSession.Create(10, 1); ChopSession.AddParticipant(s.id, 1)   -- criada, NÃO levantada
    check('2 sessão sem raised → DENY not_raised', (function() local o,e = gate(1, 10); return o == false and e == 'not_raised' end)())

    -- 3) raised + participante correto → PASS
    fresh(); spawnFake(10, 111); legitRaise(10, 1)
    check('3 raised + participante → PASS', gate(1, 10) == true)

    -- 4) raised + jogador NÃO-participante → DENY not_participant
    fresh(); spawnFake(10, 111); legitRaise(10, 1)
    check('4 raised + não-participante → DENY not_participant', (function() local o,e = gate(999, 10); return o == false and e == 'not_participant' end)())

    -- 5) fake netId (sem sessão) → DENY
    fresh()
    check('5 netId inexistente → DENY not_raised', gate(1, 424242) == false)
    check('5 netId nil → DENY', gate(1, nil) == false)

    -- 6) sessão CANCELLED → GetByVehicle=nil → DENY
    fresh(); spawnFake(10, 111); local sc = legitRaise(10, 1)
    ChopSession.Cancel(sc.id, 'x')
    check('6 sessão CANCELLED → DENY not_raised', (function() local o,e = gate(1, 10); return o == false and e == 'not_raised' end)())

    -- 7) sessão COMPLETED → GetByVehicle=nil → DENY
    fresh(); spawnFake(10, 111); local sd = legitRaise(10, 1)
    ChopSession.SetState(sd.id, 'DISMANTLING'); ChopSession.SetState(sd.id, 'READY_FOR_DISCARD'); ChopSession.Complete(sd.id)
    check('7 sessão COMPLETED → DENY not_raised', gate(1, 10) == false)

    -- 8) lowering legítimo → próximos gates = DENY
    fresh(); spawnFake(10, 111); local sl = legitRaise(10, 1)
    check('8 antes do lower: PASS', gate(1, 10) == true)
    ChopSession.ClearRaised(sl.id)          -- espelha requestLower
    check('8 após ClearRaised: DENY not_raised', (function() local o,e = gate(1, 10); return o == false and e == 'not_raised' end)())

    -- 9) EnforceRaised=false → kill-switch: comportamento legacy (PASS sem sessão)
    fresh(); spawnFake(10, 111)
    Config.ChopSession.EnforceRaised = false
    check('9 EnforceRaised=false → PASS mesmo sem sessão (legacy)', gate(1, 10) == true)

    -- 10) dois participantes legítimos → ambos passam o gate
    fresh(); spawnFake(10, 111)
    legitRaise(10, 1)                       -- player 1 levanta
    legitRaise(10, 2)                       -- player 2 pede raise no carro já levantado → vira participante
    check('10 participante A passa', gate(1, 10) == true)
    check('10 participante B (join via requestRaise) passa', gate(2, 10) == true)
    check('10 player C (nunca pediu raise) → DENY not_participant', (function() local o,e = gate(3, 10); return o == false and e == 'not_participant' end)())

    -- 11) o GATE não tem side effect de lifecycle: chamar não renova lastActivity.
    --     Só uma ação processada (callback → ChopSession.Touch(sessionId)) renova.
    fresh(); spawnFake(10, 111)
    local s11 = legitRaise(10, 1); local id11 = s11.id
    ChopSession._test.setIdle(id11, 600)                       -- back-date 10 min
    local before = ChopSession._test._sessions()[id11].lastActivity
    local ok11, _, sid11 = VPChopAdvRequireRaisedSession(1, 10) -- gate PASS
    check('11 gate PASS devolve sessionId', ok11 == true and sid11 == id11)
    check('11 gate NÃO renovou lastActivity', ChopSession._test._sessions()[id11].lastActivity == before)
    -- gate negado (não-participante) também não toca lifecycle
    ChopSession._test.setIdle(id11, 600); before = ChopSession._test._sessions()[id11].lastActivity
    VPChopAdvRequireRaisedSession(999, 10)
    check('11 gate DENY não renovou lastActivity', ChopSession._test._sessions()[id11].lastActivity == before)
    -- só o Touch do ponto de sucesso renova
    ChopSession.Touch(sid11)
    check('11 Touch (ponto de sucesso do callback) renova lastActivity', ChopSession._test._sessions()[id11].lastActivity > before)

    print(('[adv_gate/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then print('[adv_gate/spec] \27[31mHÁ FALHAS — não avançar.\27[0m') end
end)
