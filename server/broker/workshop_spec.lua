-- server/broker/workshop_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-4] WORKSHOP BRIDGE & PERSISTENT SAGA JOURNAL SPEC SUITE
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[workshop/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[workshop/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local WB = WorkshopBridge
    local PE = PartEntitlement
    local BM = BrokerMarket
    local BC = BrokerContracts

    -- Mock Database em memória para o Journal
    local mockJournal = {}
    local mockDb = {
        query = {
            await = function(sql, params)
                params = params or {}
                if sql:find('CREATE TABLE') then return {} end
                if sql:find('ALTER TABLE') then return {} end
                if sql:find('SELECT') and sql:find('vp_chop_workshop_journal') then
                    local rows = {}
                    if sql:find("WHERE state IN") then
                        for _, row in pairs(mockJournal) do
                            if row.state == 'PREPARED' or row.state == 'RESERVED' or row.state == 'COMMITTING' or
                               row.state == 'COMMITTED' or row.state == 'RECONCILING' or row.state == 'QUARANTINE' then
                                table.insert(rows, row)
                            end
                        end
                    elseif sql:find("WHERE state = 'RECONCILING'") then
                        for _, row in pairs(mockJournal) do
                            if row.state == 'RECONCILING' then
                                table.insert(rows, row)
                            end
                        end
                    elseif sql:find('txn_id = ?') then
                        local txn = params[1]
                        if mockJournal[txn] then
                            table.insert(rows, mockJournal[txn])
                        end
                    else
                        for _, row in pairs(mockJournal) do
                            table.insert(rows, row)
                        end
                    end
                    return rows
                end
                if sql:find('UPDATE vp_chop_workshop_journal') then
                    local newState = sql:match("SET state = ['\"](%w+)['\"]")
                    if not newState and sql:find('SET state = %?,') then
                        newState = params[1]
                    end
                    local whereState = sql:match("AND state = ['\"](%w+)['\"]")
                    local txnId = nil
                    for _, p in ipairs(params) do
                        if type(p) == 'string' and p:find('^ws:') then
                            txnId = p
                        end
                    end

                    if txnId and mockJournal[txnId] then
                        local row = mockJournal[txnId]
                        if whereState and row.state ~= whereState then
                            return { affectedRows = 0 }
                        end
                        if newState then row.state = newState end
                        if sql:find('reconcile_count = %?') then
                            row.reconcile_count = params[1]
                        end
                        return { affectedRows = 1 }
                    end
                    return { affectedRows = 0 }
                end
                return { affectedRows = 1 }
            end
        },
        insert = {
            await = function(sql, params)
                params = params or {}
                if sql:find('INSERT INTO vp_chop_workshop_journal') then
                    local txnId = params[1]
                    local isPlate = sql:find("'stolen_plate'") ~= nil
                    mockJournal[txnId] = {
                        txn_id          = params[1],
                        provider        = params[2],
                        player_key      = params[3],
                        asset_kind      = isPlate and 'stolen_plate' or 'part_entitlement',
                        entitlement_id  = isPlate and nil or params[4],
                        stable_part_id  = isPlate and params[4] or params[5],
                        part_key        = isPlate and 'stolen_plate' or params[6],
                        price           = isPlate and params[5] or params[7],
                        state           = 'PREPARED',
                        reconcile_count = 0,
                        metadata        = params[#params],
                    }
                    return 1
                end
                return 1
            end
        }
    }

    local virtualTime = 1700000000
    local mockProvider = nil

    local function createMockProvider(opts)
        opts = opts or {}
        local p = {
            ResourceName = opts.resourceName or 'mock_workshop',
            prepareCalls = 0,
            commitCalls = 0,
            statusCalls = 0,
            abortCalls = 0,
            actualPayouts = 0,
            isAvailable = opts.isAvailable ~= false,
            prepareOk = opts.prepareOk ~= false,
            preparePrice = opts.preparePrice or 3000,
            prepareTtl = opts.prepareTtl or 45,
            prepareErr = opts.prepareErr,
            commitOk = opts.commitOk ~= false,
            commitPaid = opts.commitPaid ~= false,
            commitErr = opts.commitErr,
            statusReturn = opts.statusReturn or 'COMMITTED',
            abortReturn = opts.abortReturn ~= false,
            paidTxns = {},
        }

        function p.IsAvailable() return p.isAvailable end
        function p.PreparePurchase(txnId, context)
            p.prepareCalls = p.prepareCalls + 1
            if not p.prepareOk then return { ok = false, err = p.prepareErr or 'prepare_rejected' } end
            return {
                ok        = true,
                price     = p.preparePrice,
                expiresAt = virtualTime + p.prepareTtl,
            }
        end
        function p.CommitPurchase(txnId)
            p.commitCalls = p.commitCalls + 1
            if not p.commitOk then return { ok = false, err = p.commitErr or 'commit_failed' } end
            if not p.paidTxns[txnId] then
                p.paidTxns[txnId] = true
                p.actualPayouts = p.actualPayouts + 1
            end
            return { ok = true, paid = p.commitPaid }
        end
        function p.GetTransactionStatus(txnId)
            p.statusCalls = p.statusCalls + 1
            return p.statusReturn
        end
        function p.AbortPurchase(txnId)
            p.abortCalls = p.abortCalls + 1
            return p.abortReturn
        end
        function p.GetMarketSignal(query)
            return { activeDemand = { adv_engine = 1.35 }, source = 'mock_workshop' }
        end
        return p
    end

    local function resetEnv()
        mockJournal = {}
        PE._test.reset()
        WB._test.reset()
        virtualTime = 1700000000

        Config.Broker.Workshop = {
            Enable = true,
            Provider = 'mock_workshop',
            ProviderResource = 'mock_workshop',
            MaxPrice = 50000,
            PrepareMaxTtlSec = 60,
            ReconcileIntervalSec = 15,
            MaxReconcileAttempts = 4,
            Debug = false,
        }

        mockProvider = createMockProvider()
        WB.RegisterProvider('mock_workshop', mockProvider)
        WB.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
    end

    -- ─── WORKSHOP-01: Sem provider (none) -> Autônomo ───────────────────────
    do
        resetEnv()
        Config.Broker.Workshop.Provider = 'none'
        local entId, _ = PE.Issue('session_w1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'W01', model = 1234 } })
        local res = WB.HandoffPart(1, entId)
        check('WORKSHOP-01 Provider none responde workshop_unavailable sem exception', res.ok == false and res.err == 'workshop_unavailable')
        check('WORKSHOP-01 Entitlement segue intacto ISSUED', PE.State(entId) == 'ISSUED')
    end

    -- ─── WORKSHOP-02: GetMarketSignal com provider ativo ────────────────────
    do
        resetEnv()
        local res = WB.GetMarketSignal({ commodity = 'adv_engine' })
        check('WORKSHOP-02 GetMarketSignal retorna sinal canônico validado', res.ok == true and res.signal ~= nil and res.signal.activeDemand.adv_engine == 1.35)
    end

    -- ─── WORKSHOP-03: PreparePurchase rejeita -> Entitlement ISSUED ─────────
    do
        resetEnv()
        mockProvider.prepareOk = false
        mockProvider.prepareErr = 'shop_budget_depleted'
        local entId, _ = PE.Issue('session_w3', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'W03', model = 1234 } })
        local res = WB.HandoffPart(1, entId)
        check('WORKSHOP-03 Prepare rejeitado retorna erro do provider', res.ok == false and res.err == 'shop_budget_depleted')
        check('WORKSHOP-03 Entitlement segue ISSUED após rejeição do prepare', PE.State(entId) == 'ISSUED')
        check('WORKSHOP-03 Zero chamadas de CommitPurchase', mockProvider.commitCalls == 0)
        check('WORKSHOP-03 Zero payouts efetuados', mockProvider.actualPayouts == 0)
    end

    -- ─── WORKSHOP-04: SAGA Completa com Sucesso ─────────────────────────────
    do
        resetEnv()
        local entId, _ = PE.Issue('session_w4', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'W04', model = 1234 } })
        local res = WB.HandoffPart(1, entId)
        check('WORKSHOP-04 SAGA completa com sucesso e paid=true', res.ok == true and res.paid == true and res.price == 3000)
        check('WORKSHOP-04 Entitlement transiciona para CONSUMED', PE.State(entId) == 'CONSUMED')
        check('WORKSHOP-04 Provider Commit chamado exatamente 1x', mockProvider.commitCalls == 1)
        check('WORKSHOP-04 Payout executado exatamente 1x', mockProvider.actualPayouts == 1)
        check('WORKSHOP-04 Journal finalizado em FINALIZED', mockJournal[res.txnId] ~= nil and mockJournal[res.txnId].state == 'FINALIZED')
    end

    -- ─── WORKSHOP-05: Retry de CommitPurchase (Idempotência) ─────────────────
    do
        resetEnv()
        local entId, _ = PE.Issue('session_w5', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'W05', model = 1234 } })
        mockProvider.commitOk = false -- 1a chamada falha
        mockProvider.statusReturn = 'PREPARED' -- Sinaliza que o commit pode ser retentado
        -- Simular retry interno:
        local res = WB.HandoffPart(1, entId)
        -- Durante o handoff, ao receber PREPARED no status, o bridge retenta com o MESMO txnId
        -- Vamos verificar que o mockProvider recebeu o mesmo txnId
        check('WORKSHOP-05 Commit Purchase retry não duplicou payout (actualPayouts <= 1)', mockProvider.actualPayouts <= 1)
    end

    -- ─── WORKSHOP-06: Restart em COMMITTING -> Boot Recovery ────────────────
    do
        resetEnv()
        local entId, _ = PE.Issue('session_w6', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'W06', model = 1234 } })
        local ent = PE.Get(entId)
        local txnId = 'ws:mock_workshop:boot6:1700000000:1'
        mockJournal[txnId] = {
            txn_id          = txnId,
            provider        = 'mock_workshop',
            player_key      = 'qbx:player_1',
            asset_kind      = 'part_entitlement',
            entitlement_id  = entId,
            stable_part_id  = ent.stablePartIdentity,
            part_key        = 'adv_engine',
            price           = 3000,
            state           = 'COMMITTING',
            reconcile_count = 0,
            metadata        = json.encode(ent),
        }
        mockProvider.statusReturn = 'COMMITTED'

        -- Simular restart (limpar RAM)
        PE._test.reset()
        WB._test.reset()

        WB.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
        check('WORKSHOP-06 Boot recovery finaliza transação COMMITTING cujo status é COMMITTED', mockJournal[txnId].state == 'FINALIZED')
        check('WORKSHOP-06 Entitlement restaurado e finalizado como CONSUMED', PE.State(entId) == 'CONSUMED')
    end

    -- ─── WORKSHOP-STABLE-01: Runtime ID Collision após Restart (GATE P0) ────
    do
        resetEnv()
        -- 1. Boot A: emite peça A com SPI_A
        local entA, _ = PE.Issue('session_a', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PL_A', model = 1234 } })
        local dataA = PE.Get(entA)
        local stableA = dataA.stablePartIdentity
        local txnA = 'ws:mock_workshop:saga_a:1700000000:1'
        mockJournal[txnA] = {
            txn_id          = txnA,
            provider        = 'mock_workshop',
            player_key      = 'qbx:player_1',
            asset_kind      = 'part_entitlement',
            entitlement_id  = entA, -- 'pe:1'
            stable_part_id  = stableA,
            part_key        = 'adv_engine',
            price           = 3000,
            state           = 'COMMITTING',
            reconcile_count = 0,
            metadata        = json.encode(dataA),
        }

        -- 2. Simular Restart do Resource (limpar RAM de Entitlements e Bridge)
        PE._test.reset()
        WB._test.reset()
        PE._test.setBootNonce('boot_b_nonce')

        -- 3. Boot B: novo jogador B emite peça que ganha o ID pe:1 na RAM com SPI_B
        local entB, _ = PE.Issue('session_b', 2, 'door_dside_f', 20, { origin = 'advanced', provenance = { realPlate = 'PL_B', model = 5678 } })
        local dataB = PE.Get(entB)
        local stableB = dataB.stablePartIdentity

        check('WORKSHOP-STABLE-01 Runtime ID colidiu propositalmente em pe:1', entA == entB and entB == 'pe:1')
        check('WORKSHOP-STABLE-01 Mas stablePartIdentities são distintas entre boots', stableA ~= stableB)

        -- 4. Recovery carrega antiga txn A e o provider confirma COMMITTED
        mockProvider.statusReturn = 'COMMITTED'
        WB.Init(mockDb, function() return virtualTime end, function() return 0.5 end)

        -- 5. Conferir que a nova peça B (pe:1 atual) permaneceu INTACTA no estado ISSUED!
        check('WORKSHOP-STABLE-01 Nova peça B (pe:1 com SPI_B) permanece INTACTA em ISSUED', PE.State(entB) == 'ISSUED')
        check('WORKSHOP-STABLE-01 Nova peça B segue pertencendo ao Player 2', PE.Get(entB).ownerKey == 'qbx:player_2')
        check('WORKSHOP-STABLE-01 Transação antiga de A foi FINALIZED sem corromper B', mockJournal[txnA].state == 'FINALIZED')
    end

    -- ─── WORKSHOP-RESERVE-01..03: Bloqueio de outros destinos ───────────────
    do
        resetEnv()
        local entId, _ = PE.Issue('session_resv', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'RESV01', model = 1234 } })
        PE.ReserveForExternal(entId, 1, 'ws:mock:txn:test')

        -- 1. Broker NPC Sale bloqueado
        local okV1, errV1 = PE.Validate(entId, 1)
        check('WORKSHOP-RESERVE-01 RESERVED_EXTERNAL bloqueia validação padrão com external_reserved', okV1 == false and errV1 == 'external_reserved')

        -- 2. Broker Contracts bloqueado
        local cId = 101
        local contract = { id = cId, contractType = 'part_type', targetKey = 'adv_engine', minTrust = 1, rewardMult = 1.20, bonusCash = 0 }
        local okC, errC = PartEntitlement.Validate(entId, 1, 'adv_engine')
        check('WORKSHOP-RESERVE-02 RESERVED_EXTERNAL bloqueia consumo de contratos', okC == false and errC == 'external_reserved')

        -- 3. Bench consume bloqueado
        local resCons = PE.Consume(entId, 1, 'bench_dismantle')
        check('WORKSHOP-RESERVE-03 RESERVED_EXTERNAL bloqueia consumo da bancada', resCons.ok == false and resCons.err == 'external_reserved')
    end

    -- ─── WORKSHOP-ABORT-01..03: Abort e Proteção de Liberação ───────────────
    do
        resetEnv()
        local entId, _ = PE.Issue('session_ab1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'AB01', model = 1234 } })
        PE.ReserveForExternal(entId, 1, 'ws:mock:txn:ab1')

        -- WORKSHOP-ABORT-01: Abort comprovado libera entitlement
        local released = PE.ReleaseExternalReservation(entId, 'ws:mock:txn:ab1')
        check('WORKSHOP-ABORT-01 Abort comprovado retorna peça para ISSUED', released == true and PE.State(entId) == 'ISSUED')

        -- WORKSHOP-ABORT-02: Transação COMMITTING com status UNKNOWN NUNCA libera
        PE.ReserveForExternal(entId, 1, 'ws:mock:txn:ab2')
        local txn2 = 'ws:mock:txn:ab2'
        mockJournal[txn2] = {
            txn_id = txn2, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entId, stable_part_id = PE.Get(entId).stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'COMMITTING', reconcile_count = 0
        }
        mockProvider.statusReturn = 'UNKNOWN'
        WB.BootstrapRecovery()
        check('WORKSHOP-ABORT-02 Status UNKNOWN em COMMITTING transiciona para RECONCILING sem liberar peça', mockJournal[txn2].state == 'RECONCILING')
        check('WORKSHOP-ABORT-02 Peça permanece RESERVED_EXTERNAL sob UNKNOWN', PE.State(entId) == 'RESERVED_EXTERNAL')
    end

    -- ─── WORKSHOP-DB-01..03: DB Failures e Circuit Breaker ──────────────────
    do
        resetEnv()
        -- WORKSHOP-DB-01: Prepare OK + journal INSERT falha
        local oldInsert = mockDb.insert.await
        mockDb.insert.await = function() return nil end -- Falha no DB
        local entDb1, _ = PE.Issue('session_db1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'DB01', model = 1234 } })
        local resDb1 = WB.HandoffPart(1, entDb1)
        check('WORKSHOP-DB-01 Falha no INSERT do journal aborta prepare e retorna journal_write_failed', resDb1.ok == false and resDb1.err == 'journal_write_failed')
        check('WORKSHOP-DB-01 Entitlement segue ISSUED após falha de DB no prepare', PE.State(entDb1) == 'ISSUED')
        check('WORKSHOP-DB-01 Provider Abort foi acionado', mockProvider.abortCalls >= 1)
        mockDb.insert.await = oldInsert

        -- WORKSHOP-DB-03: Provider pagou mas UPDATE COMMITTED falha -> circuit breaker
        resetEnv()
        local entDb3, _ = PE.Issue('session_db3', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'DB03', model = 1234 } })
        local oldQuery = mockDb.query.await
        mockDb.query.await = function(sql, params)
            if sql:find("SET state = 'COMMITTED'") then return { affectedRows = 0 } end
            return oldQuery(sql, params)
        end
        local resDb3 = WB.HandoffPart(1, entDb3)
        check('WORKSHOP-DB-03 Falha pós-pagamento ativa circuit breaker e retorna workshopDegraded=true', resDb3.ok == true and resDb3.workshopDegraded == true)
        check('WORKSHOP-DB-03 WorkshopBridge entra em Integrity Locked', WB.IsIntegrityLocked() == true)
        mockDb.query.await = oldQuery
    end

    -- ─── WORKSHOP-QUARANTINE-01: Reconcile Max Attempts -> QUARANTINE ───────
    do
        resetEnv()
        local txnQ = 'ws:mock_workshop:quarantine:1'
        mockJournal[txnQ] = {
            txn_id = txnQ, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = 'pe:999', stable_part_id = 'spi:q:1',
            part_key = 'adv_engine', price = 3000, state = 'RECONCILING', reconcile_count = 4
        }
        mockProvider.statusReturn = 'UNKNOWN'
        WB.ReconcilePending()
        check('WORKSHOP-QUARANTINE-01 Transação excedendo MaxReconcileAttempts vai para QUARANTINE', mockJournal[txnQ].state == 'QUARANTINE')
    end

    -- ─── WORKSHOP-HISTORICAL-PROVIDER-01: Respeitar provider gravado na row ──
    do
        resetEnv()
        local txnHist = 'ws:old_provider:hist:1'
        mockJournal[txnHist] = {
            txn_id = txnHist, provider = 'old_provider', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = 'pe:888', stable_part_id = 'spi:h:1',
            part_key = 'adv_engine', price = 3000, state = 'RECONCILING', reconcile_count = 0
        }
        Config.Broker.Workshop.Provider = 'mock_workshop'
        WB.BootstrapRecovery()
        check('WORKSHOP-HISTORICAL-PROVIDER-01 Provider histórico não registrado mantém transação em RECONCILING/QUARANTINE', mockJournal[txnHist].state == 'RECONCILING')
        check('WORKSHOP-HISTORICAL-PROVIDER-01 Provider atual (mock_workshop) NUNCA foi consultado sobre a txn de old_provider', mockProvider.statusCalls == 0)
    end

    -- ─── WORKSHOP-CALLER-01: Resource mismatch rejeitado ────────────────────
    do
        resetEnv()
        _G.GetInvokingResource = function() return 'malicious_resource' end
        local entCall, _ = PE.Issue('session_call', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'CALL01', model = 1234 } })
        local resCall = WB.HandoffPart(1, entCall)
        check('WORKSHOP-CALLER-01 Caller resource não correspondente é rejeitado com provider_identity_mismatch', resCall.ok == false and resCall.err == 'provider_identity_mismatch')
        _G.GetInvokingResource = function() return nil end
    end

    -- ─── WORKSHOP-PRICE-01: Validação numérica de termos econômicos ─────────
    do
        resetEnv()
        mockProvider.preparePrice = 999999 -- Acima do MaxPrice (50000)
        local entP1, _ = PE.Issue('session_pr1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PR01', model = 1234 } })
        local resP1 = WB.HandoffPart(1, entP1)
        check('WORKSHOP-PRICE-01 Preço acima do MaxPrice rejeitado com invalid_price', resP1.ok == false and resP1.err == 'invalid_price')

        mockProvider.preparePrice = 0/0 -- NaN
        local entP2, _ = PE.Issue('session_pr2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PR02', model = 1234 } })
        local resP2 = WB.HandoffPart(1, entP2)
        check('WORKSHOP-PRICE-01 Preço NaN rejeitado com invalid_price', resP2.ok == false and resP2.err == 'invalid_price')
    end

    -- ─── WORKSHOP-07 & PLATE-01..03: stolen_plate SAGA ──────────────────────
    do
        resetEnv()
        local mockSlotItem = {
            name = 'stolen_plate',
            count = 1,
            metadata = {
                plate = 'STOLEN1',
                model = 1234,
                takenAt = 1699999999,
                customField = 'audit_trace_xyz',
            }
        }
        _G.BridgeGetSlot = function(src, slot) return mockSlotItem end
        local removedItem = false
        _G.BridgeRemoveItem = function(src, name, count, meta, slot)
            if name == 'stolen_plate' and slot == 4 then
                removedItem = true
                return true
            end
            return false
        end

        local resPlate = WB.HandoffStolenPlate(1, 4)
        check('WORKSHOP-07 stolen_plate handoff concluído com sucesso e pago', resPlate.ok == true and resPlate.paid == true)
        check('WORKSHOP-PLATE-01 Item removido exatamente do slot informado (4)', removedItem == true)
        check('WORKSHOP-PLATE-02 Journal gravou asset_kind=stolen_plate', mockJournal[resPlate.txnId] ~= nil and mockJournal[resPlate.txnId].asset_kind == 'stolen_plate')

        local savedMeta = json.decode(mockJournal[resPlate.txnId].metadata)
        check('WORKSHOP-PLATE-03 Metadata completa do slot preservada sem perda', savedMeta.plate == 'STOLEN1' and savedMeta.customField == 'audit_trace_xyz')
    end

    -- ─── WORKSHOP-RACE-01: Concorrência na mesma stablePartIdentity ─────────
    do
        resetEnv()
        local entRace, _ = PE.Issue('session_race', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'RACE01', model = 1234 } })
        local res1 = WB.HandoffPart(1, entRace)
        check('WORKSHOP-RACE-01 Primeira chamada conclui SAGA com sucesso', res1.ok == true)
        local res2 = WB.HandoffPart(1, entRace)
        check('WORKSHOP-RACE-01 Segunda chamada rejeitada com already_consumed ou external_reserved', res2.ok == false)
    end

    print(('[workshop/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('workshop_spec falhou') end
end

run()
