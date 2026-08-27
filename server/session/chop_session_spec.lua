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
-- FAKE[netId] = { model, plate, mark }  — `mark` simula o state bag server-local
-- da entidade (morre com a entidade → despawnFake limpa).
local FAKE = {}
-- Comportamento do state bag simulado p/ testar o fix #7 (write + readback):
--   'ok'             → set + readback batem
--   'set_error'      → :set lança → tag=false
--   'readback_nil'   → :set não lança mas o valor não fica legível
--   'readback_wrong' → readback devolve outro valor
local MARKER_BEHAVIOR = 'ok'
ChopSession._test.setEntityAPI({
    get    = function(netId) return FAKE[netId] and (netId + 100000) or 0 end,  -- "handle" fake ≠ 0
    exists = function(h) return h ~= nil and h ~= 0 end,
    model  = function(h) local n = h - 100000; return FAKE[n] and FAKE[n].model or 0 end,
    plate  = function(h) local n = h - 100000; return FAKE[n] and FAKE[n].plate or '' end,
    owned  = function() return nil end,
    tag    = function(h, vsid)
        local n = h - 100000; if not FAKE[n] then return false end
        if MARKER_BEHAVIOR == 'set_error' then return false end
        if     MARKER_BEHAVIOR == 'readback_nil'   then FAKE[n].mark = nil
        elseif MARKER_BEHAVIOR == 'readback_wrong' then FAKE[n].mark = 'other:' .. tostring(vsid)
        else                                            FAKE[n].mark = vsid end
        return FAKE[n].mark == vsid   -- espelha o readback da produção
    end,
    marker = function(h) local n = h - 100000; return FAKE[n] and FAKE[n].mark or nil end,
})
local function spawnFake(netId, model, plate) FAKE[netId] = { model = model or 111, plate = plate or 'ABC123' } end
local function despawnFake(netId) FAKE[netId] = nil end

