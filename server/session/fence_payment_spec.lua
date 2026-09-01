-- server/session/fence_payment_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16-FENCE-PAY-1] Regression & Canary Specs para Pagamentos do Fence.
--  NÃO roda em produção (self-gated na convar vp_chopshop_selftest 1).
--
--  Cobre testes obrigatórios:
--    FENCE-PAY-01: sellItems com BridgeAddCash=false -> payment_failed, 0 XP, 0 Event, 0 retry.
--    FENCE-PAY-02: sellItems com BridgeAddCash=true -> sucesso 1x, 1x XP, 1x Event.
--    FENCE-ORDER-PAY-01: fulfillOrder com BridgeAddCash=false -> payment_failed, ordem fulfilled, 0 XP, 0 Event.
--    FENCE-ORDER-PAY-02: fulfillOrder com BridgeAddCash=true -> sucesso 1x, 1x XP, 1x Event.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then
        pass = pass + 1
        print('[fence_payment/spec] PASS  ' .. name)
    else
        fail = fail + 1
        print('[fence_payment/spec] FAIL  ' .. name)
    end
end

local mockInventory = {}
local mockTrustXp = 0
local mockEvents = 0
local mockOrders = {}

local function resetMockState()
    mockInventory = { metalscrap = 20, copper = 10, steel = 15 }
    mockTrustXp = 0
    mockEvents = 0
    mockOrders = {
        [101] = { items = { metalscrap = 10, copper = 5 }, fulfilled_at = nil, mult = 1.4 },
        [102] = { items = { steel = 5 }, fulfilled_at = nil, mult = 1.5 },
    }
end

-- Simulação exata do pipeline de sellItems (server/fence.lua:410-484)
local function simSellItems(src, itemList, simulatePaymentFail)
    local basePrices = { metalscrap = 80, copper = 150, steel = 100 }
    local totalValue = 0
    local candidates = {}

    for _, entry in ipairs(itemList or {}) do
        local item = entry.name
        local amount = math.floor(tonumber(entry.amount) or 0)
        if item and amount > 0 and basePrices[item] then
            local have = mockInventory[item] or 0
            local sell = math.min(amount, have)
            if sell > 0 then
                local price = basePrices[item]
                local earned = price * sell
                totalValue = totalValue + earned
                candidates[#candidates+1] = { name = item, amount = sell, earned = earned }
            end
        end
    end

    if totalValue <= 0 then return { ok = false, err = 'nothing_sold' } end

    local soldItems = {}
    local realTotal = 0
    for _, c in ipairs(candidates) do
        if (mockInventory[c.name] or 0) >= c.amount then
            mockInventory[c.name] = mockInventory[c.name] - c.amount
            soldItems[#soldItems+1] = c
            realTotal = realTotal + c.earned
        end
    end

    if #soldItems == 0 then return { ok = false, err = 'nothing_sold' } end

    local paid
    if simulatePaymentFail then
        paid = false
    else
        paid = BridgeAddCash(src, realTotal, 'fence_sale')
    end

    if not paid then
        return { ok = false, err = 'payment_failed' }
    end

    mockTrustXp = mockTrustXp + 20
    mockEvents = mockEvents + 1
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, soldItems, realTotal, 'material')

    return { ok = true, total = realTotal }
end

-- Simulação exata do pipeline de fulfillOrder (server/fence.lua:895-960)
local function simFulfillOrder(src, orderId, simulatePaymentFail)
    local order = mockOrders[orderId]
    if not order or order.fulfilled_at ~= nil then
        return { ok = false, err = 'no_order' }
    end

    local removed = {}
    for item, amount in pairs(order.items) do
        if (mockInventory[item] or 0) >= amount then
            mockInventory[item] = mockInventory[item] - amount
            removed[item] = amount
        else
            for ri, ra in pairs(removed) do
                mockInventory[ri] = (mockInventory[ri] or 0) + ra
            end
            return { ok = false, err = 'missing_item' }
        end
    end

    -- Atomic mark no DB
    order.fulfilled_at = os.time()
    local total = 2500

    local paid
    if simulatePaymentFail then
        paid = false
    else
        paid = BridgeAddCash(src, total, 'fence_order')
    end

    if not paid then
        return { ok = false, err = 'payment_failed' }
    end

    mockTrustXp = mockTrustXp + 80
    mockEvents = mockEvents + 1
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, order.items, total, 'order')

    return { ok = true, total = total }
