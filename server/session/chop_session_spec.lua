-- server/session/chop_session_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Self-test da ChopSession. NÃO roda em produção.
--  Ativar:  setr vp_chopshop_selftest 1   (server.cfg) e reiniciar o resource.
--  Saída:   [ChopSession/spec] PASS/FAIL por caso + resumo no console do servidor.
--
--  Cobre a lógica pura (sem OneSync) via o seam ChopSession._test:
--  veículos falsos, reset entre casos. Os cenários de segurança pedidos na
--  revisão que dependem de servidor real (timeout do sweeper, 4-player, resmon)
--  ficam no TEST_PLAN — aqui vai o que é determinístico.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then
        pass = pass + 1
        print(('[ChopSession/spec] PASS  %s'):format(name))
    else
        fail = fail + 1
        print(('[ChopSession/spec] FAIL  %s'):format(name))
    end
end

-- ─── Mundo falso ──────────────────────────────────────────────────────────────
local FAKE = {}  ---@type table<integer, {model:integer, plate:string}|nil>
ChopSession._test.setEntityAPI({
    get    = function(netId) return FAKE[netId] and (netId + 100000) or 0 end,  -- "handle" fake ≠ 0
    exists = function(h) return h ~= nil and h ~= 0 end,
    model  = function(h) local n = h - 100000; return FAKE[n] and FAKE[n].model or 0 end,
    plate  = function(h) local n = h - 100000; return FAKE[n] and FAKE[n].plate or '' end,
    owned  = function() return nil end,
})
local function spawnFake(netId, model, plate) FAKE[netId] = { model = model or 111, plate = plate or 'ABC123' } end
local function despawnFake(netId) FAKE[netId] = nil end

-- Cada caso começa limpo.
local function fresh() ChopSession._test.reset(); FAKE = {} end

