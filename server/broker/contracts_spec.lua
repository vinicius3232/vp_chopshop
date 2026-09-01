-- server/broker/contracts_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-3] CONTRACTS & HIGH-DEMAND LISTS SPEC
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

                    -- UPDATE de compensação de reserva
                    if sql:find("SET `remaining` = `remaining` +", 1, true) then
                        local addCnt, cId = params[1], params[2]
                        local c = mockDbRows[cId]
                        if c then
                            c.remaining = c.remaining + addCnt
                            c.state = (c.for_identifier == nil) and 'AVAILABLE' or 'ACCEPTED'
                            c.fulfilled_at = nil
                            return { affectedRows = 1 }
                        end
                        return { affectedRows = 0 }
                    end

                    -- UPDATE atômico de reserva de fulfillment
                    if sql:find("SET `remaining` = `remaining` - 1", 1, true) then
                        local curT, cId, pKey, tLev = params[1], params[2], params[3], params[4]
                        local c = mockDbRows[cId]
                        if c and (c.for_identifier == nil or c.for_identifier == pKey)
                           and (c.state == 'AVAILABLE' or c.state == 'ACCEPTED')
                           and c.remaining > 0
                           and c.min_trust <= tLev
                           and c.expires_at > curT then
                            c.remaining = c.remaining - 1
                            if c.remaining == 0 then
                                c.state = 'COMPLETED'
                                c.fulfilled_at = curT
                            end
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

    -- Obter callbacks registrados no ox_lib
    local getContractsCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:broker:getContracts']
    local acceptContractCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:broker:acceptContract']
    local fulfillContractCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:broker:fulfillContract']
    local getOrderCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:getOrder']
    local fulfillOrderCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:fulfillOrder']
    local deliverCarCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:deliverCar']

    -- ─── Helper para criar contratos sintéticos no mock DB ───────────────────
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
            state          = st or 'AVAILABLE',
        }
        return id
    end

    -- ─── BROKER-SEC-01: entitlementId forjado rejeitado sem pagamento ────────
    resetEnv()
    local cIdSec1 = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
    local resSec1 = fulfillContractCb(1, cIdSec1, 'forged_fake_id_999')
    check('BROKER-SEC-01 Entitlement inexistente/forjado rejeitado', resSec1.ok == false and (resSec1.err == 'not_found' or resSec1.err == 'invalid_entitlement' or resSec1.err == 'invalid'))
    check('BROKER-SEC-01 Zero pagamento efetuado para entitlement forjado', (cashPaid[1] or 0) == 0)
    check('BROKER-SEC-01 Contrato segue intacto após tentativa forjada', mockDbRows[cIdSec1].remaining == 1)

    -- ─── BROKER-SEC-02: Player B tenta entitlement do Player A -> owner_mismatch ─
    resetEnv()
    local cIdSec2 = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
    local entAId, _ = PE.Issue('session_sec2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC02A', model = 1234 } })
    local resSec2 = fulfillContractCb(2, cIdSec2, entAId)
    check('BROKER-SEC-02 Venda de entitlement alheio rejeitada com owner_mismatch', resSec2.ok == false and resSec2.err == 'owner_mismatch')
    check('BROKER-SEC-02 Zero pagamento efetuado para o impostor B', (cashPaid[2] or 0) == 0)
    check('BROKER-SEC-02 Entitlement do Player A segue ISSUED', PE.State(entAId) == 'ISSUED')

    -- ─── BROKER-SEC-03: entitlement já CONSUMED -> already_consumed ───────────
    resetEnv()
    local cIdSec3 = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
    local ent3Id, _ = PE.Issue('session_sec3', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC03', model = 1234 } })
    PE.Consume(ent3Id, 1, 'bench_test', 'adv_engine')
    local resSec3 = fulfillContractCb(1, cIdSec3, ent3Id)
    check('BROKER-SEC-03 Entitlement já consumido rejeitado com already_consumed', resSec3.ok == false and resSec3.err == 'already_consumed')
    check('BROKER-SEC-03 Zero pagamento efetuado para peça já consumida', (cashPaid[1] or 0) == 0)

    -- ─── BROKER-SEC-04: Peça não atende ao contrato -> wrong_part ────────────
    resetEnv()
    local cIdSec4 = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
    local doorEntId, _ = PE.Issue('session_sec4', 1, 'door_dside_f', 10, { origin = 'advanced', provenance = { realPlate = 'SEC04', model = 1234 } })
    local resSec4 = fulfillContractCb(1, cIdSec4, doorEntId)
    check('BROKER-SEC-04 Entrega de peça incompatível rejeitada com wrong_part', resSec4.ok == false and resSec4.err == 'wrong_part')
    check('BROKER-SEC-04 Entitlement incompatível segue ISSUED', PE.State(doorEntId) == 'ISSUED')
    check('BROKER-SEC-04 Quota do contrato segue intacta', mockDbRows[cIdSec4].remaining == 1)

    -- ─── BROKER-SEC-05: Deadline vencido -> contract_expired ──────────────────
    resetEnv()
    local cIdSec5 = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1, -100) -- expirado há 100s
    local eng5Id, _ = PE.Issue('session_sec5', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC05', model = 1234 } })
    local resSec5 = fulfillContractCb(1, cIdSec5, eng5Id)
    check('BROKER-SEC-05 Entrega para contrato expirado rejeitada com contract_expired', resSec5.ok == false and resSec5.err == 'contract_expired')
    check('BROKER-SEC-05 Entitlement segue ISSUED após contrato expirado', PE.State(eng5Id) == 'ISSUED')

    -- ─── BROKER-SEC-06: Concorrência remaining=1 -> exatamente 1 liquidação ───
    resetEnv()
    local cIdSec6 = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
    local eng6A, _ = PE.Issue('session_sec6A', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC06A', model = 1234 } })
    local eng6B, _ = PE.Issue('session_sec6B', 2, 'adv_engine', 11, { origin = 'advanced', provenance = { realPlate = 'SEC06B', model = 1234 } })

    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local res6A = fulfillContractCb(1, cIdSec6, eng6A)
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local res6B = fulfillContractCb(2, cIdSec6, eng6B)

    check('BROKER-SEC-06 Primeira chamada concorrente tem sucesso', res6A.ok == true)
    check('BROKER-SEC-06 Segunda chamada concorrente rejeitada com contract_fulfilled', res6B.ok == false and (res6B.err == 'contract_fulfilled' or res6B.err == 'contract_unavailable'))
    check('BROKER-SEC-06 Player A foi pago e Player B recebeu ZERO', (cashPaid[1] or 0) > 0 and (cashPaid[2] or 0) == 0)
    check('BROKER-SEC-06 Entitlement B segue ISSUED', PE.State(eng6B) == 'ISSUED')

    -- ─── BROKER-SEC-07: Client tenta forjar model -> provenance OneSync é autoridade ───
    resetEnv()
    local cIdSec7 = createContract(nil, 'model', 'sultan', 1, 1.35, 0, 1)
    local sultanHash = GetHashKey('sultan')
    local bisonHash = GetHashKey('bison')
    -- Peça com provenance real de 'bison'
    local eng7Bison, _ = PE.Issue('session_sec7', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'BISON01', model = bisonHash } })
    local resSec7 = fulfillContractCb(1, cIdSec7, eng7Bison)
    check('BROKER-SEC-07 Modelo incorreto rejeitado pelo servidor com wrong_part', resSec7.ok == false and resSec7.err == 'wrong_part')

    -- ─── BROKER-SEC-08: Client tenta forjar class -> provenance OneSync é autoridade ───
    resetEnv()
    local cIdSec8 = createContract(nil, 'class', 'sports', 1, 1.30, 0, 1)
    local eng8SUV, _ = PE.Issue('session_sec8', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SUV01', model = 1234, vehicleClass = 2, className = 'suvs' } })
    local resSec8 = fulfillContractCb(1, cIdSec8, eng8SUV)
    check('BROKER-SEC-08 Classe incorreta rejeitada pelo servidor com wrong_part', resSec8.ok == false and resSec8.err == 'wrong_part')

    -- ─── BROKER-SEC-09: Client tenta injetar price -> BrokerMarket calcula autoritativo ───
    resetEnv()
    local cIdSec9 = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1)
    local eng9, _ = PE.Issue('session_sec9', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC09', model = 1234 } })
    local resSec9 = fulfillContractCb(1, cIdSec9, eng9)
    local expectedBase = BM.ResolvePrice('adv_engine', { trustLevel = 3, progressionTier = 2, heatMultiplier = 1.0, jitter = 0.0 }).unitPrice
    local expectedPayout = math.floor(expectedBase * 1.20)
    check('BROKER-SEC-09 Payout calculado exclusivamente pelo servidor', resSec9.ok == true and resSec9.payout == expectedPayout)

    -- ─── BROKER-SEC-10: Client tenta injetar Trust/mult -> servidor consulta DB ───
    resetEnv()
    trustLevels[3] = 1 -- Player 3 tem trust 1
    local cIdSec10 = createContract(nil, 'part_type', 'adv_engine', 1, 1.50, 0, 3) -- exige trust 3
    local eng10, _ = PE.Issue('session_sec10', 3, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SEC10', model = 1234 } })
    local resSec10 = fulfillContractCb(3, cIdSec10, eng10)
    check('BROKER-SEC-10 Jogador com Trust insuficiente rejeitado com trust_gate', resSec10.ok == false and resSec10.err == 'trust_gate')
    check('BROKER-SEC-10 Entitlement de Trust insuficiente segue ISSUED', PE.State(eng10) == 'ISSUED')

    -- ─── CONTRACT-DB-01: Sem DB -> IsReady false -> fail-closed ───────────────
    resetEnv()
    BC.Init(false) -- desabilita DB
    local resDb01 = getContractsCb(1)
    check('CONTRACT-DB-01 getContracts falha com contracts_not_ready quando DB ausente', resDb01.ok == false and resDb01.err == 'contracts_not_ready')
    local resDbFulfill = fulfillContractCb(1, 101, 'pe:test')
    check('CONTRACT-DB-01 fulfillContract falha com contracts_not_ready quando DB ausente', resDbFulfill.ok == false and resDbFulfill.err == 'contracts_not_ready')
    BC.Init(mockDb, function() return virtualTime end, function() return 0.5 end)

    -- ─── CONTRACT-GLOBAL-01: Contrato global multi-unidade concluído em etapas ─
    resetEnv()
    local cIdGlob1 = createContract(nil, 'part_type', 'adv_engine', 2, 1.20, 0, 1)
    local engG1, _ = PE.Issue('session_glob1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'GLOB1', model = 1234 } })
    local engG2, _ = PE.Issue('session_glob2', 2, 'adv_engine', 11, { origin = 'advanced', provenance = { realPlate = 'GLOB2', model = 1234 } })

    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resG1 = fulfillContractCb(1, cIdGlob1, engG1)
    check('CONTRACT-GLOBAL-01 Player A entrega 1a unidade do contrato global', resG1.ok == true and resG1.remaining == 1 and resG1.completed == false)
    check('CONTRACT-GLOBAL-01 Contrato global permanece AVAILABLE com remaining=1', mockDbRows[cIdGlob1].state == 'AVAILABLE' and mockDbRows[cIdGlob1].remaining == 1)

    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resG2 = fulfillContractCb(2, cIdGlob1, engG2)
    check('CONTRACT-GLOBAL-01 Player B entrega 2a unidade concluindo o contrato global', resG2.ok == true and resG2.remaining == 0 and resG2.completed == true)
    check('CONTRACT-GLOBAL-01 Contrato global transiciona para COMPLETED', mockDbRows[cIdGlob1].state == 'COMPLETED' and mockDbRows[cIdGlob1].remaining == 0)

    -- ─── CONTRACT-RACE-02: Double-fire do mesmo entitlement -> compensação ────
    resetEnv()
    local cIdRace2 = createContract(nil, 'part_type', 'adv_engine', 2, 1.20, 0, 1)
    local engRace, _ = PE.Issue('session_race2', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'RACE2', model = 1234 } })

    -- 1o disparo consome e liquida
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resR1 = fulfillContractCb(1, cIdRace2, engRace)
    check('CONTRACT-RACE-02 Primeiro disparo tem sucesso', resR1.ok == true)

    -- 2o disparo tenta com peça já consumida
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resR2 = fulfillContractCb(1, cIdRace2, engRace)
    check('CONTRACT-RACE-02 Segundo disparo rejeitado com already_consumed', resR2.ok == false and resR2.err == 'already_consumed')
    check('CONTRACT-RACE-02 Quota do contrato não foi perdida (permanece 1)', mockDbRows[cIdRace2].remaining == 1)

    -- ─── CONTRACT-PERSONAL-01: Contrato pessoal não aceitável/cumprível por B ───
    resetEnv()
    local pKeyA = 'qbx:player_1'
    local cIdPers = createContract(pKeyA, 'part_type', 'adv_engine', 1, 1.30, 2000, 3)

    -- Player 2 tenta aceitar contrato de Player 1
    local resAccB = acceptContractCb(2, cIdPers)
    check('CONTRACT-PERSONAL-01 Player B não pode aceitar contrato pessoal de A (owner_mismatch)', resAccB.ok == false and resAccB.err == 'owner_mismatch')

    -- Player 1 aceita seu contrato
    local resAccA = acceptContractCb(1, cIdPers)
    check('CONTRACT-PERSONAL-01 Player A aceita seu contrato com sucesso', resAccA.ok == true)
    check('CONTRACT-PERSONAL-01 Estado do contrato pessoal avança para ACCEPTED', mockDbRows[cIdPers].state == 'ACCEPTED')

    -- Player 2 tenta cumprir contrato aceito por A
    local engPersB, _ = PE.Issue('session_pb', 2, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PERB', model = 1234 } })
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resFulB = fulfillContractCb(2, cIdPers, engPersB)
    check('CONTRACT-PERSONAL-01 Player B não pode cumprir contrato pessoal de A (owner_mismatch)', resFulB.ok == false and resFulB.err == 'owner_mismatch')

    -- ─── CONTRACT-MODEL-01 & 02: Model matching ──────────────────────────────
    resetEnv()
    local sultanH = GetHashKey('sultan')
    local cIdModel = createContract(nil, 'model', 'sultan', 1, 1.35, 0, 1)

    -- Model correto
    local engSultan, _ = PE.Issue('session_sultan', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SULTAN1', model = sultanH } })
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resModOk = fulfillContractCb(1, cIdModel, engSultan)
    check('CONTRACT-MODEL-01 Modelo correto (sultan) dá match e liquida', resModOk.ok == true)

    -- ─── CONTRACT-CLASS-01 & 02: Class matching & fail-closed on missing ──────
    resetEnv()
    local cIdClass = createContract(nil, 'class', 'sports', 1, 1.30, 0, 1)

    -- Sem class provenance
    local engNoClass, _ = PE.Issue('session_noclass', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'NOCLASS', model = 1234, className = nil, vehicleClass = nil } })
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resNoClass = fulfillContractCb(1, cIdClass, engNoClass)
    check('CONTRACT-CLASS-02 Provenance de classe ausente falha closed com provenance_class_missing', resNoClass.ok == false and resNoClass.err == 'provenance_class_missing')

    -- Com classe sports correta
    local engSports, _ = PE.Issue('session_sports', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'SPORTS1', model = 1234, className = 'sports', vehicleClass = 6 } })
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resSports = fulfillContractCb(1, cIdClass, engSports)
    check('CONTRACT-CLASS-01 Classe correta (sports) dá match e liquida', resSports.ok == true)

    -- ─── CONTRACT-HIGHVALUE-01: Target fora da allowlist ──────────────────────
    resetEnv()
    local cIdBadHigh = createContract(nil, 'high_value', 'unauthorized_target_item', 1, 1.50, 0, 1)
    local engBadHigh, _ = PE.Issue('session_badhigh', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'BADHIGH', model = 1234 } })
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resBadHigh = fulfillContractCb(1, cIdBadHigh, engBadHigh)
    check('CONTRACT-HIGHVALUE-01 Target fora da allowlist rejeitado com invalid_high_value_target', resBadHigh.ok == false and resBadHigh.err == 'invalid_high_value_target')

    -- ─── CONTRACT-EXPIRY-01: ExpireDue atualiza contratos vencidos ────────────
    resetEnv()
    local cIdExp1 = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1, 500)
    virtualTime = virtualTime + 600 -- avança além do expires_at
    local expiredCount = BC.ExpireDue(virtualTime)
    check('CONTRACT-EXPIRY-01 ExpireDue identifica e purga contrato vencido', expiredCount == 1 and mockDbRows[cIdExp1].state == 'EXPIRED')

    -- ─── CONTRACT-RESTART-01: Contrato persiste após reboot do resource ───────
    resetEnv()
    local cIdRest = createContract(nil, 'part_type', 'adv_engine', 2, 1.25, 0, 1)
    mockDbRows[cIdRest].remaining = 1 -- já entregou 1 unidade antes do reboot
    -- Simula reboot
    BC.Init(mockDb, function() return virtualTime end, function() return 0.5 end)
    local loadedRest = BC.Get(cIdRest)
    check('CONTRACT-RESTART-01 Contrato recuperado pós-reboot com remaining=1 intacto', loadedRest ~= nil and loadedRest.remaining == 1 and loadedRest.quantity == 2)

    -- ─── CONTRACT-PAY-01: BridgeAddCash=false pós-consumo -> terminalConsumed ─
    resetEnv()
    local cIdPayFail = createContract(nil, 'part_type', 'adv_engine', 1, 1.25, 0, 1)
    local engPayFail, _ = PE.Issue('session_payfail', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'PAYFAIL', model = 1234 } })
    shouldFailPayment = true

    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resPayFail = fulfillContractCb(1, cIdPayFail, engPayFail)
    check('CONTRACT-PAY-01 Falha de pagamento retorna payment_failed', resPayFail.ok == false and resPayFail.err == 'payment_failed')
    check('CONTRACT-PAY-01 Flag terminalConsumed=true retornada ao client', resPayFail.terminalConsumed == true)
    check('CONTRACT-PAY-01 Entitlement permanece terminal CONSUMED (fail-closed anti-dupe)', PE.State(engPayFail) == 'CONSUMED')
    check('CONTRACT-PAY-01 Quota do contrato permanece reservada', mockDbRows[cIdPayFail].remaining == 0 and mockDbRows[cIdPayFail].state == 'COMPLETED')
    shouldFailPayment = false

    -- ─── CONTRACT-BONUS-01: bonus_cash pago UMA vez apenas na conclusão ────────
    resetEnv()
    local cIdBonus = createContract('qbx:player_1', 'part_type', 'adv_engine', 2, 1.20, 5000, 3)
    acceptContractCb(1, cIdBonus)

    local engB1, _ = PE.Issue('session_b1', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'BONUS1', model = 1234 } })
    local engB2, _ = PE.Issue('session_b2', 1, 'adv_engine', 11, { origin = 'advanced', provenance = { realPlate = 'BONUS2', model = 1234 } })

    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resB1 = fulfillContractCb(1, cIdBonus, engB1)
    check('CONTRACT-BONUS-01 1a entrega (remaining 2->1) NÃO paga bonus_cash', resB1.ok == true and resB1.bonusCash == 0 and resB1.completed == false)

    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resB2 = fulfillContractCb(1, cIdBonus, engB2)
    check('CONTRACT-BONUS-01 2a entrega (remaining 1->0) PAGA bonus_cash exatamente 1x', resB2.ok == true and resB2.bonusCash == 5000 and resB2.completed == true)

    -- ─── CONTRACT-MARKET-01: Contrato não aplica RecordSalesBatch ─────────────
    resetEnv()
    local cIdMkt = createContract(nil, 'part_type', 'adv_engine', 1, 1.20, 0, 1)
    local engMkt, _ = PE.Issue('session_mkt', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'MKT01', model = 1234 } })

    local demBefore = BM.GetDemandIndex('adv_engine', virtualTime)
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resMkt = fulfillContractCb(1, cIdMkt, engMkt)
    local demAfter = BM.GetDemandIndex('adv_engine', virtualTime)
    check('CONTRACT-MARKET-01 Fulfillment de contrato tem sucesso financeiro', resMkt.ok == true)
    check('CONTRACT-MARKET-01 Demanda do mercado geral permaneceu inalterada (zero RecordSalesBatch)', math.abs(demAfter - demBefore) < 0.0001)

    -- ─── CONTRACT-LEGACY-01 & 02: getOrder e fulfillOrder legados funcionais ──
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

    -- ─── DELIVERCAR-CANARY: deliverCar permanece intocado ─────────────────────
    resetEnv()
    trustLevels[1] = 4
    if VPChopFence and VPChopFence._test then VPChopFence._test.setTrust(1, 4) end
    _G.VPChopGetProgression = function(src) return { tier = 4, xp = 1000 } end
    local resCanary = deliverCarCb(1, 0)
    check('DELIVERCAR-CANARY deliverCar segue rejeitando netId 0 com vehicle', resCanary.ok == false and resCanary.err == 'vehicle')

    _G.VPChopFenceGetTrust = origVPChopFenceGetTrust
    _G.VPChopGetProgression = origVPChopGetProgression
    _G.VPChopFenceCurrentLocation = origVPChopFenceCurrentLocation
    _G.BridgeAddCash = origBridgeAddCash
    _G.VPChopHeatGetPriceMult = origVPChopHeatGetPriceMult

    print(('[broker_contracts/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('contracts_spec falhou') end
end

run()
