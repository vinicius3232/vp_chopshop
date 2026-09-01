-- server/broker/workshop_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-4.1] WORKSHOP BRIDGE & PERSISTENT SAGA JOURNAL SPEC SUITE
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
                    if sql:find('LIMIT 0') then
                        return {}
                    end
                    local rows = {}
                    if sql:find("WHERE state IN %('PREPARED'") then
                        for _, row in pairs(mockJournal) do
                            if row.state == 'PREPARED' or row.state == 'RESERVED' or row.state == 'COMMITTING' or
                               row.state == 'COMMITTED' or row.state == 'RECONCILING' or row.state == 'QUARANTINE' then
                                table.insert(rows, row)
                            end
                        end
                    elseif sql:find("WHERE state IN %('RECONCILING'") or sql:find("state IN %('RECONCILING', 'QUARANTINE'%)") then
                        for _, row in pairs(mockJournal) do
                            if row.state == 'RECONCILING' or row.state == 'QUARANTINE' then
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
                    local whereInCommit = sql:find("state IN %('COMMITTING', 'RECONCILING', 'QUARANTINE'%)")
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
                        if whereInCommit and (row.state ~= 'COMMITTING' and row.state ~= 'RECONCILING' and row.state ~= 'QUARANTINE') then
                            return { affectedRows = 0 }
                        end
                        if newState then row.state = newState end
                        if sql:find('reconcile_count = %?') then
                            row.reconcile_count = params[1]
                        end
                        if sql:find('entitlement_id = %?') then
                            row.entitlement_id = params[1]
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
            commitTxnIds = {},
        }

        function p.IsAvailable()
            if type(p.isAvailable) == 'function' then return p.isAvailable() end
            return p.isAvailable
        end
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
            table.insert(p.commitTxnIds, txnId)
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
            return {
                activeDemand = { adv_engine = 1.35, catalytic_converter = 1.20 },
                urgency = 'high',
                source = 'mock_workshop'
            }
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

    -- ─── WORKSHOP-02 & WORKSHOP-SIGNAL-01..05: Validação Canônica de Sinais ────
    do
        resetEnv()
        -- 02: GetMarketSignal padrão
        local res = WB.GetMarketSignal({ commodity = 'adv_engine' })
        check('WORKSHOP-02 GetMarketSignal retorna sinal canônico validado e sanitizado', res.ok == true and res.signal ~= nil and res.signal.activeDemand.adv_engine == 1.35 and res.signal.urgency == 'high')

        -- WORKSHOP-SIGNAL-01: body_panel aceito
        local raw1 = { activeDemand = { body_panel = 1.20 }, urgency = 'normal' }
        local clean1 = WB._test.validateAndSanitizeSignal(raw1)
        check('WORKSHOP-SIGNAL-01 body_panel é aceito no activeDemand', clean1 ~= nil and clean1.activeDemand.body_panel == 1.20)

        -- WORKSHOP-SIGNAL-02: stolen_plate, metalscrap, steel, aluminum, copper, car_parts aceitos
        local raw2 = {
            activeDemand = {
                stolen_plate = 1.10,
                metalscrap = 0.90,
                steel = 1.05,
                aluminum = 1.15,
                copper = 1.25,
                car_parts = 1.30,
            },
            urgency = 'high'
        }
        local clean2 = WB._test.validateAndSanitizeSignal(raw2)
        check('WORKSHOP-SIGNAL-02 Commodities de materiais e car_parts são aceitas',
            clean2 ~= nil and
            clean2.activeDemand.stolen_plate == 1.10 and
            clean2.activeDemand.metalscrap == 0.90 and
            clean2.activeDemand.steel == 1.05 and
            clean2.activeDemand.aluminum == 1.15 and
            clean2.activeDemand.copper == 1.25 and
            clean2.activeDemand.car_parts == 1.30
        )

        -- WORKSHOP-SIGNAL-03: door_dside_f / bonnet / boot não aparecem no output
        local raw3 = {
            activeDemand = {
                door_dside_f = 1.30,
                bonnet = 1.20,
                boot = 1.10,
                carcass = 2.00,
                body_panel = 1.40,
            },
            urgency = 'low'
        }
        local clean3 = WB._test.validateAndSanitizeSignal(raw3)
        check('WORKSHOP-SIGNAL-03 Raw parts (door, bonnet, boot, carcass) são descartadas do activeDemand',
            clean3 ~= nil and
            clean3.activeDemand.door_dside_f == nil and
            clean3.activeDemand.bonnet == nil and
            clean3.activeDemand.boot == nil and
            clean3.activeDemand.carcass == nil and
            clean3.activeDemand.body_panel == 1.40
        )

        -- WORKSHOP-SIGNAL-04: Commodity adicionada dinamicamente em Config.Broker.Commodities
        Config.Broker.Commodities.custom_turbo = { basePrice = 5000 }
        local raw4 = { activeDemand = { custom_turbo = 1.50 }, urgency = 'critical' }
        local clean4 = WB._test.validateAndSanitizeSignal(raw4)
        check('WORKSHOP-SIGNAL-04 Commodity dinâmica adicionada ao config é automaticamente aceita', clean4 ~= nil and clean4.activeDemand.custom_turbo == 1.50)
        Config.Broker.Commodities.custom_turbo = nil

        -- WORKSHOP-SIGNAL-05: NaN / Inf / out-of-range descartados
        local raw5 = {
            activeDemand = {
                adv_engine = 0/0,
                tyre = 1/0,
                body_panel = -1/0,
                catalytic_converter = 0.05, -- abaixo de 0.1
                stolen_plate = 5.5,         -- acima de 5.0
                copper = 2.0,               -- válido
            }
        }
        local clean5 = WB._test.validateAndSanitizeSignal(raw5)
        check('WORKSHOP-SIGNAL-05 Valores NaN, Inf e fora da faixa [0.1, 5.0] são descartados',
            clean5 ~= nil and
            clean5.activeDemand.adv_engine == nil and
            clean5.activeDemand.tyre == nil and
            clean5.activeDemand.body_panel == nil and
            clean5.activeDemand.catalytic_converter == nil and
            clean5.activeDemand.stolen_plate == nil and
            clean5.activeDemand.copper == 2.0
        )
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

    -- ─── WORKSHOP-05 & BROKER-SEC-11: Retry de CommitPurchase (Idempotência Real)
    do
        resetEnv()
        local entId, _ = PE.Issue('session_w5', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'W05', model = 1234 } })
        local entData = PE.Get(entId)

        -- 1a chamada de CommitPurchase executa payout mas falha na resposta
        mockProvider.commitCalls = 0
        mockProvider.actualPayouts = 0
        mockProvider.commitTxnIds = {}

        local originalCommit = mockProvider.CommitPurchase
        local firstCall = true
        mockProvider.CommitPurchase = function(txnId)
            mockProvider.commitCalls = mockProvider.commitCalls + 1
            table.insert(mockProvider.commitTxnIds, txnId)
            if not mockProvider.paidTxns[txnId] then
                mockProvider.paidTxns[txnId] = true
                mockProvider.actualPayouts = mockProvider.actualPayouts + 1
            end
            if firstCall then
                firstCall = false
                return { ok = false, err = 'network_timeout_simulated' }
            end
            return { ok = true, paid = true }
        end
        mockProvider.statusReturn = 'PREPARED' -- Sinaliza que o commit pode ser retentado

        local res = WB.HandoffPart(1, entId)

        check('BROKER-SEC-11 CommitPurchase foi retentado (commitCalls >= 2)', mockProvider.commitCalls >= 2)
        check('BROKER-SEC-11 Todas as chamadas de CommitPurchase usaram o MESMO txnId', #mockProvider.commitTxnIds >= 2 and mockProvider.commitTxnIds[1] == mockProvider.commitTxnIds[2])
        check('BROKER-SEC-11 Payout real foi executado exatamente 1x (actualPayouts == 1)', mockProvider.actualPayouts == 1)
        check('BROKER-SEC-11 Entitlement finalizado como CONSUMED após retry com sucesso', PE.State(entId) == 'CONSUMED')
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

    -- ─── WORKSHOP-STABLE-02: Metadata inválida/corrompida -> QUARANTINE ─────
    do
        resetEnv()
        local entA, _ = PE.Issue('session_s2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'S2', model = 1234 } })
        PE._test.reset()
        WB._test.reset()

        -- Novo runtime emite pe:1
        local entB, _ = PE.Issue('session_s2_new', 2, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'S2_NEW', model = 1234 } })
        local txnCorrupt = 'ws:mock_workshop:corrupt:1'
        mockJournal[txnCorrupt] = {
            txn_id          = txnCorrupt,
            provider        = 'mock_workshop',
            player_key      = 'qbx:player_1',
            asset_kind      = 'part_entitlement',
            entitlement_id  = 'pe:1',
            stable_part_id  = 'spi:corrupt_old:1',
            part_key        = 'adv_engine',
            price           = 3000,
            state           = 'COMMITTED',
            reconcile_count = 0,
            metadata        = 'corrupted_not_json',
        }

        WB.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
        check('WORKSHOP-STABLE-02 Row com metadata inválida vai para QUARANTINE', mockJournal[txnCorrupt].state == 'QUARANTINE')
        check('WORKSHOP-STABLE-02 Nova peça (pe:1) permanece ISSUED intacta', PE.State(entB) == 'ISSUED')
    end

    -- ─── WORKSHOP-STABLE-03: Metadata stable != Row stable -> QUARANTINE ────
    do
        resetEnv()
        local entA, _ = PE.Issue('session_s3', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'S3', model = 1234 } })
        local dataA = PE.Get(entA)
        local txnMismatch = 'ws:mock_workshop:mismatch:1'
        mockJournal[txnMismatch] = {
            txn_id          = txnMismatch,
            provider        = 'mock_workshop',
            player_key      = 'qbx:player_1',
            asset_kind      = 'part_entitlement',
            entitlement_id  = entA,
            stable_part_id  = 'spi:different_stable_id:999',
            part_key        = 'adv_engine',
            price           = 3000,
            state           = 'COMMITTED',
            reconcile_count = 0,
            metadata        = json.encode(dataA),
        }

        WB.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
        check('WORKSHOP-STABLE-03 Row com stablePartId divergente da metadata vai para QUARANTINE', mockJournal[txnMismatch].state == 'QUARANTINE')
        check('WORKSHOP-STABLE-03 Peça local não foi alterada indevidamente', PE.State(entA) == 'ISSUED')
    end

    -- ─── WORKSHOP-STABLE-04: SessionId + PartKey collision não sobrescreve mapping
    do
        resetEnv()
        -- Peça antiga
        local entOld, _ = PE.Issue('cs:1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'OLD', model = 1234 } })
        local dataOld = PE.Get(entOld)
        local stableOld = dataOld.stablePartIdentity

        PE._test.reset()
        WB._test.reset()

        -- Peça nova no mesmo sessionId + partKey
        local entNew, _ = PE.Issue('cs:1', 2, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'NEW', model = 1234 } })
        local dataNew = PE.Get(entNew)
        local stableNew = dataNew.stablePartIdentity

        local txnOld = 'ws:mock_workshop:replay:1'
        mockJournal[txnOld] = {
            txn_id          = txnOld,
            provider        = 'mock_workshop',
            player_key      = 'qbx:player_1',
            asset_kind      = 'part_entitlement',
            entitlement_id  = entOld,
            stable_part_id  = stableOld,
            part_key        = 'adv_engine',
            price           = 3000,
            state           = 'COMMITTING',
            reconcile_count = 0,
            metadata        = json.encode(dataOld),
        }

        WB.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
        local mappedId = PE.GetBySourcePart('cs:1', 'adv_engine')
        check('WORKSHOP-STABLE-04 BySourcePart mapping preserva a autoridade da nova peça (entNew)', mappedId == entNew)
        check('WORKSHOP-STABLE-04 Nova peça permanece ISSUED e com seu stablePartIdentity original', PE.Get(mappedId).stablePartIdentity == stableNew)
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
        local okC, errC = PartEntitlement.Validate(entId, 1, 'adv_engine')
        check('WORKSHOP-RESERVE-02 RESERVED_EXTERNAL bloqueia consumo de contratos', okC == false and errC == 'external_reserved')

        -- 3. Bench consume bloqueado
        local resCons = PE.Consume(entId, 1, 'bench_dismantle')
        check('WORKSHOP-RESERVE-03 RESERVED_EXTERNAL bloqueia consumo da bancada', resCons.ok == false and resCons.err == 'external_reserved')
    end

    -- ─── WORKSHOP-ABORT-01..05: Abort Autorizado e Proteção de Liberação ────
    do
        resetEnv()
        local entId, _ = PE.Issue('session_ab1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'AB01', model = 1234 } })
        local entData = PE.Get(entId)
        PE.ReserveForExternal(entId, 1, 'ws:mock:txn:ab1')

        -- WORKSHOP-ABORT-01: Abort comprovado libera entitlement
        local released = PE.ReleaseExternalReservation(entId, 'ws:mock:txn:ab1', entData.stablePartIdentity)
        check('WORKSHOP-ABORT-01 Abort comprovado retorna peça para ISSUED', released == true and PE.State(entId) == 'ISSUED')

        -- WORKSHOP-ABORT-02: Transação COMMITTING com status UNKNOWN NUNCA libera
        PE.ReserveForExternal(entId, 1, 'ws:mock:txn:ab2')
        local txn2 = 'ws:mock:txn:ab2'
        mockJournal[txn2] = {
            txn_id = txn2, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entId, stable_part_id = entData.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'COMMITTING', reconcile_count = 0,
            metadata = json.encode(entData)
        }
        mockProvider.statusReturn = 'UNKNOWN'
        WB.BootstrapRecovery()
        check('WORKSHOP-ABORT-02 Status UNKNOWN em COMMITTING transiciona para RECONCILING sem liberar peça', mockJournal[txn2].state == 'RECONCILING')
        check('WORKSHOP-ABORT-02 Peça permanece RESERVED_EXTERNAL sob UNKNOWN', PE.State(entId) == 'RESERVED_EXTERNAL')

        -- WORKSHOP-ABORT-03: Provider retorna ABORTED autoritativamente -> libera peça
        mockProvider.statusReturn = 'ABORTED'
        mockProvider.abortReturn = true
        WB.BootstrapRecovery()
        check('WORKSHOP-ABORT-03 Status ABORTED com prova true libera peça para ISSUED', PE.State(entId) == 'ISSUED')
        check('WORKSHOP-ABORT-03 Journal transiciona para ABORTED', mockJournal[txn2].state == 'ABORTED')

        -- WORKSHOP-ABORT-04: AbortPurchase = false -> não libera peça (vai para QUARANTINE)
        PE.ReserveForExternal(entId, 1, 'ws:mock:txn:ab4')
        local txn4 = 'ws:mock:txn:ab4'
        mockJournal[txn4] = {
            txn_id = txn4, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entId, stable_part_id = entData.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'COMMITTING', reconcile_count = 0,
            metadata = json.encode(entData)
        }
        mockProvider.statusReturn = 'ABORTED'
        mockProvider.abortReturn = false -- Não comprovado!
        WB.BootstrapRecovery()
        check('WORKSHOP-ABORT-04 AbortPurchase false mantém peça RESERVED_EXTERNAL', PE.State(entId) == 'RESERVED_EXTERNAL')
        check('WORKSHOP-ABORT-04 Journal vai para QUARANTINE após abort não comprovado', mockJournal[txn4].state == 'QUARANTINE')

        -- WORKSHOP-ABORT-05: AbortPurchase lança exception -> fail-closed
        PE.ReserveForExternal(entId, 1, 'ws:mock:txn:ab5')
        local txn5 = 'ws:mock:txn:ab5'
        mockJournal[txn5] = {
            txn_id = txn5, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entId, stable_part_id = entData.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'COMMITTING', reconcile_count = 0,
            metadata = json.encode(entData)
        }
        mockProvider.abortReturn = nil
        mockProvider.AbortPurchase = function() error('abort_crash_simulation') end
        WB.BootstrapRecovery()
        check('WORKSHOP-ABORT-05 AbortPurchase exception mantém peça RESERVED_EXTERNAL fail-closed', PE.State(entId) == 'RESERVED_EXTERNAL')
        check('WORKSHOP-ABORT-05 Journal vai para QUARANTINE', mockJournal[txn5].state == 'QUARANTINE')
    end

    -- ─── WORKSHOP-DB-01..04: DB Failures e Circuit Breaker ──────────────────
    do
        resetEnv()
        -- WORKSHOP-DB-01: Prepare OK + journal INSERT falha
        local oldInsert = mockDb.insert.await
        mockDb.insert.await = function() return nil end
        local entDb1, _ = PE.Issue('session_db1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'DB01', model = 1234 } })
        local resDb1 = WB.HandoffPart(1, entDb1)
        check('WORKSHOP-DB-01 Falha no INSERT do journal aborta prepare e retorna journal_write_failed', resDb1.ok == false and resDb1.err == 'journal_write_failed')
        check('WORKSHOP-DB-01 Entitlement segue ISSUED após falha de DB no prepare', PE.State(entDb1) == 'ISSUED')
        check('WORKSHOP-DB-01 Provider Abort foi acionado', mockProvider.abortCalls >= 1)
        mockDb.insert.await = oldInsert

        -- WORKSHOP-DB-02A: PartEntitlement falha RESERVED -> COMMITTING -> commitCalls == 0
        resetEnv()
        local entDb2A, _ = PE.Issue('session_db2a', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'DB2A', model = 1234 } })
        local oldQuery = mockDb.query.await
        mockDb.query.await = function(sql, params)
            if sql:find("SET state = 'COMMITTING'") then return { affectedRows = 0 } end
            return oldQuery(sql, params)
        end
        mockProvider.commitCalls = 0
        local resDb2A = WB.HandoffPart(1, entDb2A)
        check('WORKSHOP-DB-02A Falha RESERVED -> COMMITTING resulta em ZERO commitCalls', mockProvider.commitCalls == 0)
        check('WORKSHOP-DB-02A Operação rejeitada com journal_update_failed', resDb2A.ok == false and resDb2A.err == 'journal_update_failed')
        mockDb.query.await = oldQuery

        -- WORKSHOP-DB-02B: stolen_plate falha PREPARED -> RESERVED -> commitCalls == 0
        resetEnv()
        _G.BridgeGetSlot = function() return { name = 'stolen_plate', count = 1, metadata = { plate = 'PL2B' } } end
        _G.BridgeRemoveItem = function() return true end
        mockDb.query.await = function(sql, params)
            if sql:find("SET state = 'RESERVED'") then return { affectedRows = 0 } end
            return oldQuery(sql, params)
        end
        mockProvider.commitCalls = 0
        local resDb2B = WB.HandoffStolenPlate(1, 1)
        check('WORKSHOP-DB-02B stolen_plate falha PREPARED -> RESERVED resulta em ZERO commitCalls', mockProvider.commitCalls == 0)
        check('WORKSHOP-DB-02B Operação rejeitada com journal_update_failed', resDb2B.ok == false and resDb2B.err == 'journal_update_failed')
        mockDb.query.await = oldQuery

        -- WORKSHOP-DB-02C: stolen_plate RESERVED ok, COMMITTING DB fail -> commitCalls == 0
        resetEnv()
        mockDb.query.await = function(sql, params)
            if sql:find("SET state = 'COMMITTING'") then return { affectedRows = 0 } end
            return oldQuery(sql, params)
        end
        mockProvider.commitCalls = 0
        local resDb2C = WB.HandoffStolenPlate(1, 1)
        check('WORKSHOP-DB-02C stolen_plate falha RESERVED -> COMMITTING resulta em ZERO commitCalls', mockProvider.commitCalls == 0)
        check('WORKSHOP-DB-02C Operação rejeitada com journal_update_failed', resDb2C.ok == false and resDb2C.err == 'journal_update_failed')
        mockDb.query.await = oldQuery

        -- WORKSHOP-DB-03: Provider pagou mas UPDATE COMMITTED falha -> circuit breaker
        resetEnv()
        local entDb3, _ = PE.Issue('session_db3', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'DB03', model = 1234 } })
        mockDb.query.await = function(sql, params)
            if sql:find("SET state = 'COMMITTED'") then return { affectedRows = 0 } end
            return oldQuery(sql, params)
        end
        local resDb3 = WB.HandoffPart(1, entDb3)
        check('WORKSHOP-DB-03 Falha pós-pagamento ativa circuit breaker e retorna workshopDegraded=true', resDb3.ok == true and resDb3.workshopDegraded == true)
        check('WORKSHOP-DB-03 WorkshopBridge entra em Integrity Locked', WB.IsIntegrityLocked() == true)
        mockDb.query.await = oldQuery

        -- WORKSHOP-DB-03B: Provider pagou mas UPDATE COMMITTED falha e SELECT retorna COMMITTING
        resetEnv()
        local entDb3B, _ = PE.Issue('session_db3b', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'DB3B', model = 1234 } })
        mockDb.query.await = function(sql, params)
            if sql:find("SET state = 'COMMITTED'") then return { affectedRows = 0 } end
            if sql:find("SELECT state FROM vp_chop_workshop_journal") then
                return { { state = 'COMMITTING' } }
            end
            return oldQuery(sql, params)
        end
        local resDb3B = WB.HandoffPart(1, entDb3B)
        check('WORKSHOP-DB-03B COMMITTED não comprovado ativa integridade locked', WB.IsIntegrityLocked() == true)
        check('WORKSHOP-DB-03B Entitlement permanece RESERVED_EXTERNAL', PE.State(entDb3B) == 'RESERVED_EXTERNAL')
        check('WORKSHOP-DB-03B Entitlement NÃO consumido', PE.State(entDb3B) ~= 'CONSUMED')
        check('WORKSHOP-DB-03B Journal NÃO finalizado em FINALIZED', mockJournal[resDb3B.txnId] ~= nil and mockJournal[resDb3B.txnId].state ~= 'FINALIZED')
        check('WORKSHOP-DB-03B Payout executado exatamente 1x e retorno degradado', resDb3B.ok == true and resDb3B.workshopDegraded == true and mockProvider.actualPayouts == 1)
        mockDb.query.await = oldQuery

        -- WORKSHOP-DB-03C: Journal já COMMITTED (affectedRows=0 mas SELECT state=COMMITTED)
        resetEnv()
        local entDb3C, _ = PE.Issue('session_db3c', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'DB3C', model = 1234 } })
        local txn3C = 'ws:mock_workshop:db3c:1'
        local data3C = PE.Get(entDb3C)
        PE.ReserveForExternal(entDb3C, 1, txn3C)
        mockJournal[txn3C] = {
            txn_id = txn3C, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entDb3C, stable_part_id = data3C.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'COMMITTED', reconcile_count = 0,
            metadata = json.encode(data3C),
        }
        local okFin3C = WB._test.finalizeCommittedTransaction('mock_workshop', txn3C, data3C.stablePartIdentity, entDb3C, false)
        check('WORKSHOP-DB-03C Journal já COMMITTED finaliza com sucesso via ensureJournalCommitted', okFin3C == true)
        check('WORKSHOP-DB-03C Entitlement consumido como CONSUMED', PE.State(entDb3C) == 'CONSUMED')
        check('WORKSHOP-DB-03C Journal transicionado para FINALIZED', mockJournal[txn3C].state == 'FINALIZED')

        -- WORKSHOP-DB-04: Provider pagou mas UPDATE FINALIZED falha -> circuit breaker
        resetEnv()
        local entDb4, _ = PE.Issue('session_db4', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'DB04', model = 1234 } })
        mockDb.query.await = function(sql, params)
            if sql:find("SET state = 'FINALIZED'") then return { affectedRows = 0 } end
            return oldQuery(sql, params)
        end
        local resDb4 = WB.HandoffPart(1, entDb4)
        check('WORKSHOP-DB-04 Falha no UPDATE FINALIZED ativa circuit breaker', WB.IsIntegrityLocked() == true)
        mockDb.query.await = oldQuery
    end

    -- ─── WORKSHOP-QUARANTINE-01..05: Quarentena e Reconciliação ─────────────
    do
        resetEnv()
        -- 01: Max attempts -> QUARANTINE
        local txnQ1 = 'ws:mock_workshop:quarantine:1'
        mockJournal[txnQ1] = {
            txn_id = txnQ1, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = 'pe:999', stable_part_id = 'spi:q:1',
            part_key = 'adv_engine', price = 3000, state = 'RECONCILING', reconcile_count = 4
        }
        mockProvider.statusReturn = 'UNKNOWN'
        WB.ReconcilePending()
        check('WORKSHOP-QUARANTINE-01 Transação excedendo MaxReconcileAttempts vai para QUARANTINE', mockJournal[txnQ1].state == 'QUARANTINE')

        -- 02: 1 tentativa com provider indisponível -> permanece RECONCILING
        resetEnv()
        local entQ2, _ = PE.Issue('session_q2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'Q2', model = 1234 } })
        local dataQ2 = PE.Get(entQ2)
        PE.ReserveForExternal(entQ2, 1, 'ws:mock_workshop:quarantine:2')
        local txnQ2 = 'ws:mock_workshop:quarantine:2'
        mockJournal[txnQ2] = {
            txn_id = txnQ2, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entQ2, stable_part_id = dataQ2.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'RECONCILING', reconcile_count = 1,
            metadata = json.encode(dataQ2),
        }
        mockProvider.isAvailable = false
        WB.ReconcilePending()
        check('WORKSHOP-QUARANTINE-02 Provider indisponível por 1 tentativa mantém transação em RECONCILING', mockJournal[txnQ2].state == 'RECONCILING')

        -- 03: Provider volta antes do limite -> resolve para FINALIZED
        mockProvider.isAvailable = true
        mockProvider.statusReturn = 'COMMITTED'
        WB.ReconcilePending()
        check('WORKSHOP-QUARANTINE-03 Provider online antes do limite resolve transação para FINALIZED', mockJournal[txnQ2].state == 'FINALIZED')

        -- 04: Transação em QUARANTINE com status COMMITTED -> resolve para FINALIZED
        resetEnv()
        local entQ4, _ = PE.Issue('session_q4', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'Q4', model = 1234 } })
        local dataQ4 = PE.Get(entQ4)
        PE.ReserveForExternal(entQ4, 1, 'ws:mock_workshop:quarantine:4')
        local txnQ4 = 'ws:mock_workshop:quarantine:4'
        mockJournal[txnQ4] = {
            txn_id = txnQ4, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entQ4, stable_part_id = dataQ4.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'QUARANTINE', reconcile_count = 5,
            metadata = json.encode(dataQ4),
        }
        mockProvider.statusReturn = 'COMMITTED'
        WB.ReconcilePending()
        check('WORKSHOP-QUARANTINE-04 Transação em QUARANTINE com status COMMITTED transiciona para FINALIZED', mockJournal[txnQ4].state == 'FINALIZED')

        -- 05: Transação em QUARANTINE com status UNKNOWN -> continua QUARANTINE
        resetEnv()
        local entQ5, _ = PE.Issue('session_q5', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'Q5', model = 1234 } })
        local dataQ5 = PE.Get(entQ5)
        PE.ReserveForExternal(entQ5, 1, 'ws:mock_workshop:quarantine:5')
        local txnQ5 = 'ws:mock_workshop:quarantine:5'
        mockJournal[txnQ5] = {
            txn_id = txnQ5, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entQ5, stable_part_id = dataQ5.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'QUARANTINE', reconcile_count = 5,
            metadata = json.encode(dataQ5),
        }
        mockProvider.statusReturn = 'UNKNOWN'
        WB.ReconcilePending()
        check('WORKSHOP-QUARANTINE-05 Transação em QUARANTINE com status UNKNOWN permanece em QUARANTINE', mockJournal[txnQ5].state == 'QUARANTINE')
    end

    -- ─── WORKSHOP-HISTORICAL-PROVIDER-01 ────────────────────────────────────
    do
        resetEnv()
        local entHist, _ = PE.Issue('session_h1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'H1', model = 1234 } })
        local dataHist = PE.Get(entHist)
        PE.ReserveForExternal(entHist, 1, 'ws:old_provider:hist:1')
        local txnHist = 'ws:old_provider:hist:1'
        mockJournal[txnHist] = {
            txn_id = txnHist, provider = 'old_provider', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entHist, stable_part_id = dataHist.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'RECONCILING', reconcile_count = 0,
            metadata = json.encode(dataHist),
        }
        Config.Broker.Workshop.Provider = 'mock_workshop'
        WB.BootstrapRecovery()
        check('WORKSHOP-HISTORICAL-PROVIDER-01 Provider histórico não registrado mantém transação em RECONCILING', mockJournal[txnHist].state == 'RECONCILING')
        check('WORKSHOP-HISTORICAL-PROVIDER-01 Provider atual (mock_workshop) NUNCA foi consultado sobre a txn de old_provider', mockProvider.statusCalls == 0)
    end

    -- ─── WORKSHOP-PROVIDER-REG-01..03: Registro Externo de Provedor ─────────
    do
        resetEnv()
        local regExport = exports.WorkshopRegisterProvider or exports['WorkshopRegisterProvider']

        -- 01: Resource correto registra com sucesso
        _G.GetInvokingResource = function() return 'valid_workshop_res' end
        local validAdapter = {
            ResourceName = 'valid_workshop_res',
            IsAvailable = function() return true end,
            PreparePurchase = function() return { ok = true, price = 1000, expiresAt = virtualTime + 30 } end,
            CommitPurchase = function() return { ok = true, paid = true } end,
            GetTransactionStatus = function() return 'COMMITTED' end,
            AbortPurchase = function() return true end,
        }
        local okReg1 = exports['WorkshopRegisterProvider']('external_shop', validAdapter)
        check('WORKSHOP-PROVIDER-REG-01 Resource correto registra com sucesso via export', okReg1 == true)

        -- 02: Resource A tenta registrar como ResourceName B -> rejeitado
        _G.GetInvokingResource = function() return 'impostor_res' end
        local impostorAdapter = {
            ResourceName = 'target_res_b',
            IsAvailable = function() return true end,
            PreparePurchase = function() return { ok = true } end,
            CommitPurchase = function() return { ok = true } end,
            GetTransactionStatus = function() return 'COMMITTED' end,
            AbortPurchase = function() return true end,
        }
        local okReg2, errReg2 = exports['WorkshopRegisterProvider']('shop_b', impostorAdapter)
        check('WORKSHOP-PROVIDER-REG-02 Resource mismatch é rejeitado', okReg2 == false)

        -- 03: Resource malicioso tenta sobrescrever provider existente de outro resource -> rejeitado
        _G.GetInvokingResource = function() return 'attacker_res' end
        local hijackAdapter = {
            ResourceName = 'attacker_res',
            IsAvailable = function() return true end,
            PreparePurchase = function() return { ok = true } end,
            CommitPurchase = function() return { ok = true } end,
            GetTransactionStatus = function() return 'COMMITTED' end,
            AbortPurchase = function() return true end,
        }
        local okReg3 = exports['WorkshopRegisterProvider']('external_shop', hijackAdapter)
        check('WORKSHOP-PROVIDER-REG-03 Hijack de provider existente por outro resource é rejeitado', okReg3 == false)
        _G.GetInvokingResource = function() return nil end
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
        mockProvider.preparePrice = 999999
        local entP1, _ = PE.Issue('session_pr1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PR01', model = 1234 } })
        local resP1 = WB.HandoffPart(1, entP1)
        check('WORKSHOP-PRICE-01 Preço acima do MaxPrice rejeitado com invalid_price', resP1.ok == false and resP1.err == 'invalid_price')

        mockProvider.preparePrice = 0/0
        local entP2, _ = PE.Issue('session_pr2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PR02', model = 1234 } })
        local resP2 = WB.HandoffPart(1, entP2)
        check('WORKSHOP-PRICE-01 Preço NaN rejeitado com invalid_price', resP2.ok == false and resP2.err == 'invalid_price')
    end

    -- ─── WORKSHOP-RECONCILE-ERROR-01: Exception em provider não quebra reconciler
    do
        resetEnv()
        local entRecErr, _ = PE.Issue('session_re', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'RE1', model = 1234 } })
        local dataRecErr = PE.Get(entRecErr)
        PE.ReserveForExternal(entRecErr, 1, 'ws:mock_workshop:rec_err:1')
        local txnRecErr = 'ws:mock_workshop:rec_err:1'
        mockJournal[txnRecErr] = {
            txn_id = txnRecErr, provider = 'mock_workshop', player_key = 'qbx:player_1',
            asset_kind = 'part_entitlement', entitlement_id = entRecErr, stable_part_id = dataRecErr.stablePartIdentity,
            part_key = 'adv_engine', price = 3000, state = 'RECONCILING', reconcile_count = 0,
            metadata = json.encode(dataRecErr),
        }
        mockProvider.isAvailable = function() error('unexpected_provider_crash') end

        WB.ReconcilePending()
        check('WORKSHOP-RECONCILE-ERROR-01 Reconciler captura exception sem crash', true)

        -- 2a varredura subsequente roda normalmente
        mockProvider.isAvailable = true
        mockProvider.statusReturn = 'COMMITTED'
        WB.ReconcilePending()
        check('WORKSHOP-RECONCILE-ERROR-01 Reconciler recupera e executa 2a varredura limpa', mockJournal[txnRecErr].state == 'FINALIZED')
    end

    -- ─── WORKSHOP-READY-01..02 & WORKSHOP-SCHEMA-01..03: Schema Readiness ──
    do
        resetEnv()
        local mockDbNoInsert = {
            query = { await = function() return {} end }
        }
        WB.Init(mockDbNoInsert)
        check('WORKSHOP-READY-01 DB com query mas sem insert resulta em IsReady() == false', WB.IsReady() == false)

        WB.Init(mockDb)
        check('WORKSHOP-READY-02 DB com query e insert válidos resulta em IsReady() == true', WB.IsReady() == true)

        -- 01: db apis existem, mas schema probe lança erro -> IsReady() == false
        local mockDbBrokenSchema = {
            query = {
                await = function(sql, params)
                    if sql:find("FROM vp_chop_workshop_journal") and sql:find("LIMIT 0") then
                        error("Table 'vp_chop_workshop_journal' doesn't exist")
                    end
                    return {}
                end
            },
            insert = { await = function() return {} end }
        }
        WB.Init(mockDbBrokenSchema)
        check('WORKSHOP-SCHEMA-01 Falha no probe de schema resulta em IsReady() == false', WB.IsReady() == false)

        -- 02: Schema probe válido -> IsReady() == true
        WB.Init(mockDb)
        check('WORKSHOP-SCHEMA-02 Schema probe bem sucedido resulta em IsReady() == true', WB.IsReady() == true)

        -- 03: Bootstrap journal SELECT falha -> BootstrapRecovery retorna false e Init is not ready
        local mockDbSelectFail = {
            query = {
                await = function(sql, params)
                    if sql:find("LIMIT 0") then return {} end
                    if sql:find("WHERE state IN") then error("MySQL connection lost during boot read") end
                    return {}
                end
            },
            insert = { await = function() return {} end }
        }
        local okInit3, errInit3 = WB.Init(mockDbSelectFail)
        check('WORKSHOP-SCHEMA-03 Falha de leitura no boot recovery resulta em Init not-ready', okInit3 == false and WB.IsReady() == false)
    end

    -- ─── WORKSHOP-MIGRATION-01: Legacy Row sem asset_kind ou stable_part_id ─
    do
        resetEnv()
        local txnLegacy = 'ws:mock_workshop:legacy:1'
        mockJournal[txnLegacy] = {
            txn_id          = txnLegacy,
            provider        = 'mock_workshop',
            player_key      = 'qbx:player_1',
            asset_kind      = nil, -- ausente / NULL
            entitlement_id  = 'pe:legacy_1',
            stable_part_id  = nil, -- ausente / NULL
            part_key        = 'adv_engine',
            price           = 3000,
            state           = 'RECONCILING',
            reconcile_count = 0,
            metadata        = nil,
        }
        mockProvider.statusCalls = 0
        WB.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
        check('WORKSHOP-MIGRATION-01 Legacy row sem stable_part_id é enviada para QUARANTINE', mockJournal[txnLegacy].state == 'QUARANTINE')
        check('WORKSHOP-MIGRATION-01 Zero chamadas ao provider sobre a legacy row', mockProvider.statusCalls == 0)
    end

    -- ─── WORKSHOP-RECONCILE-META-01: Reconcile com metadata stable mismatch ─
    do
        resetEnv()
        local entMeta1, _ = PE.Issue('session_meta1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'META1', model = 1234 } })
        local dataMeta1 = PE.Get(entMeta1)
        PE.ReserveForExternal(entMeta1, 1, 'ws:mock_workshop:meta_err:1')

        local txnMetaErr = 'ws:mock_workshop:meta_err:1'
        local corruptData = json.decode(json.encode(dataMeta1))
        corruptData.stablePartIdentity = 'spi:mismatch:999'

        mockJournal[txnMetaErr] = {
            txn_id          = txnMetaErr,
            provider        = 'mock_workshop',
            player_key      = 'qbx:player_1',
            asset_kind      = 'part_entitlement',
            entitlement_id  = entMeta1,
            stable_part_id  = dataMeta1.stablePartIdentity,
            part_key        = 'adv_engine',
            price           = 3000,
            state           = 'RECONCILING',
            reconcile_count = 1,
            metadata        = json.encode(corruptData),
        }

        mockProvider.statusCalls = 0
        WB.ReconcilePending()
        check('WORKSHOP-RECONCILE-META-01 Metadata divergente em ReconcilePending isola para QUARANTINE', mockJournal[txnMetaErr].state == 'QUARANTINE')
        check('WORKSHOP-RECONCILE-META-01 Provider status NÃO foi consultado sobre row com metadata inválida', mockProvider.statusCalls == 0)
        check('WORKSHOP-RECONCILE-META-01 Peça runtime não foi alterada indevidamente', PE.State(entMeta1) == 'RESERVED_EXTERNAL')
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

    -- ─── WORKSHOP-RACE-REAL-01: Interleaved Race Test Controlado ────────────
    do
        resetEnv()
        local entRace, _ = PE.Issue('session_race_real', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'RACE_REAL', model = 1234 } })
        local secondCallResult = nil

        WB._test.setRacePauseHook(function(stableId)
            -- Enquanto a primeira chamada está com o lock adquirido, dispara a segunda chamada concorrente
            secondCallResult = WB.HandoffPart(1, entRace)
        end)

        local firstCallResult = WB.HandoffPart(1, entRace)
        WB._test.setRacePauseHook(nil)

        check('WORKSHOP-RACE-REAL-01 Primeira chamada conclui SAGA com sucesso', firstCallResult.ok == true and firstCallResult.paid == true)
        check('WORKSHOP-RACE-REAL-01 Segunda chamada concorrente intercalada é rejeitada com external_reserved', secondCallResult ~= nil and secondCallResult.ok == false and secondCallResult.err == 'external_reserved')
        check('WORKSHOP-RACE-REAL-01 Exatamente 1 pagamento efetuado (actualPayouts == 1)', mockProvider.actualPayouts == 1)
    end

    print(('[workshop/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('workshop_spec falhou') end
end

run()
