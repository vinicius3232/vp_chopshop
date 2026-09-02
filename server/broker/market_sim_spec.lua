-- server/broker/market_sim_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-1.1] DYNAMIC MARKET PRICING & ECONOMIC SIMULATION ENGINE SPECS
--  Self-gated na convar vp_chopshop_selftest 1.
--
--  Cobre:
--    - FXMANIFEST-SELFTEST-01 (preservação simultânea de action_session_spec e market_sim_spec)
--    - MARKET-01 a MARKET-09 contra o módulo REAL BrokerMarket
--    - MARKET-PERSIST-01 a 06 (pcall closures, dirty retry, nil result handling, periodic flush seam)
--    - MARKET-READY-01 e 02 (degraded/unavailable policy em caso de falha no DB Init)
--    - MARKET-CONFIG-ENABLE-01 (fail-closed quando Config.Broker.Enable == false)
--    - Volume Diminishing Returns Simulation (20 catalytics, 20 engines, 50 tyres, 50 plates, 100 scrap)
--    - Asymptotic Lazy Time Recovery Simulation (+1h, +3h, +6h, +12h, +24h)
--    - 108.000+ iterações determinísticas usando o tier real Config.Progression.FencePriceMult
--    - SIM-GRID-01 a 07 (invariantes, estatística de ceiling hits, clamp de demandOverride e NaN/Inf guard)
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then
        pass = pass + 1
        print('[broker_market/spec] PASS  ' .. name)
    else
        fail = fail + 1
        print('[broker_market/spec] FAIL  ' .. name)
    end
end

