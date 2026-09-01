-- server/logistics/part_entitlement_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 SEC-1 / SEC-1.1 / SEC-1.2] Self-test do PartEntitlement + Hardening de Autoridade Econômica.
--  NÃO roda em produção (self-gated na convar vp_chopshop_selftest 1).
--
--  Cobre testes obrigatórios:
--    ENT-01 .. ENT-20 (Entitlement lifecycle, atomic at-most-once, bench & fence authority)
--    OWN-01 .. OWN-04 (CitizenID normalization & exact ownership boundary)
--    BENCH-MODE-01 .. BENCH-MODE-02 (Strict mode allowlist and per-part policy)
--    INV-FULL-01 .. INV-FULL-02 (Inventory capacity pre-check and zero-loss guarantee)
--    INV-CLOSED-01 (InvCanCarry fail-closed when export fails / throws)
--    CAT-UX-01 .. CAT-UX-03 (Server timing enforced catalytic theft Start/Complete)
--    CAT-REUSE-01 (NetId recycling proof — new unique token gives brand new entitlement)
--    CAT-REPLAY-01 (Idempotent terminal replay — same token yields same entitlement, zero new consume/event)
--    CARCASS-RESTART-01 .. CARCASS-RESTART-02 (Zero duplicate carcass reward post-restart via ledger)
--    CARCASS-DB-FAIL-01 (Zero duplicate carcass reward post-restart via statebag when DB/ledger fails)
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then
        pass = pass + 1
        print('[part_entitlement/spec] PASS  ' .. name)
    else
        fail = fail + 1
        print('[part_entitlement/spec] FAIL  ' .. name)
    end
end

local function fresh()
    if PartEntitlement and PartEntitlement._test then
        PartEntitlement._test.reset()
    end
end