-- Cada caso começa limpo.
local function fresh() ChopSession._test.reset(); FAKE = {}; MARKER_BEHAVIOR = 'ok' end

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
    ChopSession.SetState(sid, 'DISMANTLING'); ChopSession.SetState(sid, 'READY_FOR_DISCARD')
    check('8 Complete ok de READY_FOR_DISCARD', ChopSession.Complete(sid) == true)
    check('8 Complete de novo ok (idempotente)', ChopSession.Complete(sid) == true)
    check('8 SetState após terminal falha', (function() local o, e = ChopSession.SetState(sid, 'DISMANTLING'); return o == false and e == 'terminal' end)())
    check('8 MarkPart após terminal falha', (ChopSession.MarkPart(sid, 'wheel_lf', 1)) == false)
    check('8 MarkRaised após terminal falha', ChopSession.MarkRaised(sid, 1) == false)
    check('8 ClearRaised após terminal falha', ChopSession.ClearRaised(sid) == false)

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

    -- ═══ Follow-up da review PR#3 ═══════════════════════════════════════════════

    -- 12) CANCELLED → Create no MESMO veículo = NOVA sessão -----------------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); local oldId, oldVsid = s.id, s.vehicle.identity
    ChopSession.Cancel(s.id, 'abandoned')
    check('12 Get da cancelada → nil (lookup ativo)', ChopSession.Get(oldId) == nil)
    check('12 GetByVehicle após cancel → nil', ChopSession.GetByVehicle(10) == nil)
    local s2 = ChopSession.Create(10, 1)
    check('12 Create após cancel cunha NOVA sessão', s2 ~= nil and s2.id ~= oldId)
    check('12 novo vsid', s2 and s2.vehicle.identity ~= oldVsid)
    check('12 nova sessão ativa (CREATED)', ChopSession.Get(s2.id) ~= nil and s2.state == 'CREATED')

    -- 13) COMPLETED → Create no MESMO veículo (ainda existente) = DENY -----
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1)
    ChopSession.SetState(s.id, 'DISMANTLING'); ChopSession.SetState(s.id, 'READY_FOR_DISCARD'); ChopSession.Complete(s.id)
    check('13 Create em veículo com sessão COMPLETED → nil,completed', (function()
        local x, e = ChopSession.Create(10, 1); return x == nil and e == 'completed'
    end)())
    -- veículo original some → o slot libera e uma nova sessão pode nascer
    despawnFake(10); spawnFake(10, 111)
    check('13 após o veículo sumir, Create cunha nova', ChopSession.Create(10, 1) ~= nil)

    -- 14) requestRaise NUNCA retorna ok p/ sessão terminal ---------------
    -- (simulação do caminho do jackstand: Create + AddParticipant + MarkRaised)
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    ChopSession.SetState(sid, 'DISMANTLING'); ChopSession.SetState(sid, 'READY_FOR_DISCARD'); ChopSession.Complete(sid)
    local function simRequestRaise(netId, src)
        local sess, err = ChopSession.Create(netId, src)
        if not sess then return { ok = false, err = err } end
        if not ChopSession.AddParticipant(sess.id, src) then return { ok = false, err = 'session' } end
        if not sess.raised and not ChopSession.MarkRaised(sess.id, src) then return { ok = false, err = 'session' } end
        return { ok = true, sessionId = sess.id }
    end
    check('14 requestRaise em veículo COMPLETED → ok=false', simRequestRaise(10, 1).ok == false)
    -- cancelada: Create cunha nova → requestRaise deve dar ok=true (sessão nova, não a terminal)
    fresh(); spawnFake(20, 111)
    s = ChopSession.Create(20, 1); ChopSession.Cancel(s.id, 'x')
    local rr = simRequestRaise(20, 1)
    check('14 requestRaise após cancel → ok=true (sessão NOVA)', rr.ok == true and rr.sessionId ~= s.id)

    -- 15) Complete respeita a FSM --------------------------------------
    fresh(); spawnFake(10, 111); s = ChopSession.Create(10, 1); sid = s.id
    check('15 CREATED → Complete = DENY', (function() local o,e = ChopSession.Complete(sid); return o == false and e == 'bad_state' end)())
    ChopSession.MarkRaised(sid, 1)
    check('15 RAISED → Complete = DENY', ChopSession.Complete(sid) == false)
    ChopSession.SetState(sid, 'DISMANTLING')
    check('15 DISMANTLING → Complete = DENY', ChopSession.Complete(sid) == false)
    ChopSession.SetState(sid, 'READY_FOR_DISCARD')
    check('15 READY_FOR_DISCARD → Complete = OK', ChopSession.Complete(sid) == true)
    check('15 COMPLETED → Complete = idempotente OK', ChopSession.Complete(sid) == true)

    -- 16) non-participant requestLower = DENY --------------------------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); ChopSession.MarkRaised(s.id, 1)  -- participante = 1
    local function simRequestLower(netId, src)
        local sess = ChopSession.GetByVehicle(netId)
        if not sess then return { ok = true, stale = true } end
        if not ChopSession.HasParticipant(sess.id, src) then return { ok = false, err = 'not_participant' } end
        ChopSession.ClearRaised(sess.id); return { ok = true }
    end
    check('16 requestLower por não-participante → deny', simRequestLower(10, 999).ok == false)
    check('16 raised continua true após deny', ChopSession.IsRaised(10) == true)
    check('16 requestLower por participante → ok', simRequestLower(10, 1).ok == true and ChopSession.IsRaised(10) == false)

    -- 17) client lower deny não remove visual (contrato) --------------
    -- (o teste real é no client; aqui garantimos que o server devolve ok=false,
    --  sem stale, quando não-participante — o gatilho p/ o client MANTER o visual)
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); ChopSession.MarkRaised(s.id, 1)
    local resLower = simRequestLower(10, 42)
    check('17 deny de não-participante: ok=false E stale ausente', resLower.ok == false and resLower.stale == nil)

    -- 18) netId reuse, MESMO modelo, marcador disponível → stale -------
    fresh(); spawnFake(10, 111, 'AAA')
    s = ChopSession.Create(10, 1); sid = s.id
    check('18 marcador foi cravado no mint', s.vehicle._fp.markerSet == true)
    despawnFake(10); spawnFake(10, 111, 'BBB')      -- MESMO netId, MESMO modelo, entidade nova (sem marcador)
    check('18 Get → nil (marcador não bate)', ChopSession.Get(sid) == nil)
    check('18 GetByVehicle(10) → nil', ChopSession.GetByVehicle(10) == nil)

    -- 19) fallback: :set falha (runtime não suporta state bag server-local) ---
    fresh(); MARKER_BEHAVIOR = 'set_error'; spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    check('19 markerSet=false quando :set falha', s.vehicle._fp.markerSet == false)
    check('19 sessão ainda válida (fallback model/ownedId)', ChopSession.Get(sid) ~= nil)
    despawnFake(10); spawnFake(10, 222)             -- modelo diferente → fallback pega
    check('19 fallback: modelo diferente → stale', ChopSession.Get(sid) == nil)

    -- ═══ Micro-fix #7: markerSet = WRITE + READBACK confirmado ═════════════════

    -- 7A) tag write + readback correto → markerSet=true --------------------
    fresh(); MARKER_BEHAVIOR = 'ok'; spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    check('7A markerSet=true com write+readback ok', s.vehicle._fp.markerSet == true)
    check('7A sessão válida', ChopSession.Get(sid) ~= nil)

    -- 7B) :set não lança mas readback = nil → markerSet=false, fallback vale --
    fresh(); MARKER_BEHAVIOR = 'readback_nil'; spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    check('7B markerSet=false quando readback é nil', s.vehicle._fp.markerSet == false)
    check('7B sessão continua válida pelo fallback', ChopSession.Get(sid) ~= nil)
    despawnFake(10); spawnFake(10, 111)            -- MESMO modelo: sem marcador confiável, fallback NÃO pega
    check('7B mesmo modelo sem marcador → sessão sobrevive (fallback não distingue)', ChopSession.Get(sid) ~= nil)
    despawnFake(10); spawnFake(10, 333)            -- modelo diferente → fallback pega
    check('7B modelo diferente → stale', ChopSession.Get(sid) == nil)

    -- 7C) readback retorna VSID diferente → markerSet=false no mint --------
    fresh(); MARKER_BEHAVIOR = 'readback_wrong'; spawnFake(10, 111)
    s = ChopSession.Create(10, 1)
    check('7C markerSet=false quando readback difere', s.vehicle._fp.markerSet == false)
    check('7C sessão válida pelo fallback', ChopSession.Get(s.id) ~= nil)

    -- 7D) markerSet=true e o marcador muda depois → sessão stale ----------
    fresh(); MARKER_BEHAVIOR = 'ok'; spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    check('7D markerSet=true', s.vehicle._fp.markerSet == true)
    FAKE[10].mark = 'vsid:tampered'                -- alguém sobrescreveu o marcador
    check('7D marcador adulterado → Get = nil', ChopSession.Get(sid) == nil)

    -- 20) sweeper: sessão ATIVA inativa > timeout → CANCELLED ---------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    ChopSession._test.setIdle(sid, 16 * 60)   -- > SessionTimeoutMs (15 min)
    ChopSession._test.sweep()
    check('20 sessão inativa cancelada pelo sweeper', ChopSession._test._sessions()[sid].state == 'CANCELLED')
    check('20 Get da cancelada → nil', ChopSession.Get(sid) == nil)

    -- 21) sweeper: sessão TERMINAL idle > retenção → coletada -------
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    ChopSession.Cancel(sid, 'x')
    ChopSession._test.setIdle(sid, 120)       -- > 60s de retenção terminal
    ChopSession._test.sweep()
    check('21 sessão terminal coletada de Sessions', ChopSession._test._sessions()[sid] == nil)
    check('21 índice reverso limpo', ChopSession.GetByVehicle(10) == nil)
    check('21 Create após coleta cunha nova (mesmo veículo)', ChopSession.Create(10, 1) ~= nil)

    -- 22) sweeper: sessão ATIVA cujo veículo sumiu → CleanupVehicle --
    fresh(); spawnFake(10, 111)
    s = ChopSession.Create(10, 1); sid = s.id
    despawnFake(10)
    ChopSession._test.sweep()
    check('22 sessão de veículo sumido removida pelo sweeper', ChopSession._test._sessions()[sid] == nil)

    print(('[ChopSession/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then
        print('[ChopSession/spec] \27[31mHÁ FALHAS — não avançar a migração.\27[0m')
    end
end)