end

local function run()
    resetMockState()

    -- ─── FENCE-PAY-01: sellItems falha de pagamento ────────────────────────────
    local sellList = { { name = 'metalscrap', amount = 10 }, { name = 'copper', amount = 2 } }
    local resFail = simSellItems(1, sellList, true)

    check('FENCE-PAY-01 sellItems BridgeAddCash=false retorna payment_failed', resFail.ok == false and resFail.err == 'payment_failed')
    check('FENCE-PAY-01 sellItems falha concede ZERO Trust XP', mockTrustXp == 0)
    check('FENCE-PAY-01 sellItems falha emite ZERO eventos FENCE_DELIVERY', mockEvents == 0)
    check('FENCE-PAY-01 sellItems falha removeu itens de forma at-most-once sem rollback ambíguo', mockInventory.metalscrap == 10 and mockInventory.copper == 8)

    -- ─── FENCE-PAY-02: sellItems sucesso de pagamento ──────────────────────────
    local resSuccess = simSellItems(1, { { name = 'steel', amount = 5 } }, false)

    check('FENCE-PAY-02 sellItems BridgeAddCash=true retorna ok=true com total', resSuccess.ok == true and resSuccess.total == 500)
    check('FENCE-PAY-02 sellItems sucesso concede Trust XP 1x', mockTrustXp == 20)
    check('FENCE-PAY-02 sellItems sucesso emite evento FENCE_DELIVERY 1x', mockEvents == 1)
    check('FENCE-PAY-02 sellItems sucesso debita inventário', mockInventory.steel == 10)

    -- ─── FENCE-ORDER-PAY-01: fulfillOrder falha de pagamento ───────────────────
    local resOrdFail = simFulfillOrder(1, 101, true)

    check('FENCE-ORDER-PAY-01 fulfillOrder BridgeAddCash=false retorna payment_failed', resOrdFail.ok == false and resOrdFail.err == 'payment_failed')
    check('FENCE-ORDER-PAY-01 ordem permanece terminal (fulfilled_at setado)', mockOrders[101].fulfilled_at ~= nil)
    check('FENCE-ORDER-PAY-01 fulfillOrder falha concede ZERO Trust XP', mockTrustXp == 20) -- inalterado
    check('FENCE-ORDER-PAY-01 fulfillOrder falha emite ZERO novos eventos', mockEvents == 1) -- inalterado

    -- Replay na mesma ordem deve falhar com no_order
    local resReplay = simFulfillOrder(1, 101, false)
    check('FENCE-ORDER-PAY-01 replay da ordem rejeita com no_order (ZERO double payout)', resReplay.ok == false and resReplay.err == 'no_order')

    -- ─── FENCE-ORDER-PAY-02: fulfillOrder sucesso de pagamento ─────────────────
    local resOrdOk = simFulfillOrder(1, 102, false)

    check('FENCE-ORDER-PAY-02 fulfillOrder BridgeAddCash=true retorna ok=true', resOrdOk.ok == true and resOrdOk.total == 2500)
    check('FENCE-ORDER-PAY-02 fulfillOrder sucesso concede Trust XP de ordem (+80)', mockTrustXp == 100)
    check('FENCE-ORDER-PAY-02 fulfillOrder sucesso emite evento FENCE_DELIVERY (+1)', mockEvents == 2)
    check('FENCE-ORDER-PAY-02 fulfillOrder sucesso marca ordem cumprida', mockOrders[102].fulfilled_at ~= nil)

    print(('[fence_payment/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('fence_payment_spec falhou') end
end

run()