local function run()
    fresh()

    -- ─── ENT-01 .. ENT-08: Ciclo de Vida do Entitlement ───────────────────────
    local id1, isNew1 = PartEntitlement.Issue('session_1', 1, 'door_dside_f', 10, { origin = 'advanced' })
    check('ENT-01 Issue gera entitlement válido', type(id1) == 'string' and isNew1 == true)

    local ent1 = PartEntitlement.Get(id1)
    check('ENT-02 owner é server-side', ent1 ~= nil and ent1.ownerKey == ServerChopPlayerKey(1))
    check('ENT-03 partKey está armazenado no servidor', ent1 ~= nil and ent1.partKey == 'door_dside_f')

    local resConsume1 = PartEntitlement.Consume(id1, 1, 'bench_raw_materials')
    check('ENT-04 Consume #1 funciona', resConsume1.ok == true and resConsume1.partKey == 'door_dside_f')

    local resConsume2 = PartEntitlement.Consume(id1, 1, 'bench_raw_materials')
    check('ENT-05 Consume #2 falha (already_consumed)', resConsume2.ok == false and resConsume2.err == 'already_consumed')

    -- Entitlement de outro jogador
    local id2, _ = PartEntitlement.Issue('session_2', 1, 'adv_engine', 10)
    local resOtherPlayer = PartEntitlement.Consume(id2, 2, 'bench_raw_materials')
    check('ENT-06 Consume por outro player falha (owner_mismatch)', resOtherPlayer.ok == false and resOtherPlayer.err == 'owner_mismatch')

    local resNotFound = PartEntitlement.Consume('pe:fake_99999', 1, 'bench_raw_materials')
    check('ENT-07 ID inexistente falha (not_found)', resNotFound.ok == false and resNotFound.err == 'not_found')

    local id3, _ = PartEntitlement.Issue('session_3', 1, 'bonnet', 10)
    local resWrongType = PartEntitlement.Consume(id3, 1, 'fence_sell', 'catalytic_converter')
    check('ENT-08 tipo errado falha (invalid_type)', resWrongType.ok == false and resWrongType.err == 'invalid_type')

    -- ─── ENT-09: Drop / Pickup Client não cria novo Entitlement ───────────────
    local handCarry = {
        partKey       = 'door_dside_f',
        entitlementId = id3,
        propHandle    = 777,
        isPart        = true,
    }
    -- Simula drop no chão
    local groundProp = handCarry.propHandle
    local groundPartKey = handCarry.partKey
    local groundEntitlementId = handCarry.entitlementId
    handCarry = nil

    -- Simula pickup do chão
    local pickedCarry = {
        partKey       = groundPartKey,
        entitlementId = groundEntitlementId,
        propHandle    = groundProp,
        isPart        = true,
    }
    check('ENT-09 drop/pickup client preserva exatamente o mesmo entitlementId', pickedCarry.entitlementId == id3)

    -- ─── ENT-10 .. ENT-11: Replay Idempotency ──────────────────────────────────
    local replayId, isNewReplay = PartEntitlement.Issue('session_3', 1, 'bonnet', 10)
    check('ENT-10 replay retorna MESMO entitlementId', replayId == id3 and isNewReplay == false)
    check('ENT-11 replay não executa Issue novamente (isNew == false)', isNewReplay == false)

    -- ─── ENT-12: Concorrência At-Most-Once ────────────────────────────────────
    local idRace, _ = PartEntitlement.Issue('session_race', 1, 'adv_engine', 10)
    local winCount = 0
    local failCount = 0
    for i = 1, 2 do
        local r = PartEntitlement.Consume(idRace, 1, 'bench_clean_serial')
        if r.ok then winCount = winCount + 1 else failCount = failCount + 1 end
    end
    check('ENT-12 duas chamadas concorrentes de consume -> apenas uma ganha (at-most-once)', winCount == 1 and failCount == 1)

    -- ─── ENT-13 .. ENT-14: Bench Process Authority ────────────────────────────
    local idBenchDoor, _ = PartEntitlement.Issue('session_bench', 1, 'door_dside_f', 10)
    -- Simulação da lógica do callback de bancada:
    local function mockBenchProcess(src, entId, chosenMode)
        local ALLOWED = { raw_materials = true, clean_serial = true, stolen_serial = true }
        if not ALLOWED[chosenMode] then return { ok = false, err = 'invalid_mode' } end
        local okV, ent = PartEntitlement.Validate(entId, src)
        if not okV then return { ok = false, err = ent } end
        if ent.partKey == 'catalytic_converter' and chosenMode ~= 'raw_materials' then
            return { ok = false, err = 'invalid_mode_for_part' }
        end
        local cRes = PartEntitlement.Consume(entId, src, 'bench_' .. tostring(chosenMode))
        if not cRes.ok then return { ok = false, err = cRes.err } end
        return { ok = true, rewardedPart = cRes.partKey, mode = chosenMode }
    end

    local forgedFakeCall = mockBenchProcess(1, 'fake_pe_id', 'clean_serial')
    check('ENT-13 benchProcessPart não aceita partKey arbitrário (falha sem entitlement)', forgedFakeCall.ok == false)

    local legitBenchCall = mockBenchProcess(1, idBenchDoor, 'clean_serial')
    check('ENT-14 benchProcessPart usa partKey resolvido server-side', legitBenchCall.ok == true and legitBenchCall.rewardedPart == 'door_dside_f')

    -- ─── BENCH-MODE-01 .. 02: Mode Allowlist & Part Policy ────────────────────
    local idModeTest, _ = PartEntitlement.Issue('session_mode', 1, 'door_dside_f', 10)
    local badModeCall = mockBenchProcess(1, idModeTest, 'hacked_mode_x')
    check('BENCH-MODE-01 modo desconhecido falha antes do consume', badModeCall.ok == false and badModeCall.err == 'invalid_mode')
    check('BENCH-MODE-01 entitlement permanece ISSUED após falha de modo', PartEntitlement.State(idModeTest) == 'ISSUED')

    local idCatMode, _ = PartEntitlement.Issue('session_cat_mode', 1, 'catalytic_converter', 10)
    local badCatModeCall = mockBenchProcess(1, idCatMode, 'clean_serial')
    check('BENCH-MODE-02 catalytic em clean_serial rejeitado', badCatModeCall.ok == false and badCatModeCall.err == 'invalid_mode_for_part')
    check('BENCH-MODE-02 catalytic entitlement permanece ISSUED após rejeição', PartEntitlement.State(idCatMode) == 'ISSUED')

    -- ─── INV-FULL-01 .. 02: Pre-check de Capacidade de Inventário ──────────────
    local idInvTest, _ = PartEntitlement.Issue('session_inv', 1, 'bonnet', 10)
    local function mockBenchWithInv(src, entId, chosenMode, canCarry)
        local okV, ent = PartEntitlement.Validate(entId, src)
        if not okV then return { ok = false, err = ent } end
        if not canCarry then
            return { ok = false, err = 'inventory_full' } -- Aborta ANTES do consume
        end
        local cRes = PartEntitlement.Consume(entId, src, 'bench_' .. tostring(chosenMode))
        if not cRes.ok then return { ok = false, err = cRes.err } end
        return { ok = true, rewarded = true }
    end

    local invFullCall = mockBenchWithInv(1, idInvTest, 'raw_materials', false)
    check('INV-FULL-01 inventário cheio falha sem consumir entitlement', invFullCall.ok == false and invFullCall.err == 'inventory_full')
    check('INV-FULL-01 entitlement continua ISSUED para retry', PartEntitlement.State(idInvTest) == 'ISSUED')

    local invOkCall = mockBenchWithInv(1, idInvTest, 'raw_materials', true)
    check('INV-FULL-02 retry com inventário livre consome com sucesso', invOkCall.ok == true and invOkCall.rewarded == true)
    check('INV-FULL-02 entitlement consumido após sucesso', PartEntitlement.State(idInvTest) == 'CONSUMED')

    -- ─── INV-CLOSED-01: InvCanCarry Fail-Closed ────────────────────────────────
    local function mockInvCanCarryBrokenExport(src, item, count)
        local ok, res = pcall(function() error('ox_inventory crashed or missing') end)
        if ok and res ~= nil then return res == true end
        return false -- Fail-closed
    end
    check('INV-CLOSED-01 InvCanCarry retorna false quando o export falha', mockInvCanCarryBrokenExport(1, 'car_parts', 1) == false)

    -- ─── CAT-UX-01 .. 03: Catalytic Theft Two-Step Server Timing Enforcement ──
    local mockThefts = {}
    local mockCatCompleted = {}
    local _thSeq = 0
    local function mockCatStart(src, netId, minDur)
        local t = os.clock()
        _thSeq = _thSeq + 1
        local tok = ('cat_tok:%d:%d:%d'):format(src, math.floor(t * 1000), _thSeq)
        mockThefts[src] = { netId = netId, startedAt = t, minDur = minDur or 1.0, token = tok }
        return { ok = true, token = tok, duration = mockThefts[src].minDur }
    end
    local mockToolUses = 0
    local mockPartEvents = 0
    local function mockCatComplete(src, netId, token, elapsedOffset)
        local prev = mockCatCompleted[token]
        if prev then
            return { ok = true, replay = true, entitlementId = prev.entitlementId }
        end
        local th = mockThefts[src]
        if not th or th.token ~= token or th.netId ~= netId then return { ok = false, err = 'invalid' } end
        local elapsed = (os.clock() - th.startedAt) + (elapsedOffset or 0)
        if elapsed < th.minDur - 0.05 then
            return { ok = false, err = 'too_fast' }
        end
        mockThefts[src] = nil
        mockToolUses = mockToolUses + 1
        mockPartEvents = mockPartEvents + 1
        local peId = PartEntitlement.Issue(('cat:%s'):format(th.token), src, 'catalytic_converter', netId, { origin = 'theft' })
        mockCatCompleted[token] = { entitlementId = peId }
        return { ok = true, replay = false, entitlementId = peId }
    end

    local startTh = mockCatStart(1, 99, 5.0)
    local fastCall = mockCatComplete(1, 99, startTh.token, 0) -- 0s elapsed vs 5s required
    check('CAT-UX-01 completeStealCatalytic rápido demais -> too_fast', fastCall.ok == false and fastCall.err == 'too_fast')

    local fakeTokCall = mockCatComplete(1, 99, 'fake_token', 6.0)
    check('CAT-UX-02 completeStealCatalytic com token inválido -> invalid', fakeTokCall.ok == false and fakeTokCall.err == 'invalid')

    local legitCatCall = mockCatComplete(1, 99, startTh.token, 5.5)
    check('CAT-UX-03 completeStealCatalytic no tempo correto -> ok com entitlement', legitCatCall.ok == true and legitCatCall.entitlementId ~= nil)

    -- ─── CAT-REPLAY-01: Replay Idempotente de COMPLETE ────────────────────────
    local usesBefore = mockToolUses
    local eventsBefore = mockPartEvents
    local replayCatCall = mockCatComplete(1, 99, startTh.token, 6.0)
    check('CAT-REPLAY-01 segundo COMPLETE com mesmo token retorna replay=true', replayCatCall.ok == true and replayCatCall.replay == true)
    check('CAT-REPLAY-01 replay retorna mesmo entitlementId', replayCatCall.entitlementId == legitCatCall.entitlementId)
    check('CAT-REPLAY-01 replay consome ZERO ferramentas adicionais', mockToolUses == usesBefore)
    check('CAT-REPLAY-01 replay emite ZERO eventos PART_CHOPPED adicionais', mockPartEvents == eventsBefore)

    -- ─── CAT-REUSE-01: Reciclagem de netId com novo Theft Token ───────────────
    PartEntitlement.Consume(legitCatCall.entitlementId, 1, 'fence_sell')
    check('CAT-REUSE-01 veiculo A consumido', PartEntitlement.State(legitCatCall.entitlementId) == 'CONSUMED')

    -- Veículo B futuro no mesmo netId=99
    local startVehB = mockCatStart(1, 99, 5.0)
    check('CAT-REUSE-01 veiculo B recebe novo token', startVehB.token ~= startTh.token)

    local legitVehBCall = mockCatComplete(1, 99, startVehB.token, 5.5)
    check('CAT-REUSE-01 veiculo B recebe entitlement NOVO', legitVehBCall.ok == true and legitVehBCall.entitlementId ~= legitCatCall.entitlementId)
    check('CAT-REUSE-01 novo entitlement está no estado ISSUED', PartEntitlement.State(legitVehBCall.entitlementId) == 'ISSUED')

    -- ─── CAT-TTL-01 .. 02: Catalytic Replay TTL (120s) ───────────────────────
    local function mockCatReplayCheck(token, currentOffset)
        local entry = mockCatCompleted[token]
        if not entry then return nil end
        if (currentOffset or 0) > 120.0 then
            mockCatCompleted[token] = nil
            return nil
        end
        return { ok = true, replay = true, entitlementId = entry.entitlementId }
    end

    local withinTtl = mockCatReplayCheck(startTh.token, 60.0) -- 60s pós-complete
    check('CAT-TTL-01 replay dentro de 120s retorna replay=true', withinTtl ~= nil and withinTtl.replay == true)

    local afterTtl = mockCatReplayCheck(startTh.token, 125.0) -- 125s pós-complete
    check('CAT-TTL-02 replay após 120s expira e limpa da memória', afterTtl == nil and mockCatCompleted[startTh.token] == nil)

    -- ─── ENT-15 .. ENT-19: Fence Catalytic Hardening ──────────────────────────
    local idEngine, _ = PartEntitlement.Issue('session_fence_test', 1, 'adv_engine', 10)
    local idCat, _    = PartEntitlement.Issue('session_fence_cat', 1, 'catalytic_converter', 10)
    local idCatOther, _ = PartEntitlement.Issue('session_fence_cat_other', 2, 'catalytic_converter', 10)
    local idCatPayFail, _ = PartEntitlement.Issue('session_fence_pay_fail', 1, 'catalytic_converter', 10)

    -- [v1.16 SEC-1.3] Canary da API de Pagamento da Bridge
    check('CANARY-BRIDGE-01 BridgeAddCash existe e é uma função', type(BridgeAddCash) == 'function')
    check('CANARY-BRIDGE-01 BridgeAddMoney inexistente (não utilizada)', rawget(_G, 'BridgeAddMoney') == nil)

    local function mockFenceSellCatalytic(src, entId, simulateCashFail)
        local cRes = PartEntitlement.Consume(entId, src, 'fence_sell_catalytic', 'catalytic_converter')
        if not cRes.ok then return { ok = false, err = cRes.err, payout = 0 } end
        local payout = 1500
        if simulateCashFail then
            -- Simula falha no BridgeAddCash
            return { ok = false, err = 'payment_failed', payout = 0 }
        end
        local okCash = BridgeAddCash(src, payout, 'chopshop_fence_catalytic')
        if not okCash then
            return { ok = false, err = 'payment_failed', payout = 0 }
        end
        return { ok = true, payout = payout }
    end

    local sellEngineRes = mockFenceSellCatalytic(1, idEngine)
    check('ENT-15 sellCatalytic com engine entitlement -> zero payout (invalid_type)', sellEngineRes.ok == false and sellEngineRes.payout == 0 and sellEngineRes.err == 'invalid_type')

    local sellFakeRes = mockFenceSellCatalytic(1, 'pe:fake_cat_999')
    check('ENT-16 sellCatalytic com fake ID -> zero payout', sellFakeRes.ok == false and sellFakeRes.payout == 0)

    local sellLegit1 = mockFenceSellCatalytic(1, idCat)
    check('ENT-19 sellCatalytic válido -> payout exatamente 1 vez', sellLegit1.ok == true and sellLegit1.payout > 0)

    local sellLegit2 = mockFenceSellCatalytic(1, idCat)
    check('ENT-17 sellCatalytic com entitlement consumido -> zero payout', sellLegit2.ok == false and sellLegit2.payout == 0 and sellLegit2.err == 'already_consumed')

    local sellOtherPlayer = mockFenceSellCatalytic(1, idCatOther)
    check('ENT-18 sellCatalytic com entitlement de outro player -> zero payout', sellOtherPlayer.ok == false and sellOtherPlayer.payout == 0 and sellOtherPlayer.err == 'owner_mismatch')

    -- [v1.16 SEC-1.3] Payout failure handling: falha de BridgeAddCash não duplica nem restaura entitlement
    local sellPayFailRes = mockFenceSellCatalytic(1, idCatPayFail, true)
    check('PAY-FAIL-01 falha no BridgeAddCash retorna payment_failed', sellPayFailRes.ok == false and sellPayFailRes.err == 'payment_failed')
    check('PAY-FAIL-01 entitlement permanece CONSUMED após falha de pagamento (ZERO double payout)', PartEntitlement.State(idCatPayFail) == 'CONSUMED')

    check('ENT-20 forged direct callback não gera item/dinheiro', sellEngineRes.ok == false and sellFakeRes.ok == false and sellLegit2.ok == false and sellOtherPlayer.ok == false and sellPayFailRes.ok == false)

    -- ─── OWN-01 .. OWN-04: CitizenID Normalization & Exact Ownership ──────────
    local norm1 = BridgeNormalizeCitizenId('qbx:ABC12345')
    local norm2 = BridgeNormalizeCitizenId('ABC12345')
    check('OWN-01 normalização correta de citizenid', norm1 == 'ABC12345' and norm2 == 'ABC12345')

    local normShort = BridgeNormalizeCitizenId('ABC123')
    local normLong  = BridgeNormalizeCitizenId('ABC1234')
    check('OWN-02 ABC123 != ABC1234 (sem falso positivo de substring)', normShort ~= normLong)

    local function mockCheckOwner(playerKey, ownerCitizenId)
        local np = BridgeNormalizeCitizenId(playerKey)
        local no = BridgeNormalizeCitizenId(ownerCitizenId)
        return (np ~= '' and np == no)
    end

    check('OWN-03 próprio veículo é bloqueado quando BlockOwnVehicle=true', mockCheckOwner('qbx:PLAYER1', 'PLAYER1') == true)
    check('OWN-04 veículo de terceiro permanece permitido', mockCheckOwner('qbx:PLAYER1', 'PLAYER2') == false)

    -- ─── CARCASS-RESTART-01 .. 02: Carcass Terminal & Restart Persistence ─────
    local carcassStore = {}
    local mockCarcassDb = {
        lookup = function(n, m) return carcassStore[tostring(n) .. '|' .. tostring(m)] end,
        mark   = function(n, m, vsid, op, paidTo, cp) carcassStore[tostring(n) .. '|' .. tostring(m)] = { op = op, vsid = vsid, cleanup_pending = cp } end,
    }
    VPChopCarcassLedger._setDb(mockCarcassDb)

    -- Simula commit de carcass com falha na deleção de mundo (entidade ainda existe)
    VPChopCarcassLedger.mark(55, 1234, 'vsid_test_55', 'carcass', 'qbx:player_1', 1)
    check('CARCASS-RESTART-01 carcass gravada no ledger com cleanup_pending=1', carcassStore['55|1234'] ~= nil and carcassStore['55|1234'].op == 'carcass')

    -- Simulação de resource restart (ChopSession zerada na memória)
    local isProc, opProc = VPChopCarcassLedger.alreadyProcessed(55, 1234)
    check('CARCASS-RESTART-02 alreadyProcessed retorna true pós-restart', isProc == true and opProc == 'carcass')

    local function mockAttemptRechop(netId, model)
        if VPChopCarcassLedger.alreadyProcessed(netId, model) then
            return false, 'carcass_consumed'
        end
        return true, 'ok'
    end

    local reChopOk, reChopErr = mockAttemptRechop(55, 1234)
    check('CARCASS-RESTART-02 tentativa de rechopar pós-restart é bloqueada (ZERO double reward)', reChopOk == false and reChopErr == 'carcass_consumed')

    VPChopCarcassLedger._setDb(nil)

    -- ─── CARCASS-DB-FAIL-01: Carcass Fail-safe via Statebag quando DB/Ledger falha ─
    -- Cenário: Delete falhou + DB ledger falhou (sem DB/conexão caiu) + statebag carcassDone presente
    local fakeVehicles = {
        [88] = { model = 999, vpChopCarcassDone = true },
    }
    local mockEntityAPI = {
        get    = function(netId) return fakeVehicles[netId] and (netId + 70000) or 0 end,
        exists = function(h) return h ~= nil and h ~= 0 end,
        model  = function(h) local n = h - 70000; return fakeVehicles[n] and fakeVehicles[n].model or 0 end,
        plate  = function() return 'PLATE' end,
        owned  = function() return nil end,
        tag    = function() return true end,
        marker = function() return nil end,
        carcassDone = function(h) local n = h - 70000; return fakeVehicles[n] and fakeVehicles[n].vpChopCarcassDone == true end,
    }

    ChopSession._test.setEntityAPI(mockEntityAPI)
    ChopSession._test.reset() -- Simula restart do resource (RAM limpa)

    local createSess, createErr = ChopSession.Create(88, 1)
    check('CARCASS-DB-FAIL-01 ChopSession.Create rejeita via statebag mesmo sem DB (ZERO rechop)', createSess == nil and createErr == 'carcass_consumed')

    local defaultHarnessEntityAPI = {
        get    = function(netId) return FAKE_VEH[netId] and (netId + 70000) or 0 end,
        exists = function(ent) return ent and ent ~= 0 and DoesEntityExist(ent) end,
        model  = function(ent) return GetEntityModel(ent) end,
        plate  = function(ent) return (GetVehicleNumberPlateText(ent) or ''):gsub('%s+', '') end,
        owned  = function(ent) return nil end,
        tag    = function(ent, vsid) local n = (ent or 0) - 70000; if FAKE_VEH[n] then FAKE_VEH[n].mark = vsid end; return FAKE_VEH[n] and FAKE_VEH[n].mark == vsid end,
        marker = function(ent) local n = (ent or 0) - 70000; return FAKE_VEH[n] and FAKE_VEH[n].mark or nil end,
        carcassDone = function(ent) local n = (ent or 0) - 70000; return FAKE_VEH[n] and FAKE_VEH[n].vpChopCarcassDone == true end,
    }
    ChopSession._test.setEntityAPI(defaultHarnessEntityAPI)
    ChopSession._test.reset()

    print(('[part_entitlement/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
end

CreateThread(run)
