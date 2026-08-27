-- server/session/base_state_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Self-test da migração BASE CHOP → ChopSession (PR-B). NÃO roda em produção.
--  Ativar: setr vp_chopshop_selftest 1
--
--  Exercita VPChopBaseState.* e o caminho VPChopServerTryPart de server/chop.lua
--  (que delega à fachada). Natives crus de veículo → FAKE_VEH (tools/run_spec.lua);
--  EntityAPI da ChopSession apontado p/ a MESMA tabela.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[base_state/spec] PASS  ' .. name)
    else fail = fail + 1; print('[base_state/spec] FAIL  ' .. name) end
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
end

-- conta as peças de session.parts via o snapshot público
local function sessParts(netId)
    local s = ChopSession.GetByVehicle(netId)
    if not s then return {} end
    local out = {}
    for _, e in ipairs(ChopSession.Debug().sessions[s.id].parts) do out[e] = true end
    return out
end

CreateThread(function()
    Wait(1000)

    -- B1) primeira peça: sem sessão → VPChopServerTryPart valida veículo → cria → REMOVED
    fresh(); spawn(10, 111)
    local ok, err = VPChopServerTryPart(1, 10, 'wheel_lf')
    check('B1 1ª peça: VPChopServerTryPart ok', ok == true and err == nil)
    check('B1 sessão foi criada p/ o veículo', ChopSession.GetByVehicle(10) ~= nil)
    check('B1 peça marcada REMOVED', VPChopBaseState.wasChopped(10, 'wheel_lf') == true)
    check('B1 quem criou é participante', ChopSession.HasParticipant(ChopSession.GetByVehicle(10).id, 1))

    -- B2) segunda chamada mesma peça → DENY 'done'
    local ok2, err2 = VPChopServerTryPart(1, 10, 'wheel_lf')
    check('B2 2ª vez mesma peça → err=done', ok2 == false and err2 == 'done')

    -- B3) duas peças diferentes → ambas na MESMA session.parts
    VPChopServerTryPart(1, 10, 'wheel_rf')
    local p = sessParts(10)
    check('B3 wheel_lf e wheel_rf na mesma sessão', p.wheel_lf and p.wheel_rf)

    -- B4) dois players, MESMA peça: só um sucesso (WasChopped + mutex legacy)
    fresh(); spawn(20, 111)
    local a = VPChopServerTryPart(1, 20, 'wheel_lf')
    local b = VPChopServerTryPart(2, 20, 'wheel_lf')
    check('B4 player A remove; player B recebe done', a == true and select(2, VPChopServerTryPart(2, 20, 'wheel_lf')) == 'done')
    check('B4 B nunca virou participante (não abre bypass do adv gate)', not ChopSession.HasParticipant(ChopSession.GetByVehicle(20).id, 2))

    -- B5) netId reciclado: estado antigo não aparece no veículo novo
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    despawn(10); spawn(10, 222)                       -- MESMO netId, modelo diferente
    check('B5 wasChopped no veículo novo → false', VPChopBaseState.wasChopped(10, 'wheel_lf') == false)
    check('B5 partCount do veículo novo → 0', VPChopBaseState.partCount(10) == 0)

    -- B6) partCount conta exatamente as peças base removidas
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf'); VPChopServerTryPart(1, 10, 'wheel_rf'); VPChopServerTryPart(1, 10, 'boot')
    check('B6 partCount = 3', VPChopGetPartCount(10) == 3)
    local sid7 = ChopSession.GetByVehicle(10).id

    -- B7) VPChopClearVehicle (= conclusão de discard): sessão vira COMPLETED
    -- (tombstone). Enquanto o veículo ainda existir, novo chop = DENY.
    VPChopClearVehicle(10)
    check('B7 após clear: wasChopped → false', VPChopBaseState.wasChopped(10, 'wheel_lf') == false)
    check('B7 após clear: partCount → 0 (lookup ativo nil)', VPChopGetPartCount(10) == 0)
    check('B7 GetByVehicle → nil (sessão terminal)', ChopSession.GetByVehicle(10) == nil)
    check('B7 sessão está COMPLETED (não CANCELLED)', ChopSession._test._sessions()[sid7].state == 'COMPLETED')
    check('B7 veículo AINDA vivo → novo chop = DENY completed', (function()
        local o, e = VPChopServerTryPart(1, 10, 'wheel_lf'); return o == false and e == 'completed'
    end)())
    despawn(10); ChopSession.CleanupVehicle(10); spawn(10, 111)   -- entidade morre de fato
    check('B7 após entityRemoved → novo veículo pode chopar', VPChopServerTryPart(1, 10, 'wheel_lf') == true)

    -- B8) entityRemoved: sessão não vaza p/ novo veículo no mesmo netId
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    local oldId = ChopSession.GetByVehicle(10).id
    ChopSession.CleanupVehicle(10)                    -- o que o entityRemoved da ChopSession faz
    despawn(10); spawn(10, 111)                       -- novo veículo herda o netId
    check('B8 sessão antiga não é resolvível', ChopSession.GetByVehicle(10) == nil)
    check('B8 wasChopped no novo → false', VPChopBaseState.wasChopped(10, 'wheel_lf') == false)
    local ok8 = VPChopServerTryPart(2, 10, 'wheel_lf')
    check('B8 novo chop cunha sessão nova (id diferente)', ok8 == true and ChopSession.GetByVehicle(10).id ~= oldId)

    -- B12) base part NÃO contamina estado avançado (separado por origin)
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'bonnet')             -- (Config.AdvancedChop nil no harness → base processa)
    local sp = sessParts(10)
    check('B12 só a peça base em session.parts', sp.bonnet and not sp.adv_engine and not sp.adv_carcass)

    -- B13) discard: partCount equivalente ao comportamento atual
    fresh(); spawn(10, 111)
    for _, k in ipairs({ 'wheel_lf', 'wheel_rf', 'boot', 'bonnet' }) do VPChopServerTryPart(1, 10, k) end
    check('B13 partCount = 4 (MinPartsToDiscard ainda decide igual)', VPChopGetPartCount(10) == 4)
    VPChopClearVehicle(10)
    check('B13 após discard: partCount = 0', VPChopGetPartCount(10) == 0)

    -- B14) sessão terminal não é reutilizada indevidamente
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    local sid = ChopSession.GetByVehicle(10).id
    ChopSession.SetState(sid, 'DISMANTLING'); ChopSession.SetState(sid, 'READY_FOR_DISCARD'); ChopSession.Complete(sid)
    check('B14 COMPLETED + veículo existe → base chop DENY (err=completed)', (function()
        local o, e = VPChopServerTryPart(1, 10, 'wheel_rf'); return o == false and e == 'completed'
    end)())
    despawn(10); ChopSession.CleanupVehicle(10); spawn(10, 111)   -- veículo original some
    check('B14 após veículo sumir → novo chop ok', VPChopServerTryPart(1, 10, 'wheel_rf') == true)

    -- B15) Config.ChopSession.Enable=false — master switch (não kill-switch de compat).
    fresh(); spawn(10, 111)
    Config.ChopSession.Enable = false
    check('B15 Enable=false → base chop DENY', (function()
        local o = VPChopServerTryPart(1, 10, 'wheel_lf'); return o == false
    end)())
    Config.ChopSession.Enable = true
    check('B15 Enable=true de novo → volta a funcionar', VPChopServerTryPart(1, 10, 'wheel_lf') == true)

    -- ═══ Follow-up de lifecycle (PR-B review) ═══════════════════════════════════

    -- L1) disconnect com committed state: ledger NÃO morre
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')            -- player 1 = único participante
    local lid = ChopSession.GetByVehicle(10).id
    ChopSession.CleanupPlayer(1)
    check('L1 sessão ainda resolvível após disconnect do único participante', ChopSession.GetByVehicle(10) ~= nil)
    check('L1 wheel_lf continua REMOVED', VPChopBaseState.wasChopped(10, 'wheel_lf') == true)
    check('L1 partCount continua 1', VPChopGetPartCount(10) == 1)
    check('L1 participantes vazios', ChopSession._test._sessions()[lid].participants[1] == nil and next(ChopSession._test._sessions()[lid].participants) == nil)
    check('L1 raised zerado por segurança', ChopSession._test._sessions()[lid].raised == false)
    check('L1 mesma peça continua DENY done', (function() local o,e = VPChopServerTryPart(9, 10, 'wheel_lf'); return o == false and e == 'done' end)())

    -- L2) novo player após disconnect: sem reset de veículo
    check('L2 player B, mesma peça → done', (function() local o,e = VPChopServerTryPart(2, 10, 'wheel_lf'); return o == false and e == 'done' end)())
    check('L2 player B, peça diferente válida → segue comportamento base (ok)', VPChopServerTryPart(2, 10, 'wheel_rf') == true)

    -- L3) timeout com committed state: NÃO cancela (nenhuma idade)
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    local tid = ChopSession.GetByVehicle(10).id
    ChopSession._test.setIdle(tid, 24 * 3600)          -- 24h
    ChopSession._test.sweep()
    check('L3 sessão com parts NÃO cancelada por 24h de idle (veículo vivo)', ChopSession._test._sessions()[tid].state ~= 'CANCELLED')
    check('L3 wheel_lf continua REMOVED', VPChopBaseState.wasChopped(10, 'wheel_lf') == true)

    -- L4) timeout de sessão VAZIA: cancela como antes
    fresh(); spawn(20, 111)
    local eid = ChopSession.Create(20, 1).id          -- sessão sem parts
    ChopSession._test.setIdle(eid, 999999)
    ChopSession._test.sweep()
    check('L4 sessão vazia inativa → CANCELLED', ChopSession._test._sessions()[eid].state == 'CANCELLED')

    -- L5) COMPLETED tombstone: NENHUMA idade coleta enquanto o veículo existir
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    local cid = ChopSession.GetByVehicle(10).id
    ChopSession.SetState(cid, 'DISMANTLING'); ChopSession.SetState(cid, 'READY_FOR_DISCARD'); ChopSession.Complete(cid)
    ChopSession._test.setIdle(cid, 10 * 60); ChopSession._test.sweep()     -- 10min
    check('L5 tombstone sobrevive a 10min', ChopSession._test._sessions()[cid] ~= nil)
    ChopSession._test.setIdle(cid, 24 * 3600); ChopSession._test.sweep()   -- 24h
    check('L5 tombstone sobrevive a 24h (veículo vivo, SEM TTL)', ChopSession._test._sessions()[cid] ~= nil and ChopSession._test._sessions()[cid].state == 'COMPLETED')
    check('L5 Create no netId → nil,completed (sempre)', (function() local x,e = ChopSession.Create(10, 1); return x == nil and e == 'completed' end)())

    -- L6) só entity removed / veículo inválido libera o tombstone
    despawn(10); ChopSession._test.sweep()             -- sweeper detecta veículo inválido
    check('L6 veículo inválido → tombstone coletado pelo sweeper', ChopSession._test._sessions()[cid] == nil)
    spawn(10, 111)
    check('L6 novo veículo no netId → cria sessão/VSID nova', ChopSession.Create(10, 2) ~= nil)

    -- L7) clear/discard → COMPLETED, não CANCELLED
    fresh(); spawn(10, 111)
    for _, k in ipairs({ 'wheel_lf', 'wheel_rf', 'boot', 'bonnet' }) do VPChopServerTryPart(1, 10, k) end
    local did = ChopSession.GetByVehicle(10).id
    check('L7 VPChopClearVehicle → ok', VPChopBaseState.clear(10) == true)
    check('L7 sessão = COMPLETED', ChopSession._test._sessions()[did].state == 'COMPLETED')
    check('L7 veículo ainda vivo → novo chop DENY', (function() local o = VPChopServerTryPart(1, 10, 'wheel_lr'); return o == false end)())

    -- L8) master switch em sessão EXISTENTE
    fresh(); spawn(10, 111)
    check('L8 Enable=true: wheel_lf sucesso', VPChopServerTryPart(1, 10, 'wheel_lf') == true)
    Config.ChopSession.Enable = false
    check('L8 Enable=false: wheel_rf DENY', VPChopServerTryPart(1, 10, 'wheel_rf') == false)
    Config.ChopSession.Enable = true
    check('L8 wheel_lf permanece registrado', VPChopBaseState.wasChopped(10, 'wheel_lf') == true)
    check('L8 wheel_rf NÃO foi registrado', VPChopBaseState.wasChopped(10, 'wheel_rf') == false)

    -- L9) duplicate no commit autoritativo → 'done', sem 2ª operação de sucesso
    fresh(); spawn(10, 111)
    local s9 = ChopSession.Create(10, 1)
    ChopSession.MarkPart(s9.id, 'wheel_lf', 1)        -- peça já REMOVED "por fora"
    check('L9 markPart de peça já REMOVED → ok=true, duplicate=true', (function()
        local o, d = VPChopBaseState.markPart(1, 10, 'wheel_lf'); return o == true and d == true
    end)())
    check('L9 VPChopServerTryPart da mesma peça → err=done (nunca sucesso 2×)', (function()
        local o, e = VPChopServerTryPart(1, 10, 'wheel_lf'); return o == false and e == 'done'
    end)())

    -- L10) órfã (0 participantes) COM parts + veículo válido: idade NÃO cancela.
    --      Só telemetria (OrphanWarnAfterMs). Sem TTL destrutivo.
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    local o10 = ChopSession.GetByVehicle(10).id
    ChopSession.CleanupPlayer(1)                       -- órfã
    check('L10 órfã sobrevive a CleanupPlayer (tem parts)', ChopSession._test._sessions()[o10].state == 'DISMANTLING')
    ChopSession._test.setIdle(o10, 2 * 3600)           -- 2h
    ChopSession._test.sweep()
    check('L10 órfã + 2h idle + veículo válido → sessão CONTINUA ativa', ChopSession.GetByVehicle(10) ~= nil)
    check('L10 part state permanece', VPChopBaseState.wasChopped(10, 'wheel_lf') == true)
    check('L10 mesma peça continua DENY done', (function() local o,e = VPChopServerTryPart(2, 10, 'wheel_lf'); return o == false and e == 'done' end)())
    despawn(10); ChopSession._test.sweep()             -- só o veículo sumir mata o state
    check('L10 veículo inválido → CleanupVehicle finalmente coleta', ChopSession._test._sessions()[o10] == nil)

    -- L11) has-parts COM participante, inativa muito tempo → NÃO cancela
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    local o11 = ChopSession.GetByVehicle(10).id
    ChopSession._test.setIdle(o11, 30 * 60)            -- > SessionTimeoutMs
    ChopSession._test.sweep()
    check('L11 sessão com parts + participante NÃO cancela por inatividade', ChopSession._test._sessions()[o11].state ~= 'CANCELLED')

    -- L12) tombstone COMPLETED: mantido para QUALQUER idade enquanto veículo válido
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    local o12 = ChopSession.GetByVehicle(10).id
    ChopSession.SetState(o12, 'DISMANTLING'); ChopSession.SetState(o12, 'READY_FOR_DISCARD'); ChopSession.Complete(o12)
    ChopSession._test.setIdle(o12, 10 * 60); ChopSession._test.sweep()
    check('L12 tombstone + 10min → mantido', ChopSession._test._sessions()[o12] ~= nil)
    check('L12 Create bloqueado', select(2, ChopSession.Create(10, 1)) == 'completed')
    ChopSession._test.setIdle(o12, 24 * 3600); ChopSession._test.sweep()
    check('L12 tombstone + 24h → AINDA mantido (sem TTL)', ChopSession._test._sessions()[o12] ~= nil)
    check('L12 Create ainda bloqueado após 24h', select(2, ChopSession.Create(10, 1)) == 'completed')

    -- L13) tombstone só sai quando o veículo realmente morre
    despawn(10); ChopSession._test.sweep()
    check('L13 veículo inválido → tombstone coletado', ChopSession._test._sessions()[o12] == nil)
    spawn(10, 111)
    check('L13 netId volta a receber sessão nova', ChopSession.Create(10, 2) ~= nil)

    -- ═══ Cancel não pode matar committed state (micro-fix) ═════════════════════

    -- CNL1) Create sem parts → Cancel → CANCELLED (normal)
    fresh(); spawn(10, 111)
    local c1 = ChopSession.Create(10, 1).id
    check('CNL1 Cancel de sessão sem parts → true', ChopSession.Cancel(c1, 'abandoned') == true)
    check('CNL1 estado = CANCELLED', ChopSession._test._sessions()[c1].state == 'CANCELLED')

    -- CNL2) Create + MarkPart → Cancel → (false,'committed'), nada muda
    fresh(); spawn(10, 111)
    VPChopServerTryPart(1, 10, 'wheel_lf')
    local c2 = ChopSession.GetByVehicle(10).id
    local before = { st = ChopSession._test._sessions()[c2].state, la = ChopSession._test._sessions()[c2].lastActivity }
    check('CNL2 Cancel de sessão com parts → false,committed', (function()
        local o, e = ChopSession.Cancel(c2, 'x'); return o == false and e == 'committed'
    end)())
    check('CNL2 estado inalterado (DISMANTLING)', ChopSession._test._sessions()[c2].state == before.st and before.st == 'DISMANTLING')
    check('CNL2 lastActivity inalterado', ChopSession._test._sessions()[c2].lastActivity == before.la)
    check('CNL2 wheel_lf continua REMOVED', VPChopBaseState.wasChopped(10, 'wheel_lf') == true)

    -- CNL3) após CNL2: GetByVehicle → MESMA sessão; Create(outro player) → mesma, sem novo VSID
    check('CNL3 GetByVehicle → mesma sessão', ChopSession.GetByVehicle(10).id == c2)
    local vsidBefore = ChopSession._test._sessions()[c2].vehicle.identity
    local same = ChopSession.Create(10, 7)
    check('CNL3 Create(outro player) → mesma sessão ativa', same ~= nil and same.id == c2)
    check('CNL3 VSID não mudou', same.vehicle.identity == vsidBefore)

    -- CNL4) committed + CleanupPlayer último participante → órfã viva (comportamento atual)
    ChopSession.CleanupPlayer(1); ChopSession.CleanupPlayer(7)
    check('CNL4 committed órfã continua viva', ChopSession.GetByVehicle(10) ~= nil and ChopSession.GetByVehicle(10).id == c2)

    -- CNL5) committed state só some com CleanupVehicle / veículo inválido
    despawn(10); ChopSession._test.sweep()
    check('CNL5 veículo inválido → committed state finalmente some', ChopSession._test._sessions()[c2] == nil)

    print(('[base_state/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then print('[base_state/spec] \27[31mHÁ FALHAS.\27[0m') end
end)