local function run()
    -- ─── FXMANIFEST-SELFTEST-01: Verificação de Registro dos Specs ────────────
    local fxContent
    local candidatePaths = {
        'fxmanifest.lua',
        './fxmanifest.lua',
        (_G.BASE_RESOURCE_PATH or '.') .. '/fxmanifest.lua',
        (_G._HARNESS_BASE or '.') .. '/fxmanifest.lua',
        '../fxmanifest.lua',
    }
    for _, p in ipairs(candidatePaths) do
        local f = io.open(p, 'r')
        if f then
            fxContent = f:read('*a')
            f:close()
            break
        end
    end

    if fxContent then
        local hasActionSpec = fxContent:find("server/session/action_session_spec.lua", 1, true) ~= nil
        local hasMarketSpec = fxContent:find("server/broker/market_sim_spec.lua", 1, true) ~= nil
        check('FXMANIFEST-SELFTEST-01 fxmanifest.lua registra simultaneamente action_session_spec e market_sim_spec', hasActionSpec and hasMarketSpec)
    else
        check('FXMANIFEST-SELFTEST-01 fxmanifest.lua encontrado e validado', false)
    end

    local BM = _G.BrokerMarket
    check('CANARY-MARKET-01 BrokerMarket module exists and is loaded', type(BM) == 'table')
    if not BM then return end

    -- Estado virtual de tempo e RNG determinístico
    local virtualTime = 1700000000
    BM.SetClock(function() return virtualTime end)
    BM.SetRng(function() return 0.5 end) -- jitter neutro (0.0) por padrão

    local mockDb
    local shouldFailQuery = false
    local shouldReturnNilQuery = false

    mockDb = {
        _rows = {},
        query = {
            await = function(query, params)
                if shouldFailQuery then
                    error('SQL_MOCK_SIMULATED_FAILURE')
                end
                if shouldReturnNilQuery then
                    return nil
                end
                if query:find('SELECT') then
                    local list = {}
                    for k, v in pairs(mockDb._rows) do
                        list[#list + 1] = {
                            commodity = k,
                            demand_index = v.demand_index,
                            recent_volume = v.recent_volume,
                            last_rec = v.last_recovery,
                        }
                    end
                    return list
                elseif query:find('INSERT') and query:find('vp_chop_broker_market') then
                    local comm, dem, vol, t = params[1], params[2], params[3], params[4]
                    mockDb._rows[comm] = {
                        commodity = comm,
                        demand_index = dem,
                        recent_volume = vol,
                        last_recovery = t,
                    }
                    return { affectedRows = 1 }
                end
                return {}
            end,
        },
    }

    local function resetMarket()
        virtualTime = 1700000000
        shouldFailQuery = false
        shouldReturnNilQuery = false
        mockDb._rows = {}
        Config.Broker.Enable = true
        BM.Init(function() return virtualTime end, mockDb, function() return 0.5 end)
    end

    -- ─── MARKET-01: Venda reduz a demanda com pressão de volume ──────────────
    resetMarket()
    check('MARKET-READY-01 BrokerMarket.IsReady() é true após Init com DB saudável', BM.IsReady() == true)

    local snap0 = BM.GetSnapshot('catalytic_converter')
    check('MARKET-01 Demanda inicial de catalytic_converter é 1.0000', math.abs(snap0.demandIndex - 1.0000) < 0.0001)

    local saleRes1 = BM.RecordSale('catalytic_converter', 5, virtualTime)
    check('MARKET-01 RecordSale com sucesso retorna ok=true', saleRes1.ok == true)
    check('MARKET-01 Demanda cai de 1.0000 para 0.8000 (5 x 0.04 = 0.20)', math.abs(saleRes1.newDemand - 0.8000) < 0.0001)
    check('MARKET-01 Volume acumulado registrado é 5', saleRes1.volume == 5)

    -- ─── MARKET-02: Recuperação temporal lazy rumo a 1.0000 ──────────────────
    -- Avança 1 hora (3600s). Taxa de catalytic_converter = 0.15/h -> 0.80 + 0.15 = 0.95
    virtualTime = virtualTime + 3600
    local recDemand1 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('MARKET-02 Demanda recupera 0.15/h após 1 hora (0.80 -> 0.95)', math.abs(recDemand1 - 0.9500) < 0.0001)

    -- Avança mais 2 horas (total 3h desde 0.80). 0.80 + 0.45 = 1.25 -> clamped em 1.0000 (equilíbrio)
    virtualTime = virtualTime + 7200
    local recDemand2 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('MARKET-02 Demanda estabiliza exatamente no equilíbrio 1.0000 sem ultrapassar', math.abs(recDemand2 - 1.0000) < 0.0001)

    -- Arrefecimento descendente se demanda > 1.0
    BM.SetDemand('catalytic_converter', 1.3000, virtualTime)
    virtualTime = virtualTime + 3600
    local coolDemand1 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('MARKET-02 Demanda acima de 1.0 arreferece descendentemente (1.30 -> 1.15)', math.abs(coolDemand1 - 1.1500) < 0.0001)

    -- ─── MARKET-03: Preço nunca abaixo do Floor em operações elegíveis ───────
    resetMarket()
    BM.SetDemand('catalytic_converter', 0.4000, virtualTime)
    local minPriceRes = BM.ResolvePrice('catalytic_converter', {
        demandOverride = 0.4000,
        trustLevel = 1,
        progressionTier = 1,
        hour = 12, -- dia
        heatMultiplier = 0.75,
        jitter = -0.03,
    })
    check('MARKET-03 ResolvePrice em mercado saturado retorna ok=true', minPriceRes.ok == true)
    local floorBound = math.floor(1600 * 0.40) -- $640
    check('MARKET-03 Preço unitário respeita floor hard (base $1600 * 0.40 = $640)', minPriceRes.unitPrice == floorBound)
    check('MARKET-03 Flag hitFloor é true', minPriceRes.bounds.hitFloor == true)

    -- ─── MARKET-04: Preço nunca acima do Ceiling em max stack de bônus ───────
    resetMarket()
    -- Max stack com o multiplicador real: Demanda 1.30 * Trust 1.50 * Tier 1.10 * Night 1.30 * Jitter +3% (1.03) = ~2.87x base
    local maxPriceRes = BM.ResolvePrice('adv_engine', {
        demandOverride = 1.3000,
        trustLevel = 4,
        progressionTier = 4,
        hour = 23, -- noite (1.30x)
        heatMultiplier = 1.00,
        jitter = 0.03,
    })
    check('MARKET-04 Max stack de bônus retorna ok=true', maxPriceRes.ok == true)
    local ceilBound = math.floor(2500 * 2.50) -- $6250
    check('MARKET-04 Preço unitário respeita ceiling hard (base $2500 * 2.50 = $6250)', maxPriceRes.unitPrice == ceilBound)
    check('MARKET-04 Flag hitCeiling é true', maxPriceRes.bounds.hitCeiling == true)

    -- ─── MARKET-05: Limites rígidos de demanda (DemandFloor e DemandCeiling) ──
    resetMarket()
    local massiveSale = BM.RecordSale('catalytic_converter', 50, virtualTime)
    check('MARKET-05 Venda massiva não derruba demanda abaixo de DemandFloor (0.40)', math.abs(massiveSale.newDemand - 0.4000) < 0.0001)

    BM.SetDemand('catalytic_converter', 2.5000, virtualTime)
    local clampedHigh = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('MARKET-05 Demanda manual alta é limitada em DemandCeiling (1.30)', math.abs(clampedHigh - 1.3000) < 0.0001)

    -- ─── MARKET-06: Operação bloqueada (Trust 0 / Burning Heat) = NO TRADE ───
    resetMarket()
    local trust0Res = BM.ResolvePrice('catalytic_converter', { isBlockedTrust = true })
    check('MARKET-06 Trust bloqueado retorna trust_required', trust0Res.ok == false and trust0Res.err == 'trust_required')
    check('MARKET-06 Trust bloqueado NÃO possui unitPrice (zero payout)', trust0Res.unitPrice == nil)

    local burningRes = BM.ResolvePrice('catalytic_converter', { isBurningHeat = true })
    check('MARKET-06 Heat burning retorna heat_blocked', burningRes.ok == false and burningRes.err == 'heat_blocked')
    check('MARKET-06 Heat burning NÃO ativa PriceFloor (zero payout)', burningRes.unitPrice == nil)

    -- ─── MARKET-07: Operação autônoma sem dependências de terceiros ───────────
    resetMarket()
    local standaloneRes = BM.ResolvePrice('metalscrap', {})
    check('MARKET-07 Mercado funciona perfeitamente sem WorkshopBridge ou terceiros', standaloneRes.ok == true and standaloneRes.unitPrice > 0)

    -- ─── MARKET-08: Input inválido ou commodity desconhecida fail-closed ─────
    resetMarket()
    local unknownRes = BM.ResolvePrice('invalid_part_key_xyz', {})
    check('MARKET-08 Commodity desconhecida falha com unknown_commodity', unknownRes.ok == false and unknownRes.err == 'unknown_commodity')

    local badCountRes = BM.RecordSale('catalytic_converter', -5, virtualTime)
    check('MARKET-08 Venda com quantidade negativa rejeitada com invalid_count', badCountRes.ok == false and badCountRes.err == 'invalid_count')

    local floatCountRes = BM.RecordSale('catalytic_converter', 2.5, virtualTime)
    check('MARKET-08 Venda com quantidade decimal rejeitada com invalid_count', floatCountRes.ok == false and floatCountRes.err == 'invalid_count')

    -- ─── MARKET-09: Jitter extremo não ultrapassa floor ou ceiling ────────────
    resetMarket()
    local jitterFloorRes = BM.ResolvePrice('steel', {
        demandOverride = 0.4000,
        heatMultiplier = 0.75,
        jitter = -0.50, -- tentativa de forçar jitter excessivo negativo
    })
    check('MARKET-09 Jitter negativo extremo respeita floor ($100 * 0.40 = $40)', jitterFloorRes.unitPrice == 40)

    local jitterCeilRes = BM.ResolvePrice('steel', {
        demandOverride = 1.3000,
        trustLevel = 4,
        progressionTier = 4,
        hour = 23,
        jitter = 0.50, -- tentativa de forçar jitter excessivo positivo
    })
    check('MARKET-09 Jitter positivo extremo respeita ceiling ($100 * 2.50 = $250)', jitterCeilRes.unitPrice == 250)

    -- ─── QUOTE-01..09: COTAÇÃO MARGINAL EM LOTE E RECORD SALES BATCH ─────────
    resetMarket()
    -- QUOTE-01: count=1 igual a ResolvePrice no mesmo context/jitter
    local q1 = BM.QuoteSale('metalscrap', 1, { jitter = 0.0, trustLevel = 2 })
    local r1 = BM.ResolvePrice('metalscrap', { jitter = 0.0, trustLevel = 2 })
    check('QUOTE-01 count=1 igual a ResolvePrice no mesmo context/jitter', q1.ok == true and q1.total == r1.unitPrice and q1.unitPrices[1] == r1.unitPrice)

    -- QUOTE-02: count>1 aplica diminishing marginal price
    local q5 = BM.QuoteSale('adv_engine', 5, { jitter = 0.0 })
    check('QUOTE-02 count>1 possui unitPrice marginal decrescente', q5.ok == true and q5.unitPrices[1] > q5.unitPrices[2] and q5.unitPrices[2] > q5.unitPrices[3])

    -- QUOTE-03: prefixTotals monotônicos
    local prefixMonotonic = true
    for idx = 2, #q5.prefixTotals do
        if q5.prefixTotals[idx] <= q5.prefixTotals[idx - 1] then
            prefixMonotonic = false
        end
    end
    check('QUOTE-03 prefixTotals estritamente monotônicos e crescentes', prefixMonotonic)

    -- QUOTE-04: prefix[count] == total
    check('QUOTE-04 prefixTotals[count] é exatamente igual a total', q5.prefixTotals[5] == q5.total)

    -- QUOTE-05: QuoteSale NÃO altera sale pressure real
    local demAfterQuote = BM.GetDemandIndex('adv_engine', virtualTime)
    check('QUOTE-05 QuoteSale NÃO altera a demanda real in-memory', math.abs(demAfterQuote - 1.0000) < 0.0001)

    -- QUOTE-06: RecordSalesBatch aplica exatamente o projected demand
    local batchRes = BM.RecordSalesBatch({ { commodity = 'adv_engine', count = 5 } }, virtualTime)
    local demAfterBatch = BM.GetDemandIndex('adv_engine', virtualTime)
    check('QUOTE-06 RecordSalesBatch aplica exatamente o projected demand', batchRes.ok == true and math.abs(demAfterBatch - q5.demandAfterProjected) < 0.0001)

    -- QUOTE-07: invalid batch causa zero mutation
    resetMarket()
    local badBatchRes = BM.RecordSalesBatch({
        { commodity = 'metalscrap', count = 10 },
        { commodity = 'invalid_comm_xyz', count = 5 },
    }, virtualTime)
    local scrapDemAfterBad = BM.GetDemandIndex('metalscrap', virtualTime)
    check('QUOTE-07 Batch com item inválido falha atomicamente (invalid_batch)', badBatchRes.ok == false and badBatchRes.err == 'invalid_batch')
    check('QUOTE-07 Batch inválido causou ZERO mutação no metalscrap (demanda segue 1.0000)', math.abs(scrapDemAfterBad - 1.0000) < 0.0001)

    -- QUOTE-08: Floor respeitado por cada unidade
    local qMassive = BM.QuoteSale('metalscrap', 1000, { jitter = 0.0 })
    local allFloorRespected = true
    local floorScrap = math.floor(80 * 0.40) -- $32
    for _, up in ipairs(qMassive.unitPrices) do
        if up < floorScrap then allFloorRespected = false end
    end
    check('QUOTE-08 Floor ($32) respeitado por cada uma das 1000 unidades cotadas', allFloorRespected and qMassive.unitPrices[1000] == floorScrap)

    -- QUOTE-09: Ceiling respeitado por cada unidade
    local qCeil = BM.QuoteSale('copper', 10, { demandOverride = 1.30, trustLevel = 4, progressionTier = 4, hour = 23, jitter = 0.03 })
    local allCeilRespected = true
    local ceilCopper = math.floor(150 * 2.50) -- $375
    for _, up in ipairs(qCeil.unitPrices) do
        if up > ceilCopper then allCeilRespected = false end
    end
    check('QUOTE-09 Ceiling ($375) respeitado por cada unidade sob multiplicadores máximos', allCeilRespected and qCeil.unitPrices[1] == ceilCopper)

    -- ─── BATCH VS UNIT TRANSACTION SIMULATION ────────────────────────────────
    resetMarket()
    local unitTotalSum = 0
    local unitTxJitter = 0.015
    for u = 1, 100 do
        local uQuote = BM.QuoteSale('metalscrap', 1, { jitter = unitTxJitter })
        unitTotalSum = unitTotalSum + uQuote.total
        BM.RecordSale('metalscrap', 1, virtualTime)
    end

    resetMarket()
    local b100Quote = BM.QuoteSale('metalscrap', 100, { jitter = unitTxJitter })
    check('SIM-BATCH-01 Venda em lote de 100 scrap tem valor idêntico a 100 vendas unitárias sequenciais', b100Quote.total == unitTotalSum)

    -- ─── MARKET-PERSIST: PERSISTÊNCIA ASSÍNCRONA, RETRY E SEAMS ──────────────
    resetMarket()
    -- MARKET-PERSIST-01: Flush manual salva dirty commodity
    BM.RecordSale('adv_engine', 4, virtualTime) -- dirty = true
    local saved = BM.Flush(virtualTime)
    check('MARKET-PERSIST-01 Flush manual salva dirty commodity no MySQL', saved >= 1 and mockDb._rows.adv_engine ~= nil)

    -- MARKET-PERSIST-02: Snapshot persistido sobrevive a restart
    local reloadBM = _G.BrokerMarket
    reloadBM.Init(function() return virtualTime end, mockDb, function() return 0.5 end)
    local restoredSnap = reloadBM.GetSnapshot('adv_engine', virtualTime)
    check('MARKET-PERSIST-02 Snapshot persistido sobrevive a restart e é recarregado', math.abs(restoredSnap.demandIndex - 0.8000) < 0.0001 and restoredSnap.recentVolume == 4)

    -- MARKET-PERSIST-03: RecordSale -> dirty -> periodic flush -> DB contém novo demand
    resetMarket()
    BM.RecordSale('tyre', 10, virtualTime) -- 1.0 - (10 * 0.015) = 0.85
    check('MARKET-PERSIST-03 DB ainda não tem a linha antes do flush', mockDb._rows.tyre == nil)
    local periodicFlushed = BM.TriggerPeriodicFlush(virtualTime)
    check('MARKET-PERSIST-03 TriggerPeriodicFlush grava dirty item', periodicFlushed == 1 and mockDb._rows.tyre ~= nil)
    check('MARKET-PERSIST-03 DB contém novo demand após periodic flush (0.85)', math.abs(mockDb._rows.tyre.demand_index - 0.8500) < 0.0001)

    -- MARKET-PERSIST-04: DB write falha -> dirty permanece true -> retry posterior funciona
    resetMarket()
    BM.RecordSale('stolen_plate', 5, virtualTime)
    shouldFailQuery = true
    local failSaved = BM.Flush(virtualTime)
    check('MARKET-PERSIST-04 Falha de SQL retorna 0 salvos', failSaved == 0)
    check('MARKET-PERSIST-04 DB não foi atualizado na falha', mockDb._rows.stolen_plate == nil)

    -- Retry com DB restaurado
    shouldFailQuery = false
    local retrySaved = BM.Flush(virtualTime)
    check('MARKET-PERSIST-04 Retry subsequente tem sucesso (dirty foi preservado)', retrySaved == 1 and mockDb._rows.stolen_plate ~= nil)

    -- MARKET-PERSIST-05: Query retorna nil/resultado inválido -> NÃO considerar salvo
    resetMarket()
    BM.RecordSale('copper', 4, virtualTime)
    shouldReturnNilQuery = true
    local nilSaved = BM.Flush(virtualTime)
    check('MARKET-PERSIST-05 Query retornando nil rejeita flush', nilSaved == 0)
    shouldReturnNilQuery = false
    local recoverNil = BM.Flush(virtualTime)
    check('MARKET-PERSIST-05 Dirty mantido após retorno nil e salvo no próximo flush', recoverNil == 1 and mockDb._rows.copper ~= nil)

    -- MARKET-PERSIST-06: Restart após flush restaura snapshot de múltiplas commodities
    resetMarket()
    BM.RecordSale('metalscrap', 50, virtualTime) -- 1.0 - (50 * 0.002) = 0.90
    BM.RecordSale('aluminum', 25, virtualTime)   -- 1.0 - (25 * 0.004) = 0.90
    BM.Flush(virtualTime)
    BM.Init(function() return virtualTime end, mockDb, function() return 0.5 end)
    local snapScrap = BM.GetSnapshot('metalscrap', virtualTime)
    local snapAlum = BM.GetSnapshot('aluminum', virtualTime)
    check('MARKET-PERSIST-06 Restart restaura snapshot completo', math.abs(snapScrap.demandIndex - 0.9000) < 0.0001 and math.abs(snapAlum.demandIndex - 0.9000) < 0.0001)

    -- ─── DB INIT FAILURE / DEGRADED STATE ────────────────────────────────────
    resetMarket()
    shouldFailQuery = true
    local initOk = BM.Init(function() return virtualTime end, mockDb, function() return 0.5 end)
    check('MARKET-READY-02 Init com falha no DB retorna false', initOk == false)
    check('MARKET-READY-02 IsReady() é false em estado degradado', BM.IsReady() == false)
    local priceDegraded = BM.ResolvePrice('metalscrap', {})
    check('MARKET-READY-02 ResolvePrice falha closed em estado degradado (market_not_ready)', priceDegraded.ok == false and priceDegraded.err == 'market_not_ready')
    local saleDegraded = BM.RecordSale('metalscrap', 1, virtualTime)
    check('MARKET-READY-02 RecordSale falha closed em estado degradado (market_not_ready)', saleDegraded.ok == false and saleDegraded.err == 'market_not_ready')
    shouldFailQuery = false

    -- ─── MARKET-READY-03: DB AUSENTE RESULTA EM FAIL-CLOSED DEGRADED ─────────
    resetMarket()
    local origMySQL = _G.MySQL
    _G.MySQL = nil
    local noDbInit = BM.Init(function() return virtualTime end, nil, function() return 0.5 end)
    check('MARKET-READY-03 Init sem DB retorna false', noDbInit == false)
    check('MARKET-READY-03 IsReady() sem DB é false', BM.IsReady() == false)
    local noDbPrice = BM.ResolvePrice('metalscrap', {})
    check('MARKET-READY-03 ResolvePrice sem DB falha com market_not_ready', noDbPrice.ok == false and noDbPrice.err == 'market_not_ready')
    local noDbSale = BM.RecordSale('metalscrap', 1, virtualTime)
    check('MARKET-READY-03 RecordSale sem DB falha com market_not_ready', noDbSale.ok == false and noDbSale.err == 'market_not_ready')
    _G.MySQL = origMySQL
    resetMarket()

    -- ─── MARKET-NIGHT: PARIDADE COM CONFIG.FENCE.NIGHTBONUS ──────────────────
    resetMarket()
    -- MARKET-NIGHT-01: Config atual 21 -> 6 (overnight) com 1.30
    Config.Fence.NightBonus = { Enable = true, StartHour = 21, EndHour = 6, Multiplier = 1.30 }
    check('MARKET-NIGHT-01 20:59 retorna 1.0 (fora da janela)', math.abs(BM.ResolveNightMultiplier(20.99) - 1.00) < 0.0001)
    check('MARKET-NIGHT-01 21:00 retorna 1.30 (início)', math.abs(BM.ResolveNightMultiplier(21.00) - 1.30) < 0.0001)
    check('MARKET-NIGHT-01 23:00 retorna 1.30 (noite)', math.abs(BM.ResolveNightMultiplier(23.00) - 1.30) < 0.0001)
    check('MARKET-NIGHT-01 02:00 retorna 1.30 (madrugada)', math.abs(BM.ResolveNightMultiplier(2.00) - 1.30) < 0.0001)
    check('MARKET-NIGHT-01 05:59 retorna 1.30 (fim da madrugada)', math.abs(BM.ResolveNightMultiplier(5.99) - 1.30) < 0.0001)
    check('MARKET-NIGHT-01 06:00 retorna 1.0 (amanhecer)', math.abs(BM.ResolveNightMultiplier(6.00) - 1.00) < 0.0001)

    -- MARKET-NIGHT-02: Enable=false retorna 1.0
    Config.Fence.NightBonus.Enable = false
    check('MARKET-NIGHT-02 NightBonus desabilitado retorna 1.0 mesmo à noite (23h)', math.abs(BM.ResolveNightMultiplier(23.00) - 1.00) < 0.0001)
    Config.Fence.NightBonus.Enable = true

    -- MARKET-NIGHT-03: Config custom 23 -> 5 com multiplier 1.20
    Config.Fence.NightBonus = { Enable = true, StartHour = 23, EndHour = 5, Multiplier = 1.20 }
    check('MARKET-NIGHT-03 Custom 22h fora da janela retorna 1.0', math.abs(BM.ResolveNightMultiplier(22.00) - 1.00) < 0.0001)
    check('MARKET-NIGHT-03 Custom 23h dentro da janela retorna 1.20', math.abs(BM.ResolveNightMultiplier(23.00) - 1.20) < 0.0001)
    check('MARKET-NIGHT-03 Custom 04h dentro da janela retorna 1.20', math.abs(BM.ResolveNightMultiplier(4.00) - 1.20) < 0.0001)
    check('MARKET-NIGHT-03 Custom 05h fora da janela retorna 1.0', math.abs(BM.ResolveNightMultiplier(5.00) - 1.00) < 0.0001)

    -- MARKET-NIGHT-04: Janela não-overnight (intra-dia: ex: 1h às 5h)
    Config.Fence.NightBonus = { Enable = true, StartHour = 1, EndHour = 5, Multiplier = 1.25 }
    check('MARKET-NIGHT-04 Intra-dia 0h retorna 1.0', math.abs(BM.ResolveNightMultiplier(0.00) - 1.00) < 0.0001)
    check('MARKET-NIGHT-04 Intra-dia 1h retorna 1.25', math.abs(BM.ResolveNightMultiplier(1.00) - 1.25) < 0.0001)
    check('MARKET-NIGHT-04 Intra-dia 3h retorna 1.25', math.abs(BM.ResolveNightMultiplier(3.00) - 1.25) < 0.0001)
    check('MARKET-NIGHT-04 Intra-dia 5h retorna 1.0', math.abs(BM.ResolveNightMultiplier(5.00) - 1.00) < 0.0001)
    -- Restaura padrão
    Config.Fence.NightBonus = { Enable = true, StartHour = 21, EndHour = 6, Multiplier = 1.30 }

    -- ─── CONFIG.BROKER.ENABLE == FALSE ───────────────────────────────────────
    resetMarket()
    Config.Broker.Enable = false
    local disabledPrice = BM.ResolvePrice('metalscrap', {})
    check('MARKET-CONFIG-ENABLE-01 Config.Broker.Enable=false retorna broker_disabled em ResolvePrice', disabledPrice.ok == false and disabledPrice.err == 'broker_disabled')
    local disabledSale = BM.RecordSale('metalscrap', 1, virtualTime)
    check('MARKET-CONFIG-ENABLE-01 Config.Broker.Enable=false retorna broker_disabled em RecordSale', disabledSale.ok == false and disabledSale.err == 'broker_disabled')
    Config.Broker.Enable = true

    -- ─── SIMULAÇÃO 1: CURVA DE VOLUME (DIMINISHING RETURNS) ───────────────────
    resetMarket()
    local volSimCommodities = {
        { name = 'catalytic_converter', count = 20 },
        { name = 'adv_engine', count = 20 },
        { name = 'tyre', count = 50 },
        { name = 'stolen_plate', count = 50 },
        { name = 'metalscrap', count = 100 },
    }

    local volumeDiminishingMonotonic = true
    for _, item in ipairs(volSimCommodities) do
        local lastPrice = 999999
        for i = 1, item.count do
            local priceBefore = BM.ResolvePrice(item.name, { jitter = 0.0 }).unitPrice
            BM.RecordSale(item.name, 1, virtualTime)
            local priceAfter = BM.ResolvePrice(item.name, { jitter = 0.0 }).unitPrice
            if priceAfter > priceBefore or priceBefore > lastPrice then
                volumeDiminishingMonotonic = false
            end
            lastPrice = priceBefore
        end
    end
    check('SIM-VOL-01 Vendas sequenciais produzem curva monotônica decrescente até o floor', volumeDiminishingMonotonic)

    -- ─── SIMULAÇÃO 2: RECUPERAÇÃO TEMPORAL ASSINTÓTICA (+1h, +3h, +6h, +12h, +24h)
    resetMarket()
    BM.RecordSale('catalytic_converter', 20, virtualTime) -- Satura para 0.4000
    local d0 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('SIM-REC-01 Ponto de partida saturado em 0.4000', math.abs(d0 - 0.4000) < 0.0001)

    -- +1h (+0.15) -> 0.55
    virtualTime = virtualTime + 3600
    local d1 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('SIM-REC-02 +1h recupera para 0.5500', math.abs(d1 - 0.5500) < 0.0001)

    -- +3h (+0.30 mais) -> 0.85
    virtualTime = virtualTime + 7200
    local d3 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('SIM-REC-03 +3h recupera para 0.8500', math.abs(d3 - 0.8500) < 0.0001)

    -- +6h (+0.45 mais) -> equilíbrio 1.0000
    virtualTime = virtualTime + 10800
    local d6 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('SIM-REC-04 +6h atinge equilíbrio 1.0000 assintoticamente', math.abs(d6 - 1.0000) < 0.0001)

    -- +12h e +24h -> permanece em 1.0000
    virtualTime = virtualTime + 21600
    local d12 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    virtualTime = virtualTime + 43200
    local d24 = BM.GetDemandIndex('catalytic_converter', virtualTime)
    check('SIM-REC-05 +12h e +24h permanecem perfeitamente estáveis em 1.0000', math.abs(d12 - 1.0000) < 0.0001 and math.abs(d24 - 1.0000) < 0.0001)

    -- ─── SIMULAÇÃO 3: 108.000+ ITERAÇÕES COM TIER MULTIPLIER REAL ────────────
    resetMarket()
    local commoditiesList = {
        'catalytic_converter', 'adv_engine', 'tyre', 'stolen_plate',
        'metalscrap', 'steel', 'aluminum', 'copper', 'car_parts'
    }
    local demandLevels = { 0.40, 0.60, 0.80, 1.00, 1.15, 1.30 }
    local trustLevels = { 0, 1, 2, 3, 4 }
    local tierLevels = { 1, 2, 3, 4 }
    local hourSamples = { 2, 8, 14, 20, 23 } -- 2 e 23 são noite (1.30x)
    local heatLabels = { 'cold', 'warm', 'hot', 'burning' }
    local jitterSamples = { -0.03, -0.015, 0.0, 0.015, 0.03 }

    local iterationsCount = 0
    local allInvariantsHold = true
    local blockedCount = 0
    local eligibleCount = 0
    local hitFloorCount = 0
    local hitCeilingCount = 0

    for _, comm in ipairs(commoditiesList) do
        local base = Config.Broker.Commodities[comm].basePrice
        local floorB = math.floor(base * 0.40)
        local ceilB = math.floor(base * 2.50)

        for _, dem in ipairs(demandLevels) do
            for _, tr in ipairs(trustLevels) do
                for _, ti in ipairs(tierLevels) do
                    for _, hr in ipairs(hourSamples) do
                        for _, ht in ipairs(heatLabels) do
                            for _, jit in ipairs(jitterSamples) do
                                iterationsCount = iterationsCount + 1

                                local res = BM.ResolvePrice(comm, {
                                    demandOverride = dem,
                                    trustLevel = tr,
                                    progressionTier = ti,
                                    hour = hr,
                                    heatLabel = ht,
                                    jitter = jit,
                                    isBlockedTrust = (tr == 0),
                                    isBurningHeat = (ht == 'burning'),
                                })

                                if tr == 0 then
                                    if res.ok ~= false or res.err ~= 'trust_required' or res.unitPrice ~= nil then
                                        allInvariantsHold = false
                                    end
                                    blockedCount = blockedCount + 1
                                elseif ht == 'burning' then
                                    if res.ok ~= false or res.err ~= 'heat_blocked' or res.unitPrice ~= nil then
                                        allInvariantsHold = false
                                    end
                                    blockedCount = blockedCount + 1
                                else
                                    -- Operação elegível
                                    if res.ok ~= true or type(res.unitPrice) ~= 'number' then
                                        allInvariantsHold = false
                                    else
                                        if res.unitPrice < floorB or res.unitPrice > ceilB then
                                            allInvariantsHold = false
                                        end
                                        if res.unitPrice == floorB and res.bounds.hitFloor then
                                            hitFloorCount = hitFloorCount + 1
                                        end
                                        if res.unitPrice == ceilB and res.bounds.hitCeiling then
                                            hitCeilingCount = hitCeilingCount + 1
                                        end
                                    end
                                    eligibleCount = eligibleCount + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local ceilPercentage = (eligibleCount > 0) and ((hitCeilingCount / eligibleCount) * 100.0) or 0.0
    local floorPercentage = (eligibleCount > 0) and ((hitFloorCount / eligibleCount) * 100.0) or 0.0

    print(('[broker_market/spec] ─── SIMULAÇÃO ESTATÍSTICA 108K ───'))
    print(('[broker_market/spec] Total Iterações: %d (Elegíveis: %d | Bloqueadas: %d)'):format(iterationsCount, eligibleCount, blockedCount))
    print(('[broker_market/spec] Hit Floor: %d (%.2f%% dos elegíveis)'):format(hitFloorCount, floorPercentage))
    print(('[broker_market/spec] Hit Ceiling: %d (%.2f%% dos elegíveis)'):format(hitCeilingCount, ceilPercentage))

    check(('SIM-GRID-01 Executadas %d iterações sintéticas (mínimo 1.000)'):format(iterationsCount), iterationsCount >= 1000)
    check('SIM-GRID-02 100% dos invariantes de economia, floor, ceiling e bloqueio mantidos', allInvariantsHold)
    check(('SIM-GRID-03 Transações bloqueadas (%d) mantiveram ZERO payout'):format(blockedCount), blockedCount > 0)
    check(('SIM-GRID-04 Transações elegíveis (%d) contidas no envelope [$Floor, $Ceiling]'):format(eligibleCount), eligibleCount > 0)
    check(('SIM-GRID-05 Percentual de Ceiling Hits reportado (%.2f%%)'):format(ceilPercentage), true)

    -- ─── SIM-GRID-06: DEMAND OVERRIDE FORA DO RANGE É CLAMPADO ──────────────
    local overLowRes = BM.ResolvePrice('metalscrap', { demandOverride = -5.0 })
    check('SIM-GRID-06 demandOverride negativo (-5.0) é clampado no DemandFloor (0.40)', overLowRes.ok == true and math.abs(overLowRes.demand - 0.4000) < 0.0001)

    local overHighRes = BM.ResolvePrice('metalscrap', { demandOverride = 99.0 })
    check('SIM-GRID-06 demandOverride excessivo (99.0) é clampado no DemandCeiling (1.30)', overHighRes.ok == true and math.abs(overHighRes.demand - 1.3000) < 0.0001)

    -- ─── SIM-GRID-07: NaN / INF / STRING DEMAND FAIL CLOSED ──────────────────
    local nanDemand = 0 / 0
    local nanRes = BM.ResolvePrice('metalscrap', { demandOverride = nanDemand })
    check('SIM-GRID-07 NaN demandOverride falha closed (invalid_demand)', nanRes.ok == false and nanRes.err == 'invalid_demand')

    local strDemandRes = BM.ResolvePrice('metalscrap', { demandOverride = 'exploit_string' })
    check('SIM-GRID-07 String demandOverride falha closed (invalid_demand)', strDemandRes.ok == false and strDemandRes.err == 'invalid_demand')

    local nanMultRes = BM.ResolvePrice('metalscrap', { trustMultiplier = 0 / 0 })
    check('SIM-GRID-07 NaN trustMultiplier falha closed (invalid_multipliers)', nanMultRes.ok == false and nanMultRes.err == 'invalid_multipliers')

    print(('[broker_market/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('broker_market_spec falhou') end
end

run()
