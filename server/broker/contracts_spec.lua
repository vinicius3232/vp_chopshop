-- server/broker/contracts_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-3 / BROKER-3.1] CONTRACTS & HIGH-DEMAND LISTS SPEC
--  Testa o domínio BrokerContracts, matching server-authoritative, concorrência,
--  reserva atômica de quota, fail-closed economics e segurança BROKER-SEC-01..10.
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass = 0
    local fail = 0
    local total = 0

    local function check(desc, cond)
        total = total + 1
        if cond then
            pass = pass + 1
            print(('[broker_contracts/spec] PASS  %s'):format(desc))
        else
            fail = fail + 1
            print(('[broker_contracts/spec] FAIL  %s'):format(desc))
        end
    end

    -- ─── Mocks & Stubs de Ambiente ──────────────────────────────────────────
    local mockDbRows = {}
    local contractSeq = 100
    local cashPaid = {}
    local trustLevels = { [1] = 3, [2] = 3, [3] = 1 }
    local trustXpGained = {}
    local eventsTriggered = {}
    local virtualTime = 1700000000
    local shouldFailPayment = false

    local BM = _G.BrokerMarket
    local BC = _G.BrokerContracts
    local PE = _G.PartEntitlement

    local mockDb = {
        query = {
            await = function(sql, params)
                params = params or {}
                if sql:find('UPDATE `vp_chop_broker_contracts`', 1, true) then
                    -- UPDATE de expiração
                    if sql:find("SET `state` = 'EXPIRED'", 1, true) then
                        local expTime = params[1]
                        local count = 0
                        for _, c in pairs(mockDbRows) do
                            if (c.state == 'AVAILABLE' or c.state == 'ACCEPTED') and c.expires_at <= expTime then
                                c.state = 'EXPIRED'
                                count = count + 1
                            end
                        end
                        return { affectedRows = count }
                    end

                    -- UPDATE de compensação de reserva (com ou sem state)
                    if sql:find("SET `remaining` = `remaining` +", 1, true) then
                        if sql:find("`state` = ?", 1, true) then
                            local addCnt, restoredState, cId = params[1], params[2], params[3]
                            local c = mockDbRows[cId]
                            if c then
                                c.remaining = c.remaining + addCnt
                                c.state = restoredState
                                c.fulfilled_at = nil
                                return { affectedRows = 1 }
                            end
                        else
                            local addCnt, cId = params[1], params[2]
                            local c = mockDbRows[cId]
                            if c then
                                c.remaining = c.remaining + addCnt
                                return { affectedRows = 1 }
                            end
                        end
                        return { affectedRows = 0 }
                    end

                    -- 1. UPDATE atômico FINAL (remaining == 1 -> 0 / COMPLETED)
                    if sql:find("SET `remaining` = 0", 1, true) then
                        local curT, cId, pKey, tLev = params[1], params[2], params[3], params[4]
                        local c = mockDbRows[cId]
                        local allowsGlobal = (c and c.for_identifier == nil and c.state == 'AVAILABLE')
                        local allowsPersonal = (c and c.for_identifier == pKey and c.state == 'ACCEPTED')
                        if c and (allowsGlobal or allowsPersonal)
                           and c.remaining == 1
                           and c.min_trust <= tLev
                           and c.expires_at > curT then
                            c.remaining = 0
                            c.state = 'COMPLETED'
                            c.fulfilled_at = curT
                            return { affectedRows = 1 }
                        end
                        return { affectedRows = 0 }
                    end

                    -- 2. UPDATE atômico NÃO-FINAL (remaining > 1 -> remaining - 1)
                    if sql:find("SET `remaining` = `remaining` - 1", 1, true) then
                        local cId, pKey, tLev, curT = params[1], params[2], params[3], params[4]
                        local c = mockDbRows[cId]
                        local allowsGlobal = (c and c.for_identifier == nil and c.state == 'AVAILABLE')
                        local allowsPersonal = (c and c.for_identifier == pKey and c.state == 'ACCEPTED')
                        if c and (allowsGlobal or allowsPersonal)
                           and c.remaining > 1
                           and c.min_trust <= tLev
                           and c.expires_at > curT then
                            c.remaining = c.remaining - 1
                            return { affectedRows = 1 }
                        end
                        return { affectedRows = 0 }
                    end

                    -- UPDATE de aceitar contrato pessoal
                    if sql:find("SET `state` = 'ACCEPTED'", 1, true) then
                        local cId, pKey, tLev, curT = params[1], params[2], params[3], params[4]
                        local c = mockDbRows[cId]
                        if c and c.for_identifier == pKey and c.state == 'AVAILABLE' and c.min_trust <= tLev and c.expires_at > curT then
                            c.state = 'ACCEPTED'
                            return { affectedRows = 1 }
                        end
                        return { affectedRows = 0 }
                    end

                    return { affectedRows = 0 }
                end

                -- SELECT COUNT(*)
                if sql:find('COUNT', 1, true) then
                    local curT = params[#params]
                    local pKey = (sql:find('for_identifier` = ?', 1, true) and params[1]) or nil
                    local count = 0
                    for _, c in pairs(mockDbRows) do
                        if pKey ~= nil then
                            if c.for_identifier == pKey and (c.state == 'AVAILABLE' or c.state == 'ACCEPTED') and c.expires_at > curT then
                                count = count + 1
                            end
                        else
                            if c.for_identifier == nil and c.state == 'AVAILABLE' and c.expires_at > curT then
                                count = count + 1
                            end
                        end
                    end
                    return { { cnt = count } }
                end

                -- SELECT contrato por ID
                if sql:find('WHERE `id` = ?', 1, true) then
                    local cId = params[1]
                    local c = mockDbRows[cId]
                    if c then
                        return { {
                            id             = c.id,
                            for_identifier = c.for_identifier,
                            contract_type  = c.contract_type,
                            target_key     = c.target_key,
                            quantity       = c.quantity,
                            remaining      = c.remaining,
                            reward_mult    = c.reward_mult,
                            bonus_cash     = c.bonus_cash,
                            min_trust      = c.min_trust,
                            expires_at     = c.expires_at,
                            created_at     = c.created_at,
                            fulfilled_at   = c.fulfilled_at,
                            state          = c.state,
                        } }
                    end
                    return {}
                end

                -- SELECT de contratos visíveis (GetAvailable)
                if sql:find('FROM `vp_chop_broker_contracts`', 1, true) then
                    local pKey, curT, tLev = params[1], params[2], params[3]
                    local out = {}
                    for _, c in pairs(mockDbRows) do
                        local isMatch = false
                        if c.for_identifier == nil and c.state == 'AVAILABLE' and c.expires_at > curT and c.min_trust <= tLev then
                            isMatch = true
                        elseif c.for_identifier == pKey and (c.state == 'AVAILABLE' or c.state == 'ACCEPTED') and c.expires_at > curT and c.min_trust <= tLev then
                            isMatch = true
                        end
                        if isMatch then
                            out[#out + 1] = {
                                id             = c.id,
                                for_identifier = c.for_identifier,
                                contract_type  = c.contract_type,
                                target_key     = c.target_key,
                                quantity       = c.quantity,
                                remaining      = c.remaining,
                                reward_mult    = c.reward_mult,
                                bonus_cash     = c.bonus_cash,
                                min_trust      = c.min_trust,
                                expires_at     = c.expires_at,
                                created_at     = c.created_at,
                                state          = c.state,
                            }
                        end
                    end
                    return out
                end

                return {}
            end,
        },
        insert = {
            await = function(sql, params)
                contractSeq = contractSeq + 1
                local id = contractSeq
                local forId, cType, tKey, qty, rem, rMult, bCash, mTrust, cAt, expAt
                if sql:find('VALUES (NULL,', 1, true) then
                    forId = nil
                    cType, tKey, qty, rem, rMult, bCash, mTrust, cAt, expAt =
                        params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9]
                else
                    forId, cType, tKey, qty, rem, rMult, bCash, mTrust, cAt, expAt =
                        params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10]
                end

                mockDbRows[id] = {
                    id             = id,
                    for_identifier = forId,
                    contract_type  = cType,
                    target_key     = tKey,
                    quantity       = qty,
                    remaining      = rem or qty,
                    reward_mult    = rMult,
                    bonus_cash     = bCash or 0,
                    min_trust      = mTrust or 1,
                    created_at     = cAt,
                    expires_at     = expAt,
                    fulfilled_at   = nil,
                    state          = 'AVAILABLE',
                }
                return id
            end,
        },
    }

    local function resetEnv()
        mockDbRows = {}
        contractSeq = 100
        cashPaid = {}
        trustLevels = { [1] = 3, [2] = 3, [3] = 1 }
        trustXpGained = {}
        eventsTriggered = {}
        virtualTime = 1700000000
        shouldFailPayment = false

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 10000
        Config.Broker.Enable = true
        if Config.Broker.Contracts then Config.Broker.Contracts.Enable = true end

        BM.SetIntegrityLock(false)
        BM.Init(function() return virtualTime end, mockDb, function() return 0.5 end)
        BC.Init(mockDb, function() return virtualTime end, function() return 0.5 end)

        if PE and PE._test then PE._test.reset() end
        if VPChopFence and VPChopFence._test then
            VPChopFence._test.clearTrust()
            VPChopFence._test.clearQuarantine()
            if VPChopFence._test.clearOrderGenBusy then VPChopFence._test.clearOrderGenBusy() end
            VPChopFence._test.setTrust(1, 3, 500)
            VPChopFence._test.setTrust(2, 3, 500)
            VPChopFence._test.setTrust(3, 1, 100)
        end
    end

    local origVPChopFenceGetTrust = _G.VPChopFenceGetTrust
    local origVPChopGetProgression = _G.VPChopGetProgression
    local origVPChopFenceCurrentLocation = _G.VPChopFenceCurrentLocation
    local origBridgeAddCash = _G.BridgeAddCash
    local origVPChopHeatGetPriceMult = _G.VPChopHeatGetPriceMult

    _G.VPChopFenceGetTrust = function(src) return trustLevels[src] or 0 end
    _G.VPChopGetProgression = function(src) return { tier = 2, xp = 200 } end
    _G.VPChopFenceCurrentLocation = function() return { coords = vector3(0.0, 0.0, 0.0) } end
    _G.VPChopHeatGetPriceMult = function(plate) return 1.0 end
    _G.BridgeAddCash = function(src, amount, reason)
        if shouldFailPayment then return false end
        cashPaid[src] = (cashPaid[src] or 0) + amount
        return true
    end

    local getContractsCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:broker:getContracts']
    local acceptContractCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:broker:acceptContract']
    local fulfillContractCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:broker:fulfillContract']
    local getOrderCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:getOrder']
    local fulfillOrderCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:fulfillOrder']
    local deliverCarCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:deliverCar']

    local function createContract(forId, cType, tKey, qty, rMult, bCash, mTrust, expSecs, st)
        contractSeq = contractSeq + 1
        local id = contractSeq
        mockDbRows[id] = {
            id             = id,
            for_identifier = forId,
            contract_type  = cType,
            target_key     = tKey,
            quantity       = qty or 1,
            remaining      = qty or 1,
            reward_mult    = rMult or 1.20,
            bonus_cash     = bCash or 0,
            min_trust      = mTrust or 1,
            created_at     = virtualTime,
            expires_at     = virtualTime + (expSecs or 3600),
            fulfilled_at   = nil,
            state          = st or (forId and 'ACCEPTED' or 'AVAILABLE'),
        }
        return id
    end

    -- ─── BROKER-SEC Suite ───────────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
        local res = fulfillContractCb(1, cId, 'forged_fake_id_999')
        check('BROKER-SEC-01 Entitlement inexistente/forjado rejeitado', res.ok == false and (res.err == 'not_found' or res.err == 'invalid_entitlement' or res.err == 'invalid'))
        check('BROKER-SEC-01 Zero pagamento efetuado para entitlement forjado', (cashPaid[1] or 0) == 0)
        check('BROKER-SEC-01 Contrato segue intacto após tentativa forjada', mockDbRows[cId].remaining == 1)
    end

    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
        local entA, _ = PE.Issue('session_sec2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC02A', model = 1234 } })
        local res = fulfillContractCb(2, cId, entA)
        check('BROKER-SEC-02 Venda de entitlement alheio rejeitada com owner_mismatch', res.ok == false and res.err == 'owner_mismatch')
        check('BROKER-SEC-02 Zero pagamento efetuado para o impostor B', (cashPaid[2] or 0) == 0)
        check('BROKER-SEC-02 Entitlement do Player A segue ISSUED', PE.State(entA) == 'ISSUED')
    end

    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
        local ent3, _ = PE.Issue('session_sec3', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC03', model = 1234 } })
        PE.Consume(ent3, 1, 'bench_test', 'adv_engine')
        local res = fulfillContractCb(1, cId, ent3)
        check('BROKER-SEC-03 Entitlement já consumido rejeitado com already_consumed', res.ok == false and res.err == 'already_consumed')
        check('BROKER-SEC-03 Zero pagamento efetuado para peça já consumida', (cashPaid[1] or 0) == 0)
    end

    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
        local doorEnt, _ = PE.Issue('session_sec4', 1, 'door_dside_f', 10, { origin = 'advanced', provenance = { realPlate = 'SEC04', model = 1234 } })
        local res = fulfillContractCb(1, cId, doorEnt)
        check('BROKER-SEC-04 Entrega de peça incompatível rejeitada com wrong_part', res.ok == false and res.err == 'wrong_part')
        check('BROKER-SEC-04 Entitlement incompatível segue ISSUED', PE.State(doorEnt) == 'ISSUED')
        check('BROKER-SEC-04 Quota do contrato segue intacta', mockDbRows[cId].remaining == 1)
    end

    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1, -100)
        local eng5, _ = PE.Issue('session_sec5', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC05', model = 1234 } })
        local res = fulfillContractCb(1, cId, eng5)
        check('BROKER-SEC-05 Entrega para contrato expirado rejeitada com contract_expired', res.ok == false and res.err == 'contract_expired')
        check('BROKER-SEC-05 Entitlement segue ISSUED após contrato expirado', PE.State(eng5) == 'ISSUED')
    end

    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
        local eng6A, _ = PE.Issue('session_sec6A', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC06A', model = 1234 } })
        local eng6B, _ = PE.Issue('session_sec6B', 2, 'adv_engine', 11, { origin = 'advanced', provenance = { realPlate = 'SEC06B', model = 1234 } })

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local res6A = fulfillContractCb(1, cId, eng6A)
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local res6B = fulfillContractCb(2, cId, eng6B)

        check('BROKER-SEC-06 Primeira chamada concorrente tem sucesso', res6A.ok == true)
        check('BROKER-SEC-06 Segunda chamada concorrente rejeitada com contract_fulfilled ou contract_busy', res6B.ok == false and (res6B.err == 'contract_fulfilled' or res6B.err == 'contract_unavailable' or res6B.err == 'contract_busy'))
        check('BROKER-SEC-06 Player A foi pago e Player B recebeu ZERO', (cashPaid[1] or 0) > 0 and (cashPaid[2] or 0) == 0)
        check('BROKER-SEC-06 Entitlement B segue ISSUED', PE.State(eng6B) == 'ISSUED')
    end

    do
        resetEnv()
        local cId = createContract(nil, 'model', 'sultan', 1, 1.35, 0, 1)
        local sultanHash = GetHashKey('sultan')
        local bisonHash = GetHashKey('bison')
        local eng7Bison, _ = PE.Issue('session_sec7', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'BISON01', model = bisonHash } })
        local res = fulfillContractCb(1, cId, eng7Bison)
        check('BROKER-SEC-07 Modelo incorreto rejeitado pelo servidor com wrong_part', res.ok == false and res.err == 'wrong_part')
    end

    do
        resetEnv()
        local cId = createContract(nil, 'class', 'sports', 1, 1.30, 0, 1)
        local eng8SUV, _ = PE.Issue('session_sec8', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SUV01', model = 1234, vehicleClass = 2, className = 'suvs' } })
        local res = fulfillContractCb(1, cId, eng8SUV)
        check('BROKER-SEC-08 Classe incorreta rejeitada pelo servidor com wrong_part', res.ok == false and res.err == 'wrong_part')
    end

    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1)
        local eng9, _ = PE.Issue('session_sec9', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC09', model = 1234 } })
        local res = fulfillContractCb(1, cId, eng9)
        local expectedBase = BM.ResolvePrice('adv_engine', { trustLevel = 3, progressionTier = 2, heatMultiplier = 1.0, jitter = 0.0 }).unitPrice
        local expectedPayout = math.floor(expectedBase * 1.20)
        check('BROKER-SEC-09 Payout calculado exclusivamente pelo servidor', res.ok == true and res.payout == expectedPayout)
    end

    do
        resetEnv()
        trustLevels[3] = 1
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.50, 0, 3)
        local eng10, _ = PE.Issue('session_sec10', 3, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC10', model = 1234 } })
        local res = fulfillContractCb(3, cId, eng10)
        check('BROKER-SEC-10 Jogador com Trust insuficiente rejeitado com trust_gate', res.ok == false and res.err == 'trust_gate')
        check('BROKER-SEC-10 Entitlement de Trust insuficiente segue ISSUED', PE.State(eng10) == 'ISSUED')
    end

    -- ─── CONTRACT-BOOT Suite ────────────────────────────────────────────────
    do
        resetEnv()
        BC._test.setReady(false)
        BC._test.setDb(nil)
        check('CONTRACT-BOOT-01 Inicialmente não ready', BC.IsReady() == false)
        _G.TriggerEvent('vp_chopshop:server:dbReady')
        check('CONTRACT-BOOT-01 IsReady=true após evento dbReady', BC.IsReady() == true)

        BC.Init({ query = {} })
        check('CONTRACT-BOOT-02 DB com API incompleta resulta em IsReady=false', BC.IsReady() == false)
        BC.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
    end

    -- ─── CONTRACT-DB Suite ──────────────────────────────────────────────────
    do
        resetEnv()
        BC.Init(false)
        local resDb = getContractsCb(1)
        check('CONTRACT-DB-01 getContracts falha com contracts_not_ready quando DB ausente', resDb.ok == false and resDb.err == 'contracts_not_ready')
        local resFulfill = fulfillContractCb(1, 101, 'pe:test')
        check('CONTRACT-DB-01 fulfillContract falha com contracts_not_ready quando DB ausente', resFulfill.ok == false and resFulfill.err == 'contracts_not_ready')
        BC.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
    end

    -- ─── CONTRACT-GLOBAL Suite ──────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 2, 1.20, 0, 1)
        local engG1, _ = PE.Issue('session_glob1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'GLOB1', model = 1234 } })
        local engG2, _ = PE.Issue('session_glob2', 2, 'adv_engine', 11, { origin = 'advanced', provenance = { realPlate = 'GLOB2', model = 1234 } })

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resG1 = fulfillContractCb(1, cId, engG1)
        check('CONTRACT-GLOBAL-01 Player A entrega 1a unidade do contrato global', resG1.ok == true and resG1.remaining == 1 and resG1.completed == false)
        check('CONTRACT-GLOBAL-01 Contrato global permanece AVAILABLE com remaining=1', mockDbRows[cId].state == 'AVAILABLE' and mockDbRows[cId].remaining == 1)

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resG2 = fulfillContractCb(2, cId, engG2)
        check('CONTRACT-GLOBAL-01 Player B entrega 2a unidade concluindo o contrato global', resG2.ok == true and resG2.remaining == 0 and resG2.completed == true)
        check('CONTRACT-GLOBAL-01 Contrato global transiciona para COMPLETED', mockDbRows[cId].state == 'COMPLETED' and mockDbRows[cId].remaining == 0)
    end

    -- ─── CONTRACT-RACE-REAL Suite ───────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract('qbx:player_1', 'part_type', 'adv_engine', 2, 1.20, 5000, 3, 3600, 'ACCEPTED')
        local engA, _ = PE.Issue('session_race_a', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'RACEA', model = 1234 } })
        local engB, _ = PE.Issue('session_race_b', 1, 'adv_engine', 11, { origin = 'advanced', provenance = { realPlate = 'RACEB', model = 1234 } })

        local raceInterleavedRes = nil
        BC._test.setHookBeforeConsume(function(hookCId, hookSrc, hookEntId)
            _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
            raceInterleavedRes = fulfillContractCb(1, cId, engB)
        end)

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resA = fulfillContractCb(1, cId, engA)
        BC._test.setHookBeforeConsume(nil)

        check('CONTRACT-RACE-REAL-01 Operação intercalada B é rejeitada com contract_busy', raceInterleavedRes ~= nil and raceInterleavedRes.ok == false and raceInterleavedRes.err == 'contract_busy')
        check('CONTRACT-RACE-REAL-01 Entitlement B seguiu ISSUED durante lock de A', PE.State(engB) == 'ISSUED')
        check('CONTRACT-RACE-REAL-01 Operação A concluiu 1a unidade (remaining 2->1, bonus 0)', resA.ok == true and resA.remaining == 1 and resA.bonusCash == 0)

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resBRetry = fulfillContractCb(1, cId, engB)
        check('CONTRACT-RACE-REAL-01 Retry de B conclui 2a unidade (remaining 1->0, completed=true, bonus=5000)', resBRetry.ok == true and resBRetry.remaining == 0 and resBRetry.completed == true and resBRetry.bonusCash == 5000)
    end

    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 2, 1.20, 0, 1)
        local engSame, _ = PE.Issue('session_same', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SAME', model = 1234 } })

        local doubleFireRes = nil
        BC._test.setHookBeforeConsume(function(hookCId, hookSrc, hookEntId)
            _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
            doubleFireRes = fulfillContractCb(1, cId, engSame)
        end)

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resSame = fulfillContractCb(1, cId, engSame)
        BC._test.setHookBeforeConsume(nil)

        check('CONTRACT-RACE-REAL-02 Double-fire concorrente com mesmo entitlement rejeitado com contract_busy', doubleFireRes ~= nil and doubleFireRes.ok == false and doubleFireRes.err == 'contract_busy')
        check('CONTRACT-RACE-REAL-02 Apenas 1 consumo efetivo e quota do contrato preservada em 1', mockDbRows[cId].remaining == 1)
    end

    -- ─── CONTRACT-BONUS-RACE Suite ──────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract('qbx:player_1', 'part_type', 'adv_engine', 2, 1.20, 5000, 3, 3600, 'ACCEPTED')
        local engBR1, _ = PE.Issue('session_br1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'BR1', model = 1234 } })
        local engBR2, _ = PE.Issue('session_br2', 1, 'adv_engine', 11, { origin = 'advanced', provenance = { realPlate = 'BR2', model = 1234 } })

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resBR1 = fulfillContractCb(1, cId, engBR1)
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resBR2 = fulfillContractCb(1, cId, engBR2)
        local totalBonusPaid = (resBR1.bonusCash or 0) + (resBR2.bonusCash or 0)
        check('CONTRACT-BONUS-RACE-01 Soma de bonusCash paga no ciclo inteiro é exatamente 5000 (nunca 10000)', totalBonusPaid == 5000)
    end

    -- ─── CONTRACT-POOL Suite ────────────────────────────────────────────────
    do
        resetEnv()
        local pPool = Config.Broker.Contracts.Pools.part_type or {}
        local hasTyre = false
        for _, item in ipairs(pPool) do
            if item.key == 'tyre' then hasTyre = true end
        end
        check('CONTRACT-POOL-01 tyre removido do pool part_type', hasTyre == false)
    end

    -- ─── CONTRACT-LOC Suite ─────────────────────────────────────────────────
    do
        resetEnv()
        _G.VPChopFenceCurrentLocation = function() return nil end
        local resLoc1 = getContractsCb(1)
        check('CONTRACT-LOC-01 getContracts retorna no_fence quando fence location ausente', resLoc1.ok == false and resLoc1.err == 'no_fence')
        local resLoc2 = acceptContractCb(1, 101)
        check('CONTRACT-LOC-02 acceptContract retorna no_fence quando fence location ausente', resLoc2.ok == false and resLoc2.err == 'no_fence')
        local resLoc3 = fulfillContractCb(1, 101, 'pe:test')
        check('CONTRACT-LOC-03 fulfillContract retorna no_fence quando fence location ausente', resLoc3.ok == false and resLoc3.err == 'no_fence')
        _G.VPChopFenceCurrentLocation = function() return { coords = vector3(0.0, 0.0, 0.0) } end
    end

    -- ─── CONTRACT-TERMS Suite ───────────────────────────────────────────────
    do
        resetEnv()
        local cIdT1 = createContract(nil, 'part_type', 'adv_engine', 1, 2.50, 0, 1)
        local engT1, _ = PE.Issue('session_t1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'T1', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resT1 = fulfillContractCb(1, cIdT1, engT1)
        check('CONTRACT-TERMS-01 rewardMult acima do config max rejeitado com invalid_contract_terms', resT1.ok == false and resT1.err == 'invalid_contract_terms')
        check('CONTRACT-TERMS-01 Entitlement segue ISSUED', PE.State(engT1) == 'ISSUED')

        local cIdT2 = createContract(nil, 'part_type', 'adv_engine', 1, 0/0, 0, 1)
        local engT2, _ = PE.Issue('session_t2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'T2', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resT2 = fulfillContractCb(1, cIdT2, engT2)
        check('CONTRACT-TERMS-02 rewardMult NaN rejeitado com invalid_contract_terms', resT2.ok == false and resT2.err == 'invalid_contract_terms')

        local cIdT3 = createContract('qbx:player_1', 'part_type', 'adv_engine', 1, 1.20, 25000, 3, 3600, 'ACCEPTED')
        local engT3, _ = PE.Issue('session_t3', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'T3', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resT3 = fulfillContractCb(1, cIdT3, engT3)
        check('CONTRACT-TERMS-03 bonusCash acima do config max rejeitado com invalid_contract_terms', resT3.ok == false and resT3.err == 'invalid_contract_terms')

        local cIdT4 = createContract('qbx:player_1', 'part_type', 'adv_engine', 1, 1.20, -500, 3, 3600, 'ACCEPTED')
        local engT4, _ = PE.Issue('session_t4', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'T4', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resT4 = fulfillContractCb(1, cIdT4, engT4)
        check('CONTRACT-TERMS-04 bonusCash negativo rejeitado com invalid_contract_terms', resT4.ok == false and resT4.err == 'invalid_contract_terms')

        local cIdT5 = createContract(nil, 'part_type', 'adv_engine', 2, 1.20, 0, 1)
        mockDbRows[cIdT5].remaining = 5
        local engT5, _ = PE.Issue('session_t5', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'T5', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resT5 = fulfillContractCb(1, cIdT5, engT5)
        check('CONTRACT-TERMS-05 remaining > quantity rejeitado com invalid_contract_terms', resT5.ok == false and resT5.err == 'invalid_contract_terms')
    end

    -- ─── CONTRACT-PRICE-FAIL Suite (BROKER-3.2) ─────────────────────────────
    do
        -- CONTRACT-PRICE-FAIL-01: Config.Broker.Enable = false retorna broker_disabled
        resetEnv()
        Config.Broker.Enable = false
        local cIdP1 = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1)
        local engP1, _ = PE.Issue('session_p1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PRICE1', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resP1 = fulfillContractCb(1, cIdP1, engP1)
        check('CONTRACT-PRICE-FAIL-01 Broker desabilitado retorna broker_disabled sem exception', resP1 ~= nil and resP1.ok == false and resP1.err == 'broker_disabled')
        check('CONTRACT-PRICE-FAIL-01 Entitlement segue ISSUED após broker_disabled', PE.State(engP1) == 'ISSUED')
        check('CONTRACT-PRICE-FAIL-01 Quota do contrato permanece intacta (1)', mockDbRows[cIdP1].remaining == 1)
        check('CONTRACT-PRICE-FAIL-01 Zero pagamento efetuado (cashPaid == 0)', (cashPaid[1] or 0) == 0)
        Config.Broker.Enable = true
    end

    do
        -- CONTRACT-PRICE-FAIL-02: Commodity ausente no BrokerMarket retorna unknown_commodity
        resetEnv()
        local oldComm = Config.Broker.Commodities and Config.Broker.Commodities.adv_engine
        Config.Broker.Commodities.adv_engine = nil
        local cIdP2 = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1)
        local engP2, _ = PE.Issue('session_p2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PRICE2', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resP2 = fulfillContractCb(1, cIdP2, engP2)
        check('CONTRACT-PRICE-FAIL-02 Commodity desconhecida retorna unknown_commodity sem exception', resP2 ~= nil and resP2.ok == false and resP2.err == 'unknown_commodity')
        check('CONTRACT-PRICE-FAIL-02 Entitlement segue ISSUED após unknown_commodity', PE.State(engP2) == 'ISSUED')
        check('CONTRACT-PRICE-FAIL-02 Quota do contrato permanece intacta (1)', mockDbRows[cIdP2].remaining == 1)
        check('CONTRACT-PRICE-FAIL-02 Zero pagamento efetuado (cashPaid == 0)', (cashPaid[1] or 0) == 0)
        Config.Broker.Commodities.adv_engine = oldComm
    end

    do
        -- CONTRACT-PRICE-FAIL-03: ResolvePrice com unitPrice nil/inválido retorna invalid_price
        resetEnv()
        local origResolve = BM.ResolvePrice
        BM.ResolvePrice = function(...) return { ok = true, unitPrice = nil } end
        local cIdP3 = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1)
        local engP3, _ = PE.Issue('session_p3', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PRICE3', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resP3 = fulfillContractCb(1, cIdP3, engP3)
        check('CONTRACT-PRICE-FAIL-03 unitPrice nil retorna invalid_price sem exception', resP3 ~= nil and resP3.ok == false and resP3.err == 'invalid_price')
        check('CONTRACT-PRICE-FAIL-03 Entitlement segue ISSUED após invalid_price', PE.State(engP3) == 'ISSUED')
        check('CONTRACT-PRICE-FAIL-03 Quota do contrato permanece intacta (1)', mockDbRows[cIdP3].remaining == 1)
        check('CONTRACT-PRICE-FAIL-03 Zero pagamento efetuado (cashPaid == 0)', (cashPaid[1] or 0) == 0)
        BM.ResolvePrice = origResolve
    end

    -- ─── CONTRACT-GEN Suite ─────────────────────────────────────────────────
    do
        resetEnv()
        BC.EnsureGlobalContracts(virtualTime)
        BC.EnsureGlobalContracts(virtualTime)
        local globContracts = BC.GetAvailable('qbx:player_1', 3, virtualTime)
        local gCount = 0
        for _, c in ipairs(globContracts) do if c.isGlobal then gCount = gCount + 1 end end
        check('CONTRACT-GEN-RACE-01 Total de contratos globais gerados <= GlobalSlots (3)', gCount <= 3)

        local pCount = 0
        for _, c in ipairs(globContracts) do if not c.isGlobal then pCount = pCount + 1 end end
        check('CONTRACT-GEN-RACE-02 Total de contratos pessoais gerados <= PersonalSlots (3)', pCount <= 3)
    end

    -- ─── CONTRACT-RNG Suite ─────────────────────────────────────────────────
    do
        resetEnv()
        BC._test.setRng(function() return 0.0 end)
        local q0 = BC._test.randInt(1, 10)
        BC._test.setRng(function() return 0.999 end)
        local q1 = BC._test.randInt(1, 10)
        check('CONTRACT-RNG-01 randInt respeita o seam _rng determinístico', q0 == 1 and q1 == 10)
        BC._test.setRng(function() return 0.5 end)
    end

    -- ─── CONTRACT-GEN-DB Suite ──────────────────────────────────────────────
    do
        resetEnv()
        local origInsert = mockDb.insert.await
        mockDb.insert.await = function() return nil end
        local genNil = BC.EnsureGlobalContracts(virtualTime)
        check('CONTRACT-GEN-DB-01 db.insert retornando nil resulta em 0 gerados', genNil == 0)
        mockDb.insert.await = origInsert
    end

    -- ─── CONTRACT-PERSONAL-ACCEPT Suite ─────────────────────────────────────
    do
        resetEnv()
        local cId = createContract('qbx:player_1', 'part_type', 'adv_engine', 1, 1.25, 2000, 3, 3600, 'AVAILABLE')
        local eng, _ = PE.Issue('session_pa', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PA01', model = 1234 } })

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local res1 = fulfillContractCb(1, cId, eng)
        check('CONTRACT-PERSONAL-ACCEPT-01 Contrato pessoal AVAILABLE rejeitado no fulfill com contract_not_accepted', res1.ok == false and res1.err == 'contract_not_accepted')
        check('CONTRACT-PERSONAL-ACCEPT-01 Entitlement segue ISSUED após rejeição', PE.State(eng) == 'ISSUED')

        local resAcc = acceptContractCb(1, cId)
        check('CONTRACT-PERSONAL-ACCEPT-01 Player aceita contrato pessoal com sucesso', resAcc.ok == true)
        check('CONTRACT-PERSONAL-ACCEPT-01 Estado do contrato tornou-se ACCEPTED', mockDbRows[cId].state == 'ACCEPTED')

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local res2 = fulfillContractCb(1, cId, eng)
        check('CONTRACT-PERSONAL-ACCEPT-01 Contrato pessoal ACCEPTED liquidado com sucesso', res2.ok == true and res2.completed == true)
    end

    -- ─── CONTRACT-MODEL-HASH Suite ──────────────────────────────────────────
    do
        resetEnv()
        local signedModel = -1002345
        local unsignedModel = signedModel + 4294967296
        local h1 = BC._test.normHash32(signedModel)
        local h2 = BC._test.normHash32(unsignedModel)
        check('CONTRACT-MODEL-HASH-01 normHash32 produz uint32 idêntico para signed e unsigned', h1 == h2 and h1 >= 0 and h1 < 4294967296)

        local hDiff = BC._test.normHash32(123456)
        check('CONTRACT-MODEL-HASH-02 Hash diferente produz valor distinto', h1 ~= hDiff)
    end

    -- ─── CONTRACT-RACE-02 Suite ─────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 2, 1.20, 0, 1)
        local engRace, _ = PE.Issue('session_race2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'RACE2', model = 1234 } })

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resR1 = fulfillContractCb(1, cId, engRace)
        check('CONTRACT-RACE-02 Primeiro disparo tem sucesso', resR1.ok == true)

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resR2 = fulfillContractCb(1, cId, engRace)
        check('CONTRACT-RACE-02 Segundo disparo rejeitado com already_consumed', resR2.ok == false and resR2.err == 'already_consumed')
        check('CONTRACT-RACE-02 Quota do contrato não foi perdida (permanece 1)', mockDbRows[cId].remaining == 1)
    end

    -- ─── CONTRACT-PERSONAL-01 Suite ─────────────────────────────────────────
    do
        resetEnv()
        local pKeyA = 'qbx:player_1'
        local cId = createContract(pKeyA, 'part_type', 'adv_engine', 1, 1.30, 2000, 3, 3600, 'AVAILABLE')

        local resAccB = acceptContractCb(2, cId)
        check('CONTRACT-PERSONAL-01 Player B não pode aceitar contrato pessoal de A (owner_mismatch)', resAccB.ok == false and resAccB.err == 'owner_mismatch')

        local resAccA = acceptContractCb(1, cId)
        check('CONTRACT-PERSONAL-01 Player A aceita seu contrato com sucesso', resAccA.ok == true)
        check('CONTRACT-PERSONAL-01 Estado do contrato pessoal avança para ACCEPTED', mockDbRows[cId].state == 'ACCEPTED')

        local engPersB, _ = PE.Issue('session_pb', 2, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PERB', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resFulB = fulfillContractCb(2, cId, engPersB)
        check('CONTRACT-PERSONAL-01 Player B não pode cumprir contrato pessoal de A (owner_mismatch)', resFulB.ok == false and resFulB.err == 'owner_mismatch')
    end

    -- ─── CONTRACT-MODEL-01 Suite ────────────────────────────────────────────
    do
        resetEnv()
        local sultanH = GetHashKey('sultan')
        local cId = createContract(nil, 'model', 'sultan', 1, 1.35, 0, 1)

        local engSultan, _ = PE.Issue('session_sultan', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SULTAN1', model = sultanH } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resModOk = fulfillContractCb(1, cId, engSultan)
        check('CONTRACT-MODEL-01 Modelo correto (sultan) dá match e liquida', resModOk.ok == true)
    end

    -- ─── CONTRACT-CLASS Suite ───────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'class', 'sports', 1, 1.30, 0, 1)

        local engNoClass, _ = PE.Issue('session_noclass', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'NOCLASS', model = 1234, className = nil, vehicleClass = nil } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resNoClass = fulfillContractCb(1, cId, engNoClass)
        check('CONTRACT-CLASS-02 Provenance de classe ausente falha closed com provenance_class_missing', resNoClass.ok == false and resNoClass.err == 'provenance_class_missing')

        local engSports, _ = PE.Issue('session_sports', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SPORTS1', model = 1234, className = 'sports', vehicleClass = 6 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resSports = fulfillContractCb(1, cId, engSports)
        check('CONTRACT-CLASS-01 Classe correta (sports) dá match e liquida', resSports.ok == true)
    end

    -- ─── CONTRACT-HIGHVALUE Suite ───────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'high_value', 'unauthorized_target_item', 1, 1.50, 0, 1)
        local engBadHigh, _ = PE.Issue('session_badhigh', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'BADHIGH', model = 1234 } })
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resBadHigh = fulfillContractCb(1, cId, engBadHigh)
        check('CONTRACT-HIGHVALUE-01 Target fora da allowlist rejeitado com invalid_high_value_target', resBadHigh.ok == false and resBadHigh.err == 'invalid_high_value_target')
    end

    -- ─── CONTRACT-EXPIRY Suite ──────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1, 500)
        virtualTime = virtualTime + 600
        local expiredCount = BC.ExpireDue(virtualTime)
        check('CONTRACT-EXPIRY-01 ExpireDue identifica e purga contrato vencido', expiredCount == 1 and mockDbRows[cId].state == 'EXPIRED')
    end

    -- ─── CONTRACT-RESTART Suite ─────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 2, 1.25, 0, 1)
        mockDbRows[cId].remaining = 1
        BC.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
        local loadedRest = BC.Get(cId)
        check('CONTRACT-RESTART-01 Contrato recuperado pós-reboot com remaining=1 intacto', loadedRest ~= nil and loadedRest.remaining == 1 and loadedRest.quantity == 2)
    end

    -- ─── CONTRACT-PAY Suite ─────────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
        local engPayFail, _ = PE.Issue('session_payfail', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PAYFAIL', model = 1234 } })
        shouldFailPayment = true

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resPayFail = fulfillContractCb(1, cId, engPayFail)
        check('CONTRACT-PAY-01 Falha de pagamento retorna payment_failed', resPayFail.ok == false and resPayFail.err == 'payment_failed')
        check('CONTRACT-PAY-01 Flag terminalConsumed=true retornada ao client', resPayFail.terminalConsumed == true)
        check('CONTRACT-PAY-01 Entitlement permanece terminal CONSUMED (fail-closed anti-dupe)', PE.State(engPayFail) == 'CONSUMED')
        check('CONTRACT-PAY-01 Quota do contrato permanece reservada', mockDbRows[cId].remaining == 0 and mockDbRows[cId].state == 'COMPLETED')
        shouldFailPayment = false
    end

    -- ─── CONTRACT-BONUS Suite ───────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract('qbx:player_1', 'part_type', 'adv_engine', 2, 1.20, 5000, 3, 3600, 'ACCEPTED')

        local engB1, _ = PE.Issue('session_b1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'BONUS1', model = 1234 } })
        local engB2, _ = PE.Issue('session_b2', 1, 'adv_engine', 11, { origin = 'advanced', provenance = { realPlate = 'BONUS2', model = 1234 } })

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resB1 = fulfillContractCb(1, cId, engB1)
        check('CONTRACT-BONUS-01 1a entrega (remaining 2->1) NÃO paga bonus_cash', resB1.ok == true and resB1.bonusCash == 0 and resB1.completed == false)

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resB2 = fulfillContractCb(1, cId, engB2)
        check('CONTRACT-BONUS-01 2a entrega (remaining 1->0) PAGA bonus_cash exatamente 1x', resB2.ok == true and resB2.bonusCash == 5000 and resB2.completed == true)
    end

    -- ─── CONTRACT-MARKET Suite ──────────────────────────────────────────────
    do
        resetEnv()
        local cId = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1)
        local engMkt, _ = PE.Issue('session_mkt', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'MKT01', model = 1234 } })

        local demBefore = BM.GetDemandIndex('adv_engine', virtualTime)
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
        local resMkt = fulfillContractCb(1, cId, engMkt)
        local demAfter = BM.GetDemandIndex('adv_engine', virtualTime)
        check('CONTRACT-MARKET-01 Fulfillment de contrato tem sucesso financeiro', resMkt.ok == true)
        check('CONTRACT-MARKET-01 Demanda do mercado geral permaneceu inalterada (zero RecordSalesBatch)', math.abs(demAfter - demBefore) < 0.0001)
    end

    -- ─── CONTRACT-LEGACY Suite ──────────────────────────────────────────────
    do
        resetEnv()
        if getOrderCb then
            local oldSingle = _G.MySQL.single.await
            local oldInsert = _G.MySQL.insert.await
            _G.MySQL.single.await = function(...) return nil end
            _G.MySQL.insert.await = function(...) return 42 end
            local resLegOrder = getOrderCb(1)
            check('CONTRACT-LEGACY-01 getOrder legado permanece operacional', resLegOrder ~= nil and resLegOrder.id ~= nil)
            _G.MySQL.single.await = oldSingle
            _G.MySQL.insert.await = oldInsert
        end
        if fulfillOrderCb then
            local resLegFulfill = fulfillOrderCb(1, 99999)
            check('CONTRACT-LEGACY-02 fulfillOrder legado rejeita ID inexistente com no_order', resLegFulfill.ok == false and resLegFulfill.err == 'no_order')
        end
    end

    -- ─── DELIVERCAR-CANARY Suite ────────────────────────────────────────────
    do
        resetEnv()
        trustLevels[1] = 4
        if VPChopFence and VPChopFence._test then VPChopFence._test.setTrust(1, 4) end
        _G.VPChopGetProgression = function(src) return { tier = 4, xp = 1000 } end
        local resCanary = deliverCarCb(1, 0)
        check('DELIVERCAR-CANARY deliverCar segue rejeitando netId 0 com vehicle', resCanary.ok == false and resCanary.err == 'vehicle')
    end

    _G.VPChopFenceGetTrust = origVPChopFenceGetTrust
    _G.VPChopGetProgression = origVPChopGetProgression
    _G.VPChopFenceCurrentLocation = origVPChopFenceCurrentLocation
    _G.BridgeAddCash = origBridgeAddCash
    _G.VPChopHeatGetPriceMult = origVPChopHeatGetPriceMult

    print(('[broker_contracts/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('contracts_spec falhou') end
end

run()


