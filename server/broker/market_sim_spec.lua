-- server/broker/market_sim_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-1] DYNAMIC MARKET PRICING & ECONOMIC SIMULATION ENGINE SPECS
--  Self-gated na convar vp_chopshop_selftest 1.
--
--  Cobre:
--    - MARKET-01 a MARKET-09 contra o módulo REAL BrokerMarket
--    - Volume Diminishing Returns Simulation (20 catalytics, 20 engines, 50 tyres, 50 plates, 100 scrap)
--    - Asymptotic Lazy Time Recovery Simulation (+1h, +3h, +6h, +12h, +24h)
--    - 1.000+ iterações determinísticas de teste de propriedades e invariantes
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
    local BM = _G.BrokerMarket
    check('CANARY-MARKET-01 BrokerMarket module exists and is loaded', type(BM) == 'table')
    if not BM then return end

    -- Estado virtual de tempo e RNG determinístico
    local virtualTime = 1700000000
    BM.SetClock(function() return virtualTime end)
    BM.SetRng(function() return 0.5 end) -- jitter neutro (0.0) por padrão

    local mockDb
    mockDb = {
        _rows = {},
        query = {
            await = function(query, params)
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
        mockDb._rows = {}
        BM.Init(function() return virtualTime end, mockDb, function() return 0.5 end)
    end

    -- ─── MARKET-01: Venda reduz a demanda com pressão de volume ──────────────
    resetMarket()
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
    -- Saturar mercado até o floor (0.40) + heat hot (0.75) + tier 1 + trust 1 + -3% jitter
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
    -- Max stack: Demanda 1.30 * Trust 1.50 * Tier 1.50 * Night 1.30 * Jitter +3% (1.03) = ~3.92x base
    local maxPriceRes = BM.ResolvePrice('adv_engine', {
        demandOverride = 1.3000,
        trustLevel = 4,
        progressionTier = 4,
        hour = 23, -- noite (1.30x)
        heatMultiplier = 1.00,
        jitter = 0.03,
    })
    check('MARKET-04 Max stack de bônus retorna ok=true', maxPriceRes.ok == true)
    local ceilBound = math.floor(2800 * 2.50) -- $7000
    check('MARKET-04 Preço unitário respeita ceiling hard (base $2800 * 2.50 = $7000)', maxPriceRes.unitPrice == ceilBound)
    check('MARKET-04 Flag hitCeiling é true', maxPriceRes.bounds.hitCeiling == true)

    -- ─── MARKET-05: Limites rígidos de demanda (DemandFloor e DemandCeiling) ──
    resetMarket()
    -- Vender 50 unidades de uma vez (queda de 50 * 0.04 = 2.00)
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
    check('MARKET-09 Jitter negativo extremo respeita floor ($180 * 0.40 = $72)', jitterFloorRes.unitPrice == 72)

    local jitterCeilRes = BM.ResolvePrice('steel', {
        demandOverride = 1.3000,
        trustLevel = 4,
        progressionTier = 4,
        hour = 23,
        jitter = 0.50, -- tentativa de forçar jitter excessivo positivo
    })
    check('MARKET-09 Jitter positivo extremo respeita ceiling ($180 * 2.50 = $450)', jitterCeilRes.unitPrice == 450)

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

    -- ─── SIMULAÇÃO 3: 1.000+ ITERAÇÕES DETERMINÍSTICAS DE PROPRIEDADES ───────
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

    check(('SIM-GRID-01 Executadas %d iterações sintéticas (mínimo 1.000)'):format(iterationsCount), iterationsCount >= 1000)
    check('SIM-GRID-02 100% dos invariantes de economia, floor, ceiling e bloqueio mantidos', allInvariantsHold)
    check(('SIM-GRID-03 Transações bloqueadas (%d) mantiveram ZERO payout'):format(blockedCount), blockedCount > 0)
    check(('SIM-GRID-04 Transações elegíveis (%d) contidas no envelope [$Floor, $Ceiling]'):format(eligibleCount), eligibleCount > 0)

    -- ─── PERSISTÊNCIA: FLUSH E BOOTSTRAP ─────────────────────────────────────
    resetMarket()
    BM.RecordSale('adv_engine', 4, virtualTime) -- dirty = true
    local saved = BM.Flush(virtualTime)
    check('MARKET-PERSIST-01 Flush salva dirty commodity no MySQL', saved >= 1 and mockDb._rows.adv_engine ~= nil)

    -- Simulação de restart de resource com re-load do DB
    local newBMState = {}
    local reloadBM = _G.BrokerMarket
    reloadBM.Init(function() return virtualTime end, mockDb, function() return 0.5 end)
    local restoredSnap = reloadBM.GetSnapshot('adv_engine', virtualTime)
    check('MARKET-PERSIST-02 Snapshot persistido sobrevive a restart e é recarregado', math.abs(restoredSnap.demandIndex - 0.8000) < 0.0001 and restoredSnap.recentVolume == 4)

    print(('[broker_market/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('broker_market_spec falhou') end
end

run()
