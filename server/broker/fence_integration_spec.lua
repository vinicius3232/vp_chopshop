-- server/broker/fence_integration_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-2] FENCE INTEGRATION, DYNAMIC PAYOUTS & PHYSICAL PART SPEC
--  Testa a integração entre Fence callbacks/domínio, BrokerMarket e PartEntitlement.
--  Cobre B2-01 a B2-30 com execução server-authoritative e fail-closed.
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
            print(('[broker_fence/spec] PASS  %s'):format(desc))
        else
            fail = fail + 1
            print(('[broker_fence/spec] FAIL  %s'):format(desc))
        end
    end

    -- ─── Mocks & Stubs do Ambiente ──────────────────────────────────────────
    local mockInv = {}
    local cashPaid = {}
    local cashDeducted = {}
    local trustLevels = {}
    local trustXpGained = {}
    local eventsTriggered = {}
    local mockDbRows = {}
    local virtualTime = 1700000000
    local shouldFailPayment = false
    local shouldFailRefund = false
    local shouldFailRemove = false
    local partialRemoveCount = nil

    local mockDb = {
        query = {
            await = function(sql, params)
                if sql:find('vp_chop_broker_market') then
                    return {}
                end
                return {}
            end,
        },
        single = {
            await = function(sql, params)
                return nil
            end,
        },
        insert = {
            await = function(sql, params)
                return 1
            end,
        }
    }

    local BM = _G.BrokerMarket
    local PE = _G.PartEntitlement

    local simLostDuringPayment = false

    local function resetEnv()
        mockInv = {}
        cashPaid = {}
        cashDeducted = {}
        trustLevels = { [1] = 2, [2] = 2 }
        trustXpGained = {}
        eventsTriggered = {}
        shouldFailPayment = false
        shouldFailRefund = false
        shouldFailRemove = false
        simLostDuringPayment = false
        partialRemoveCount = nil

        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 10000
        Config.Broker.Enable = true
        BM.SetIntegrityLock(false)
        BM.Init(function() return virtualTime end, mockDb, function() return 0.5 end)
        if PE and PE._test then PE._test.reset() end
        if TyreEntitlement and TyreEntitlement._test then TyreEntitlement._test.reset() end
        if TruckStorage and TruckStorage._test then TruckStorage._test.reset() end
        if VPChopFence and VPChopFence._test then
            VPChopFence._test.clearTrust()
            VPChopFence._test.clearQuarantine()
            VPChopFence._test.setTrust(1, 2)
            VPChopFence._test.setTrust(2, 2)
        end
    end

    local origVPChopFenceGetTrust = _G.VPChopFenceGetTrust
    local origVPChopGetProgression = _G.VPChopGetProgression
    local origVPChopFenceCurrentLocation = _G.VPChopFenceCurrentLocation
    local origBridgeAddCash = _G.BridgeAddCash
    local origBridgeRemoveCash = _G.BridgeRemoveCash
    local origVPChopHeatGetPriceMult = _G.VPChopHeatGetPriceMult

    local FAKE_TRUCK = _G.FAKE_TRUCK or {}
    _G.FAKE_TRUCK = FAKE_TRUCK
    local TRUCK_API = {
        get      = function(n) return FAKE_TRUCK[n] and (n + 90000) or 0 end,
        exists   = function(h) return h ~= nil and h ~= 0 end,
        model    = function(h) local n = (h or 0) - 90000; return FAKE_TRUCK[n] and FAKE_TRUCK[n].model or 0 end,
        tag      = function(h, sid)
            local n = h - 90000
            if FAKE_TRUCK[n] then FAKE_TRUCK[n].mark = sid end
            return FAKE_TRUCK[n] and FAKE_TRUCK[n].mark == sid
        end,
        marker   = function(h) local n = h - 90000; return FAKE_TRUCK[n] and FAKE_TRUCK[n].mark or nil end,
        setCount = function() end,
    }
    if TruckStorage and TruckStorage._test then
        TruckStorage._test.setEntityAPI(TRUCK_API)
    end

    -- Stubbing ox_inventory
    local oxInvStub = {
        GetItemCount = function(self, src, item)
            mockInv[src] = mockInv[src] or {}
            return mockInv[src][item] or 0
        end,
        RemoveItem = function(self, src, item, count)
            if shouldFailRemove then return false end
            mockInv[src] = mockInv[src] or {}
            local cur = mockInv[src][item] or 0
            local toRemove = count
            if partialRemoveCount ~= nil then
                toRemove = math.min(count, partialRemoveCount)
            end
            if cur >= toRemove and toRemove > 0 then
                mockInv[src][item] = cur - toRemove
                return true
            end
            return false
        end,
        AddItem = function(self, src, item, count)
            mockInv[src] = mockInv[src] or {}
            mockInv[src][item] = (mockInv[src][item] or 0) + count
            return true
        end,
        Search = function(self, queryType, item)
            mockInv[1] = mockInv[1] or {}
            return mockInv[1][item] or 0
        end
    }
    _G.FAKE_EXPORTS.ox_inventory = oxInvStub
    exports.ox_inventory = oxInvStub

    -- Stubbing Bridge payments
    _G.BridgeAddCash = function(src, amount, reason)
        if shouldFailPayment then return false end
        cashPaid[src] = (cashPaid[src] or 0) + amount
        if simLostDuringPayment then
            TyreEntitlement.MarkLost(simLostDuringPayment, 'lost_during_yield')
        end
        return true
    end

    _G.BridgeRemoveCash = function(src, amount, reason)
        if shouldFailRefund then return false end
        cashDeducted[src] = (cashDeducted[src] or 0) + amount
        return true
    end

    _G.VPChopFenceGetTrust = function(src)
        return trustLevels[src] or 1
    end

    _G.VPChopGetProgression = function(src)
        return { tier = 1, xp = 100 }
    end

    _G.VPChopFenceCurrentLocation = function()
        return { coords = vector3(0.0, 0.0, 0.0) }
    end

    -- Obter callbacks registrados no ox_lib
    local sellItemsCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:sellItems']
    local sellTyresCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:sellTyres']
    local sellCarriedPartCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:sellCarriedPart']
    local sellCatalyticCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:sellCatalytic']
    local fulfillOrderCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:fulfillOrder']
    local deliverCarCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:deliverCar']

    -- ─── B2-01: sellItems dynamic success -> QuoteSale real + RecordSalesBatch ─
    resetEnv()
    mockInv[1] = { metalscrap = 20 }
    local demBefore = BM.GetDemandIndex('metalscrap', virtualTime)
    local res01 = sellItemsCb(1, { { name = 'metalscrap', amount = 20 } })
    local demAfter = BM.GetDemandIndex('metalscrap', virtualTime)

    check('B2-01 sellItems dinâmico retorna ok=true', res01.ok == true)
    check('B2-01 Payout recebido pelo jogador é > 0', (cashPaid[1] or 0) > 0)
    check('B2-01 RecordSalesBatch aplicou pressão de venda (demanda caiu)', demAfter < demBefore)

    -- ─── B2-02: sellItems payment false -> zero pressure, zero XP ─────────────
    resetEnv()
    mockInv[1] = { metalscrap = 20 }
    shouldFailPayment = true
    local demBeforeFail = BM.GetDemandIndex('metalscrap', virtualTime)
    local res02 = sellItemsCb(1, { { name = 'metalscrap', amount = 20 } })
    local demAfterFail = BM.GetDemandIndex('metalscrap', virtualTime)

    check('B2-02 sellItems falha com payment_failed quando BridgeAddCash é false', res02.ok == false and res02.err == 'payment_failed')
    check('B2-02 Zero pressão de venda aplicada quando pagamento falha', math.abs(demAfterFail - demBeforeFail) < 0.0001)

    -- ─── B2-03: sellItems RemoveItem parcial -> payout apenas removidos ────────
    resetEnv()
    mockInv[1] = { steel = 5 } -- só tem 5 embora peça 10
    local q5 = BM.QuoteSale('steel', 5, { trustLevel = 2 })
    local res03 = sellItemsCb(1, { { name = 'steel', amount = 10 } })

    check('B2-03 sellItems com estoque menor paga apenas a quantidade real removida (5)', res03.ok == true and res03.total == q5.total)

    -- ─── B2-04: duplicate item entries agregadas -> nunca oversell ────────────
    resetEnv()
    mockInv[1] = { aluminum = 10 }
    local q10Alum = BM.QuoteSale('aluminum', 10, { trustLevel = 2 })
    local res04 = sellItemsCb(1, {
        { name = 'aluminum', amount = 5 },
        { name = 'aluminum', amount = 5 },
    })

    check('B2-04 Itens duplicados na lista são agregados e precificados marginalmente', res04.ok == true and res04.total == q10Alum.total)

    -- ─── B2-05: chopshop_tyre via sellItems mapeia para commodity tyre ─────────
    resetEnv()
    mockInv[1] = { chopshop_tyre = 4 }
    local demTyreBefore = BM.GetDemandIndex('tyre', virtualTime)
    local res05 = sellItemsCb(1, { { name = 'chopshop_tyre', amount = 4 } })
    local demTyreAfter = BM.GetDemandIndex('tyre', virtualTime)

    check('B2-05 chopshop_tyre em sellItems pressiona a commodity tyre', res05.ok == true and demTyreAfter < demTyreBefore)

    -- ─── B2-06: rubber/plastic/glass explicit legacy path ──────────────────────
    resetEnv()
    mockInv[1] = { rubber = 10, plastic = 5, glass = 2 }
    local res06 = sellItemsCb(1, {
        { name = 'rubber', amount = 10 },
        { name = 'plastic', amount = 5 },
        { name = 'glass', amount = 2 },
    })

    check('B2-06 Itens estáticos legados (rubber/plastic/glass) vendem com sucesso no legacy path', res06.ok == true and res06.total > 0)

    -- ─── B2-07: market_not_ready -> zero RemoveItem, zero money ───────────────
    resetEnv()
    mockInv[1] = { metalscrap = 10 }
    BM.Init(function() return virtualTime end, {}, function() return 0.5 end) -- sem DB -> not ready
    local res07 = sellItemsCb(1, { { name = 'metalscrap', amount = 10 } })

    check('B2-07 Mercado degradado / not ready aborta venda com market_not_ready', res07.ok == false and res07.err == 'market_not_ready')
    check('B2-07 Nenhum item foi removido durante market_not_ready', mockInv[1].metalscrap == 10)

    -- ─── B2-08: Broker Enable=false -> legacy compatibility v1.16 ─────────────
    resetEnv()
    Config.Broker.Enable = false
    mockInv[1] = { metalscrap = 10 }
    local res08 = sellItemsCb(1, { { name = 'metalscrap', amount = 10 } })

    check('B2-08 Broker desabilitado opera no fallback legacy v1.16', res08.ok == true and res08.total > 0)
    Config.Broker.Enable = true

    local function makeStoredTyre(storageId, id)
        local all = TyreEntitlement._test._all()
        all[id] = {
            id = id,
            source = { sessionId = 'session_t', vsid = 'vsid_t', partKey = 'wheel_lf', model = GetHashKey('bison') },
            removedBy = 1,
            state = 'REMOVED',
            storageId = nil,
            createdAt = os.time(),
            updatedAt = os.time(),
        }
        TruckStorage.Load(storageId, id)
    end

    -- ─── B2-09: truck tyre success -> marginal batch payout, pressure=sold ─────
    resetEnv()
    FAKE_TRUCK[100] = { model = GetHashKey('bison') }
    local sId, _ = TruckStorage.Resolve(100)
    makeStoredTyre(sId, 'te:101')
    makeStoredTyre(sId, 'te:102')

    local demTyrePre = BM.GetDemandIndex('tyre', virtualTime)
    local res09 = sellTyresCb(1, 'truck', 100)
    local demTyrePost = BM.GetDemandIndex('tyre', virtualTime)

    if not (res09 and res09.ok == true) then
        print(('[B2-09 DEBUG] res09=%s'):format(json.encode(res09)))
    end
    check('B2-09 Venda de pneus da pickup truck tem sucesso', res09.ok == true and res09.count == 2)
    check('B2-09 Demanda de pneus caiu proporcional a 2 unidades', demTyrePost < demTyrePre)

    -- ─── B2-10: truck tyre payment fail -> entitlements STORED, pressure 0 ────
    resetEnv()
    FAKE_TRUCK[101] = { model = GetHashKey('bison') }
    local sId2, _ = TruckStorage.Resolve(101)
    makeStoredTyre(sId2, 'te:103')
    shouldFailPayment = true
    local demTyrePreFail = BM.GetDemandIndex('tyre', virtualTime)
    local res10 = sellTyresCb(1, 'truck', 101)
    local demTyrePostFail = BM.GetDemandIndex('tyre', virtualTime)

    check('B2-10 Falha de pagamento em pneus de truck retorna payment', res10.ok == false and res10.err == 'payment')
    check('B2-10 Entitlements permanecem STORED no storage', TruckStorage.Count(sId2) == 1)
    check('B2-10 Zero pressão de demanda aplicada quando pagamento falhou', math.abs(demTyrePostFail - demTyrePreFail) < 0.0001)

    -- ─── B2-11: CommitSold parcial -> refund prefixTotals[sold] ───────────────
    resetEnv()
    FAKE_TRUCK[102] = { model = GetHashKey('bison') }
    local sId3, _ = TruckStorage.Resolve(102)
    makeStoredTyre(sId3, 'te:104')
    makeStoredTyre(sId3, 'te:105')

    -- Simular que te:105 sumiu/virou LOST durante o yield do pagamento
    simLostDuringPayment = 'te:105'
    local res11 = sellTyresCb(1, 'truck', 102)

    check('B2-11 Venda parcial de pneus vende apenas o disponível (1)', res11.ok == true and res11.count == 1)
    check('B2-11 Estorno parcial foi deduzido da conta do jogador', (cashDeducted[1] or 0) > 0)

    -- ─── B2-12: refund failure -> TyreSaleQuarantine ───────────────────────────
    resetEnv()
    FAKE_TRUCK[103] = { model = GetHashKey('bison') }
    local sId4, _ = TruckStorage.Resolve(103)
    makeStoredTyre(sId4, 'te:106')
    makeStoredTyre(sId4, 'te:107')
    simLostDuringPayment = 'te:107'
    shouldFailRefund = true
    local res12 = sellTyresCb(1, 'truck', 103)

    check('B2-12 Falha no estorno de venda parcial coloca jogador em quarentena de pneus', res12.ok == true)
    local resQuarantine = sellTyresCb(1, 'truck', 103)
    check('B2-12 Próxima tentativa de venda bloqueada por transaction_locked', resQuarantine.ok == false and resQuarantine.err == 'transaction_locked')

    -- ─── B2-13: inventory tyre payment fail -> rollback inventory, pressure 0 ──
    resetEnv()
    mockInv[2] = { chopshop_tyre = 2 }
    shouldFailPayment = true
    local res13 = sellTyresCb(2, 'inventory', nil)

    check('B2-13 Falha de pagamento em pneus de inventário retorna payment', res13.ok == false and res13.err == 'payment')
    check('B2-13 Pneus de inventário devolvidos no rollback', mockInv[2].chopshop_tyre == 2)

    -- ─── B2-14: catalytic trust 0 -> NO Consume ───────────────────────────────
    resetEnv()
    trustLevels[1] = 0
    if VPChopFence and VPChopFence._test then VPChopFence._test.setTrust(1, 0) end
    local catId, _ = PE.Issue('session_cat_t0', 1, 'catalytic_converter', 10, { origin = 'theft', provenance = { realPlate = 'CHOP1', model = 1234 } })
    local res14 = sellCatalyticCb(1, catId)

    check('B2-14 Catalisador com trust 0 rejeitado com no_trust', res14.ok == false and res14.err == 'no_trust')
    check('B2-14 Entitlement segue ISSUED (não consumido)', PE.State(catId) == 'ISSUED')

    -- ─── B2-15: catalytic burning heat -> NO Consume ──────────────────────────
    resetEnv()
    trustLevels[1] = 2
    _G.VPChopHeatGetPriceMult = function(plate) return 0.0 end -- Burning
    local catIdBurn, _ = PE.Issue('session_cat_burn', 1, 'catalytic_converter', 10, { origin = 'theft', provenance = { realPlate = 'HOT99', model = 1234 } })
    local res15 = sellCatalyticCb(1, catIdBurn)

    check('B2-15 Catalisador com Burning Heat rejeitado com heat_blocked', res15.ok == false and res15.err == 'heat_blocked')
    check('B2-15 Entitlement segue ISSUED sob Burning Heat', PE.State(catIdBurn) == 'ISSUED')
    _G.VPChopHeatGetPriceMult = function(plate) return 1.0 end

    -- ─── B2-16: catalytic payment fail -> CONSUMED, pressure 0, terminalConsumed
    resetEnv()
    trustLevels[1] = 2
    local catIdPayFail, _ = PE.Issue('session_cat_pf', 1, 'catalytic_converter', 10, { origin = 'theft', provenance = { realPlate = 'SAFE1', model = 1234 } })
    shouldFailPayment = true
    local demCatPre = BM.GetDemandIndex('catalytic_converter', virtualTime)
    local res16 = sellCatalyticCb(1, catIdPayFail)
    local demCatPost = BM.GetDemandIndex('catalytic_converter', virtualTime)

    check('B2-16 Falha de pagamento em catalisador retorna payment_failed', res16.ok == false and res16.err == 'payment_failed')
    check('B2-16 Retorna flag terminalConsumed=true para limpar carry no client', res16.terminalConsumed == true)
    check('B2-16 Entitlement é marcado CONSUMED (fail-closed anti-dupe)', PE.State(catIdPayFail) == 'CONSUMED')
    check('B2-16 Zero pressão de demanda aplicada quando pagamento falhou', math.abs(demCatPost - demCatPre) < 0.0001)

    -- ─── B2-17: adv_engine direct sale -> commodity adv_engine, Consume 1x ────
    resetEnv()
    trustLevels[1] = 2
    local engId, _ = PE.Issue('session_eng_ok', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'ENG01', model = 5678 } })
    local demEngPre = BM.GetDemandIndex('adv_engine', virtualTime)
    local res17 = sellCarriedPartCb(1, engId)
    local demEngPost = BM.GetDemandIndex('adv_engine', virtualTime)

    check('B2-17 Venda direta de motor físico tem sucesso', res17.ok == true and res17.commodity == 'adv_engine')
    check('B2-17 Motor foi consumido no ledger', PE.State(engId) == 'CONSUMED')
    check('B2-17 Demanda de adv_engine caiu após venda confirmada', demEngPost < demEngPre)

    -- ─── B2-18: door/bonnet/boot direct -> commodity body_panel ───────────────
    resetEnv()
    trustLevels[1] = 2
    local doorId, _ = PE.Issue('session_door_ok', 1, 'door_dside_f', 10, { origin = 'advanced', provenance = { realPlate = 'PANEL1', model = 5678 } })
    local bonnetId, _ = PE.Issue('session_bonnet_ok', 1, 'bonnet', 10, { origin = 'advanced', provenance = { realPlate = 'PANEL2', model = 5678 } })

    local resDoor = sellCarriedPartCb(1, doorId)
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 10000
    local resBonnet = sellCarriedPartCb(1, bonnetId)

    check('B2-18 Porta mapeia e vende como body_panel', resDoor.ok == true and resDoor.commodity == 'body_panel')
    check('B2-18 Capô mapeia e vende como body_panel', resBonnet.ok == true and resBonnet.commodity == 'body_panel')

    -- ─── B2-19: adv_carcass direct sale -> rejected ───────────────────────────
    resetEnv()
    local carcassId, _ = PE.Issue('session_carcass', 1, 'adv_carcass', 10, { origin = 'advanced', provenance = { realPlate = 'CHASSIS', model = 100 } })
    local res19 = sellCarriedPartCb(1, carcassId)

    check('B2-19 Venda direta de adv_carcass rejeitada (invalid_part)', res19.ok == false and res19.err == 'invalid_part')
    check('B2-19 Entitlement de adv_carcass segue ISSUED intacto', PE.State(carcassId) == 'ISSUED')

    -- ─── B2-20: another-player entitlement -> zero payout ─────────────────────
    resetEnv()
    local otherId, _ = PE.Issue('session_other', 2, 'door_dside_f', 10, { origin = 'advanced', provenance = { realPlate = 'P2CAR', model = 100 } })
    local res20 = sellCarriedPartCb(1, otherId) -- player 1 tenta vender peça do player 2

    check('B2-20 Tentativa de vender peça de outro jogador rejeitada com owner_mismatch', res20.ok == false and res20.err == 'owner_mismatch')
    check('B2-20 Zero pagamento emitido para o impostor', (cashPaid[1] or 0) == 0)

    -- ─── B2-21: bench then Broker -> zero second reward ───────────────────────
    resetEnv()
    local bId1, _ = PE.Issue('session_bench_broker', 1, 'bonnet', 10, { origin = 'advanced', provenance = { realPlate = 'BENCH1', model = 100 } })
    local consumeBench = PE.Consume(bId1, 1, 'bench_dismantle')
    check('B2-21 Peça consumida primeiro na bancada', consumeBench.ok == true)
    local resBrokerAfter = sellCarriedPartCb(1, bId1)
    check('B2-21 Venda subsequente no Broker rejeitada com already_consumed', resBrokerAfter.ok == false and resBrokerAfter.err == 'already_consumed')

    -- ─── B2-22: Broker then bench -> zero second reward ───────────────────────
    resetEnv()
    local bId2, _ = PE.Issue('session_broker_bench', 1, 'bonnet', 10, { origin = 'advanced', provenance = { realPlate = 'BROKER1', model = 100 } })
    local resBrokerFirst = sellCarriedPartCb(1, bId2)
    check('B2-22 Peça vendida primeiro no Broker', resBrokerFirst.ok == true)
    local resBenchAfter = PE.Consume(bId2, 1, 'bench_dismantle')
    check('B2-22 Consumo subsequente na bancada rejeitado com already_consumed', resBenchAfter.ok == false and resBenchAfter.err == 'already_consumed')

    -- ─── B2-23: provenance plate resolves Heat correctly ─────────────────────
    resetEnv()
    _G.VPChopHeatGetPriceMult = function(plate)
        if plate == 'WARM_PLATE' then return 0.90 end
        return 1.00
    end
    local warmId, _ = PE.Issue('session_warm', 1, 'door_dside_f', 10, { origin = 'advanced', provenance = { realPlate = 'WARM_PLATE', model = 100 } })
    local curH = (os.date and tonumber(os.date('%H'))) or nil
    local qWarm = BM.QuoteSale('body_panel', 1, { trustLevel = 2, progressionTier = 1, heatMultiplier = 0.90, hour = curH, jitter = 0.0 })
    local resWarm = sellCarriedPartCb(1, warmId)

    check('B2-23 Provenance realPlate aplica multiplicador de Heat policial (warm 0.90)', resWarm.ok == true and resWarm.payout == qWarm.total and resWarm.payout == 621)
    _G.VPChopHeatGetPriceMult = function(plate) return 1.0 end

    -- ─── B2-24: provenance_missing -> fail closed before Consume ──────────────
    resetEnv()
    local noProvId, _ = PE.Issue('session_noprov', 1, 'door_dside_f', 10, { origin = 'advanced', provenance = nil })
    local res24 = sellCarriedPartCb(1, noProvId)

    check('B2-24 Peça física sem provenance rejeitada com provenance_missing', res24.ok == false and res24.err == 'provenance_missing')
    check('B2-24 Entitlement sem provenance segue ISSUED (não consumido)', PE.State(noProvId) == 'ISSUED')

    -- ─── B2-25: same commodity concurrent lock -> market_busy ─────────────────
    resetEnv()
    BM.AcquireLocks('adv_engine')
    local engLockId, _ = PE.Issue('session_eng_lock', 1, 'adv_engine', 10, { origin = 'advanced', provenance = { realPlate = 'LOCK01', model = 100 } })
    local res25 = sellCarriedPartCb(1, engLockId)

    check('B2-25 Venda concorrente com commodity ocupada rejeita com market_busy', res25.ok == false and res25.err == 'market_busy')
    BM.ReleaseLocks('adv_engine')

    -- ─── B2-26: bulk 100 metalscrap total < 100 * firstUnitPrice ──────────────
    resetEnv()
    local q100Scrap = BM.QuoteSale('metalscrap', 100, { jitter = 0.0 })
    local linearHypo = q100Scrap.unitPrices[1] * 100
    check('B2-26 Venda de 100 scrap tem diminishing returns (total < 100 * preço unitário inicial)', q100Scrap.total < linearHypo)

    -- ─── B2-27: RecordSalesBatch invalid batch -> zero partial mutation ───────
    resetEnv()
    local badBRes = BM.RecordSalesBatch({
        { commodity = 'copper', count = 5 },
        { commodity = 'tyre', count = -2 },
    }, virtualTime)
    check('B2-27 Batch com quantidade negativa rejeitado atomicamente', badBRes.ok == false and badBRes.err == 'invalid_batch')
    local demCopper = BM.GetDemandIndex('copper', virtualTime)
    check('B2-27 Zero mutação no copper quando o batch é inválido', math.abs(demCopper - 1.0000) < 0.0001)

    -- ─── B2-28: post-payment market commit failure -> circuit breaker ─────────
    resetEnv()
    BM.SetIntegrityLock(true)
    local testIntegrityRes = BM.QuoteSale('metalscrap', 1)
    check('B2-28 Circuit breaker ativado rejeita novas cotações (market_integrity_locked)', testIntegrityRes.ok == false and testIntegrityRes.err == 'market_integrity_locked')
    BM.SetIntegrityLock(false)

    -- ─── B2-29: fulfillOrder legacy unchanged ─────────────────────────────────
    resetEnv()
    trustLevels[1] = 3
    if VPChopFence and VPChopFence._test then VPChopFence._test.setTrust(1, 3) end
    local res29NoOrder = fulfillOrderCb(1, 99999)
    check('B2-29 fulfillOrder segue no pipeline legacy (no_order para ID inexistente)', res29NoOrder.ok == false and res29NoOrder.err == 'no_order')

    -- ─── B2-30: deliverCar legacy unchanged ───────────────────────────────────
    resetEnv()
    trustLevels[1] = 4
    if VPChopFence and VPChopFence._test then VPChopFence._test.setTrust(1, 4) end
    _G.VPChopGetProgression = function(src) return { tier = 4, xp = 1000 } end
    local res30NoVeh = deliverCarCb(1, 0)
    check('B2-30 deliverCar segue no pipeline legacy (vehicle para netId 0)', res30NoVeh.ok == false and res30NoVeh.err == 'vehicle')

    -- ─── B2-LOCK-01: Lock ownership & non-leak on market_busy / early-returns ───
    resetEnv()
    FAKE_TRUCK[200] = { model = GetHashKey('bison') }
    local sId1, _ = TruckStorage.Resolve(200)
    makeStoredTyre(sId1, 'te:lock_1')
    makeStoredTyre(sId1, 'te:lock_2')

    -- 1. Player A adquire lock de 'tyre'
    local aLockOk = BM.AcquireLocks('tyre')
    check('B2-LOCK-01 Player A adquire lock em tyre', aLockOk == true)

    -- 2. Player B tenta sellTyres -> recebe market_busy e executa releaseTruck
    local resLockB = sellTyresCb(2, 'truck', 200)
    check('B2-LOCK-01 Player B recebe market_busy', resLockB.ok == false and resLockB.err == 'market_busy')

    -- 3. Player C tenta adquirir lock -> ainda deve falhar (B não liberou lock de A)
    local cLockFail = BM.AcquireLocks('tyre')
    check('B2-LOCK-01 Lock de tyre ainda está retido por Player A após release de B', cLockFail == false)

    -- 4. Early returns (no_truck, bad_truck, truck_range, no_tyres) não liberam lock de terceiro
    sellTyresCb(2, 'truck', 99999) -- no_truck
    check('B2-LOCK-01 Lock mantido após early-return no_truck', BM.AcquireLocks('tyre') == false)

    -- 5. Player A libera explicitamente
    BM.ReleaseLocks('tyre')
    local cLockSuccess = BM.AcquireLocks('tyre')
    check('B2-LOCK-01 Player C consegue adquirir lock após Player A liberar', cLockSuccess == true)
    BM.ReleaseLocks('tyre')

    -- ─── B2-NIGHT-01..03: Game Clock & Config.Fence.NightBonus Parity ─────────
    resetEnv()
    local origGetClockHours = _G.GetClockHours
    
    -- B2-NIGHT-01: 23h in-game -> NightBonus 1.30
    _G.GetClockHours = function() return 23 end
    local qNight = BM.QuoteSale('metalscrap', 1, { trustLevel = 1, progressionTier = 1, jitter = 0.0 })
    local qDayRef = BM.QuoteSale('metalscrap', 1, { trustLevel = 1, progressionTier = 1, jitter = 0.0, hour = 12 })
    check('B2-NIGHT-01 GetClockHours 23h aplica multiplicador noturno in-game 1.30', math.abs(qNight.total - math.floor(qDayRef.total * 1.30)) <= 1)

    -- B2-NIGHT-02: 12h in-game -> 1.00
    _G.GetClockHours = function() return 12 end
    local qDay = BM.QuoteSale('metalscrap', 1, { trustLevel = 1, progressionTier = 1, jitter = 0.0 })
    check('B2-NIGHT-02 GetClockHours 12h aplica multiplicador diurno 1.00', qDay.total == qDayRef.total)

    -- B2-NIGHT-03: Custom Config.Fence.NightBonus 23->5 Multiplier 1.20
    local origNB = Config.Fence.NightBonus
    Config.Fence.NightBonus = { Enable = true, StartHour = 23, EndHour = 5, Multiplier = 1.20 }
    _G.GetClockHours = function() return 23 end
    local qCustomNight = BM.QuoteSale('metalscrap', 1, { trustLevel = 1, progressionTier = 1, jitter = 0.0 })
    check('B2-NIGHT-03 Custom NightBonus 1.20 aplicado corretamente via GetClockHours', math.abs(qCustomNight.total - math.floor(qDayRef.total * 1.20)) <= 1)
    
    Config.Fence.NightBonus = origNB
    _G.GetClockHours = origGetClockHours

    -- ─── B2-PROV-01..04: Canonical Vehicle Provenance & MDT Resolution ─────────
    resetEnv()
    local origMDT = _G.VPChopMDT
    local origPlateText = _G.GetVehicleNumberPlateText
    _G.FAKE_VEH[1] = { model = 1234, plate = 'CHOP1' }
    
    -- B2-PROV-01: Fake plate com espaços resolvida para REAL999
    _G.GetVehicleNumberPlateText = function(v) return " FAKE123  " end
    _G.VPChopMDT = {
        GetRealPlate = function(plate)
            if plate == "FAKE123" then return "REAL999" end
            return plate
        end
    }
    local prov01 = PE.CaptureVehicleProvenance(70001)
    check('B2-PROV-01 Placa padded com whitespace resolvida para canonicalRealPlate', prov01 and prov01.realPlate == "REAL999")

    -- B2-PROV-02: Heat de REAL999 é burning -> venda bloqueada
    _G.VPChopHeatGetPriceMult = function(plate)
        if plate == "REAL999" then return 0.0 end
        return 1.0
    end
    local entHotId, _ = PE.Issue('session_hot_prov', 1, 'door_dside_f', 1, { origin = 'advanced', provenance = prov01 })
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resProv02 = sellCarriedPartCb(1, entHotId)
    check('B2-PROV-02 Peça com Heat burning de REAL999 bloqueada no Broker (heat_blocked)', resProv02.ok == false and resProv02.err == 'heat_blocked')
    check('B2-PROV-02 Entitlement segue ISSUED após bloqueio de Heat', PE.State(entHotId) == 'ISSUED')
    _G.VPChopHeatGetPriceMult = function() return 1.0 end

    -- B2-PROV-03: Resolver lança erro DB -> retirada física não crasha, provenance=nil, venda rejeita com provenance_missing
    _G.VPChopMDT = {
        GetRealPlate = function() error('DB connection timeout') end
    }
    local prov03 = PE.CaptureVehicleProvenance(70001)
    check('B2-PROV-03 Erro no resolver MDT resulta em provenance=nil sem crash', prov03 == nil)
    local entFailId, _ = PE.Issue('session_fail_prov', 1, 'bonnet', 1, { origin = 'advanced', provenance = prov03 })
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resProv03 = sellCarriedPartCb(1, entFailId)
    check('B2-PROV-03 Peça emitida com provenance=nil falha na venda com provenance_missing', resProv03.ok == false and resProv03.err == 'provenance_missing')
    check('B2-PROV-03 Entitlement segue ISSUED com zero payout', PE.State(entFailId) == 'ISSUED')

    -- B2-PROV-04: Resolver retorna string vazia ou nil -> fail-closed
    _G.VPChopMDT = {
        GetRealPlate = function() return "   " end
    }
    local prov04 = PE.CaptureVehicleProvenance(70001)
    check('B2-PROV-04 Retorno vazio do MDT resulta em provenance=nil', prov04 == nil)

    _G.VPChopMDT = origMDT
    _G.GetVehicleNumberPlateText = origPlateText

    -- ─── B2-CAT-TRUST-01..03: Catalytic Trust Parity (Zero Trust XP) ───────────
    resetEnv()
    trustLevels[1] = 1
    if VPChopFence and VPChopFence._test then VPChopFence._test.setTrust(1, 1, 100) end
    
    -- B2-CAT-TRUST-01: Dynamic sale success -> Trust XP antes == Trust XP depois
    local catIdT1, _ = PE.Issue('session_cat_t1', 1, 'catalytic_converter', 10, { origin = 'theft', provenance = { realPlate = 'SAFE1', model = 1234 } })
    local tBefore1 = VPChopFence._test.getTrust(1).trust_xp
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resCatT1 = sellCatalyticCb(1, catIdT1)
    local tAfter1 = VPChopFence._test.getTrust(1).trust_xp
    check('B2-CAT-TRUST-01 Venda dinâmica de catalisador tem sucesso', resCatT1.ok == true)
    check('B2-CAT-TRUST-01 Venda dinâmica de catalisador concede ZERO Trust XP', tBefore1 == tAfter1 and tAfter1 == 100)

    -- B2-CAT-TRUST-02: Legacy rollback Enable=false -> Trust XP antes == Trust XP depois
    Config.Broker.Enable = false
    local catIdT2, _ = PE.Issue('session_cat_t2', 1, 'catalytic_converter', 10, { origin = 'theft', provenance = { realPlate = 'SAFE2', model = 1234 } })
    local tBefore2 = VPChopFence._test.getTrust(1).trust_xp
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resCatT2 = sellCatalyticCb(1, catIdT2)
    local tAfter2 = VPChopFence._test.getTrust(1).trust_xp
    check('B2-CAT-TRUST-02 Venda legada de catalisador tem sucesso', resCatT2.ok == true)
    check('B2-CAT-TRUST-02 Venda legada de catalisador concede ZERO Trust XP', tBefore2 == tAfter2 and tAfter2 == 100)
    Config.Broker.Enable = true

    -- B2-CAT-TRUST-03: Payment failure -> Trust XP sem mudança
    local catIdT3, _ = PE.Issue('session_cat_t3', 1, 'catalytic_converter', 10, { origin = 'theft', provenance = { realPlate = 'SAFE3', model = 1234 } })
    shouldFailPayment = true
    local tBefore3 = VPChopFence._test.getTrust(1).trust_xp
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resCatT3 = sellCatalyticCb(1, catIdT3)
    local tAfter3 = VPChopFence._test.getTrust(1).trust_xp
    check('B2-CAT-TRUST-03 Falha de pagamento em catalisador não altera Trust XP', tBefore3 == tAfter3 and tAfter3 == 100)
    shouldFailPayment = false

    -- ─── B2-CB-01: Real Post-Payment Market Commit Failure -> Circuit Breaker ─
    resetEnv()
    BM.SetIntegrityLock(false)
    local catIdCB, _ = PE.Issue('session_cat_cb', 1, 'catalytic_converter', 10, { origin = 'theft', provenance = { realPlate = 'SAFE99', model = 1234 } })
    
    local origRecordSalesBatch = BM.RecordSalesBatch
    BM.RecordSalesBatch = function(batch, now)
        return { ok = false, err = 'forced_test_failure' }
    end

    local bridgeAddCashCount = 0
    _G.BridgeAddCash = function(src, amount, reason)
        bridgeAddCashCount = bridgeAddCashCount + 1
        return true
    end

    local bridgeRemoveCashCount = 0
    _G.BridgeRemoveCash = function(src, amount, reason)
        bridgeRemoveCashCount = bridgeRemoveCashCount + 1
        return true
    end

    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resCB = sellCatalyticCb(1, catIdCB)
    
    check('B2-CB-01 Dinheiro entregue exatamente 1x ao jogador', bridgeAddCashCount == 1)
    check('B2-CB-01 Entitlement ficou terminal CONSUMED', PE.State(catIdCB) == 'CONSUMED')
    check('B2-CB-01 Zero refund automático emitido', bridgeRemoveCashCount == 0)
    check('B2-CB-01 BrokerMarket ativou circuit breaker (IsIntegrityLocked == true)', BM.IsIntegrityLocked() == true)
    check('B2-CB-01 Callback retorna ok=true com flag marketDegraded=true', resCB.ok == true and resCB.marketDegraded == true)
    
    -- Próxima venda dinâmica é bloqueada por market_integrity_locked
    local catIdNext, _ = PE.Issue('session_cat_next', 1, 'catalytic_converter', 10, { origin = 'theft', provenance = { realPlate = 'SAFE100', model = 1234 } })
    _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 1000
    local resNext = sellCatalyticCb(1, catIdNext)
    check('B2-CB-01 Próxima venda dinâmica rejeitada com market_integrity_locked', resNext.ok == false and resNext.err == 'market_integrity_locked')
    check('B2-CB-01 Nenhum segundo pagamento emitido', bridgeAddCashCount == 1)

    BM.RecordSalesBatch = origRecordSalesBatch
    BM.SetIntegrityLock(false)

    _G.VPChopFenceGetTrust = origVPChopFenceGetTrust
    _G.VPChopGetProgression = origVPChopGetProgression
    _G.VPChopFenceCurrentLocation = origVPChopFenceCurrentLocation
    _G.BridgeAddCash = origBridgeAddCash
    _G.BridgeRemoveCash = origBridgeRemoveCash
    _G.VPChopHeatGetPriceMult = origVPChopHeatGetPriceMult
    _G.FAKE_TRUCK = {}

    print(('[broker_fence/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('fence_integration_spec falhou') end
end

run()