CreateThread(function()
    Wait(1500)  -- deixa o resource assentar

    -- 1) Create idempotente por netId + retry de callback ----------------------
    fresh(); spawnFake(10, 111)
    local a = ChopSession.Create(10, 1)
    local b = ChopSession.Create(10, 1)
    check('1 Create idempotente (mesmo netId → mesma sessão)', a and b and a.id == b.id)
    check('1 Create sem veículo → nil,vehicle', (function() local s, e = ChopSession.Create(99, 1); return s == nil and e == 'vehicle' end)())

    -- 2) MarkPart idempotente: mesma roda 2× ---------------------------------
    fresh(); spawnFake(10, 111)
    local s = ChopSession.Create(10, 1)
    local ok1, dup1 = ChopSession.MarkPart(s.id, 'wheel_lf', 1)
    local ok2, dup2 = ChopSession.MarkPart(s.id, 'wheel_lf', 1)
    check('2 MarkPart 1ª vez → ok, não-dup', ok1 and not dup1)
    check('2 MarkPart 2ª vez (mesma roda) → ok, dup=true, sem duplicar', ok2 and dup2)
    check('2 estado da peça = REMOVED', ChopSession.GetPartState(s.id, 'wheel_lf') == 'REMOVED')

    -- 3) LockPart: dois players na MESMA roda -------------------------------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1)
    ChopSession.AddParticipant(s.id, 2)
    local lockA, tokA = ChopSession.LockPart(s.id, 'wheel_rf')
    local lockB, tokB = ChopSession.LockPart(s.id, 'wheel_rf')
    check('3 player A trava a roda', lockA and tokA)
    check('3 player B é recusado enquanto travada', lockB == false)
    check('3 unlock com token errado falha', ChopSession.UnlockPart(s.id, 'wheel_rf', 'x') == false)
    check('3 unlock com token certo ok', ChopSession.UnlockPart(s.id, 'wheel_rf', tokA) == true)
    check('3 B consegue travar após release', (ChopSession.LockPart(s.id, 'wheel_rf')) == true)

    -- 4) Dois players, PARTES diferentes -----------------------------------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); ChopSession.AddParticipant(s.id, 2)
    local okL = ChopSession.MarkPart(s.id, 'wheel_lf', 1)
    local okR = ChopSession.MarkPart(s.id, 'wheel_rf', 2)
    check('4 ambas as peças distintas marcadas', okL and okR
        and ChopSession.GetPartState(s.id, 'wheel_lf') == 'REMOVED'
        and ChopSession.GetPartState(s.id, 'wheel_rf') == 'REMOVED')

    -- 5) netId REUTILIZADO noutro modelo → sessão stale --------------------
    fresh(); spawnFake(10, 111, 'OLD111')
    s = ChopSession.Create(10, 1)
    local sid = s.id
    despawnFake(10); spawnFake(10, 222, 'NEW222')     -- mesmo netId, outro veículo
    check('5 Get devolve nil (modelo diferente → reciclado)', ChopSession.Get(sid) == nil)
    check('5 GetByVehicle(10) também nil', ChopSession.GetByVehicle(10) == nil)
    check('5 índice reverso limpo', ChopSession._test._sessions()[sid] == nil)

    -- 6) Veículo REMOVIDO → cleanup --------------------------------------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    despawnFake(10)
    ChopSession.CleanupVehicle(10)
    check('6 sessão removida após CleanupVehicle', ChopSession.Get(sid) == nil and ChopSession.GetByVehicle(10) == nil)

    -- 7) Player DISCONNECT: sessão sobrevive se resta participante --------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); ChopSession.AddParticipant(s.id, 2); sid = s.id
    ChopSession.CleanupPlayer(1)       -- startedBy sai
    local still = ChopSession.Get(sid)
    check('7 sessão viva com participante restante', still ~= nil and still.state ~= 'CANCELLED')
    check('7 startedBy reatribuído ao restante', still and still.startedBy == 2)
    check('7 player que saiu removido dos participantes', still and still.participants[1] == nil)
    ChopSession.CleanupPlayer(2)       -- último sai
    local sAfter = ChopSession._test._sessions()[sid]
    check('7 sessão cancelada quando fica vazia', sAfter and sAfter.state == 'CANCELLED')

    -- 8) Estados terminais: Complete/Cancel idempotentes + bloqueiam -----
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    check('8 Complete ok', ChopSession.Complete(sid) == true)
    check('8 Complete de novo ok (idempotente)', ChopSession.Complete(sid) == true)
    check('8 SetState após terminal falha', (function() local o, e = ChopSession.SetState(sid, 'DISMANTLING'); return o == false and e == 'terminal' end)())
    check('8 MarkPart após terminal falha', (ChopSession.MarkPart(sid, 'wheel_lf', 1)) == false)
    check('8 MarkRaised após terminal falha', ChopSession.MarkRaised(sid, 1) == false)

    -- 9) Transições de estado ------------------------------------------
    check('9 CREATED→RAISED ok', ChopSession.CanTransition('CREATED', 'RAISED'))
    check('9 CREATED→COMPLETED bloqueado', not ChopSession.CanTransition('CREATED', 'COMPLETED'))
    check('9 COMPLETED→qualquer bloqueado', not ChopSession.CanTransition('COMPLETED', 'DISMANTLING'))
    check('9 estado desconhecido bloqueado', not ChopSession.CanTransition('CREATED', 'BOGUS'))

    -- 10) Jackstand: raised autoritativo + retry ---------------------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    check('10 IsRaised falso por padrão', ChopSession.IsRaised(10) == false)
    ChopSession.MarkRaised(sid, 1)
    check('10 IsRaised true após MarkRaised', ChopSession.IsRaised(10) == true)
    check('10 estado foi p/ RAISED', ChopSession.Get(sid).state == 'RAISED')
    ChopSession.MarkRaised(sid, 1)   -- retry
    check('10 MarkRaised repetido não quebra', ChopSession.IsRaised(10) == true)
    ChopSession.ClearRaised(sid)
    check('10 ClearRaised → IsRaised false + estado DISMANTLING', ChopSession.IsRaised(10) == false and ChopSession.Get(sid).state == 'DISMANTLING')

    -- 11) MarkPart avança CREATED→DISMANTLING ----------------------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1)
    ChopSession.MarkPart(s.id, 'bonnet', 1)
    check('11 1ª peça leva a sessão p/ DISMANTLING', ChopSession.Get(s.id).state == 'DISMANTLING')

    print(('[ChopSession/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then
        print('[ChopSession/spec] \27[31mHÁ FALHAS — não avançar a migração.\27[0m')
    end
end)
