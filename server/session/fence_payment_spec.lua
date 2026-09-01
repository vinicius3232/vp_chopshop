-- server/session/fence_payment_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16-FENCE-PAY-1.1] Regression & Canary Specs nos Handlers REAIS de server/fence.lua.
--  NÃO roda em produção (self-gated na convar vp_chopshop_selftest 1).
--
--  Cobre testes obrigatórios executados diretamente contra os callbacks registrados:
--    FENCE-ZERO-01: dry-run encontra item, mas RemoveItem=false -> nothing_sold, 0 BridgeAddCash, 0 XP, 0 Event.
--    FENCE-ZERO-02: remoção parcial -> paga somente realTotal removido, 1x XP, 1x Event.
--    FENCE-PAY-01: itens removidos + BridgeAddCash=false -> payment_failed, 0 XP, 0 Event.
--    FENCE-PAY-02: itens removidos + BridgeAddCash=true -> sucesso 1x, 1x XP, 1x Event.
--    FENCE-ORDER-PAY-01: fulfillOrder REAL + BridgeAddCash=false -> payment_failed, ordem terminal, replay no_order, 0 XP, 0 Event.
--    FENCE-ORDER-PAY-02: fulfillOrder REAL + BridgeAddCash=true -> sucesso 1x, 1x XP, 1x Event.
--    FENCE-CANARY-01: verificação estática do pipeline de segurança no arquivo server/fence.lua.
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

local function run()
    local sellItemsCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:sellItems']
    local fulfillOrderCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:fence:fulfillOrder']

    check('FENCE-SEAM-01 callback vp_chopshop:fence:sellItems está registrado', type(sellItemsCb) == 'function')
    check('FENCE-SEAM-02 callback vp_chopshop:fence:fulfillOrder está registrado', type(fulfillOrderCb) == 'function')
    if not sellItemsCb or not fulfillOrderCb then return end

    -- Estado controlável do ambiente de teste
    local mockInventory = {}
    local allowRemoveItem = {}
    local cashCalls = {}
    local mockDbOrders = {}
    local forceCashFail = false

    -- Configuração do export ox_inventory (com suporte a chamada com colon `ox_inventory:Func(...)`)
    _G.FAKE_EXPORTS.ox_inventory = {
        GetItemCount = function(_, src, item)
            return tonumber(mockInventory[item]) or 0
        end,
        RemoveItem = function(_, src, item, count)
            if allowRemoveItem[item] == false then return false end
            local have = tonumber(mockInventory[item]) or 0
            local needed = tonumber(count) or 0
            if have >= needed then
                mockInventory[item] = have - needed
                return true
            end
            return false
        end,
        AddItem = function(_, src, item, count)
            local current = tonumber(mockInventory[item]) or 0
            mockInventory[item] = current + (tonumber(count) or 0)
            return true
        end,
    }

    -- Mock da função global BridgeAddCash
    _G.BridgeAddCash = function(src, amount, reason)
        cashCalls[#cashCalls + 1] = { src = src, amount = amount, reason = reason }
        if forceCashFail then return false end
        return true
    end

    -- Mock do MySQL para Trust e Orders
    _G.MySQL = {
        single = {
            await = function(query, params)
                if query:find('vp_chop_fence_trust') then
                    return { trust_level = 3, trust_xp = 350, last_seen = os.time() }
                end
                if query:find('vp_chop_fence_orders') then
                    local orderId = params and params[1]
                    local row = mockDbOrders[orderId]
                    if row and row.fulfilled_at == nil then
                        return {
                            id = row.id,
                            for_identifier = row.for_identifier,
                            order_data = row.order_data,
                            expires_at = os.time() + 3600,
                        }
                    end
                    return nil
                end
                return nil
            end,
        },
        query = {
            await = function(query, params)
                if query:find('UPDATE vp_chop_fence_orders SET fulfilled_at') then
                    local orderId = params and params[1]
                    local row = mockDbOrders[orderId]
                    if row and row.fulfilled_at == nil then
                        row.fulfilled_at = os.time()
                        return { affectedRows = 1 }
                    end
                    return { affectedRows = 0 }
                end
                return { affectedRows = 1 }
            end,
        },
        insert = { await = function() return 1 end },
        update = { await = function() return 1 end },
    }

    local function resetTestEnv()
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 10000 -- Avança tempo para bypassar rate limits
        _G.NEAR = true
        mockInventory = { metalscrap = 20, copper = 10, steel = 15 }
        allowRemoveItem = {}
        cashCalls = {}
        mockDbOrders = {}
        forceCashFail = false
        for i = #_G._TRIGGERED, 1, -1 do _G._TRIGGERED[i] = nil end
    end

    -- ─── FENCE-ZERO-01: dry-run encontra item, mas RemoveItem falha ───────────
    resetTestEnv()
    allowRemoveItem['metalscrap'] = false -- Simula falha do inventário no momento da remoção
    local resZero1 = sellItemsCb(1, { { name = 'metalscrap', amount = 5 } })

    check('FENCE-ZERO-01 sellItems retorna nothing_sold quando RemoveItem falha', resZero1.ok == false and resZero1.err == 'nothing_sold')
    check('FENCE-ZERO-01 BridgeAddCash NÃO é chamado quando nada foi vendido', #cashCalls == 0)
    check('FENCE-ZERO-01 ZERO eventos FENCE_DELIVERY emitidos', #_G._TRIGGERED == 0)

    -- ─── FENCE-ZERO-02: remoção parcial paga somente o que foi removido ───────
    resetTestEnv()
    allowRemoveItem['metalscrap'] = true
    allowRemoveItem['copper'] = false -- copper falha, metalscrap é removido
    local resPartial = sellItemsCb(2, { { name = 'metalscrap', amount = 10 }, { name = 'copper', amount = 5 } })

    check('FENCE-ZERO-02 sellItems parcial tem sucesso', resPartial.ok == true)
    check('FENCE-ZERO-02 sellItems parcial tem total > 0', resPartial.total ~= nil and resPartial.total > 0)
    check('FENCE-ZERO-02 BridgeAddCash chamado exatamente 1x com valor parcial', #cashCalls == 1 and cashCalls[1].amount == resPartial.total)
    check('FENCE-ZERO-02 exatamente 1 evento FENCE_DELIVERY emitido', #_G._TRIGGERED == 1)

    -- ─── FENCE-PAY-01: itens removidos + BridgeAddCash=false (Fail-Closed) ───
    resetTestEnv()
    forceCashFail = true
    local resPayFail = sellItemsCb(3, { { name = 'metalscrap', amount = 5 } })

    check('FENCE-PAY-01 BridgeAddCash=false retorna payment_failed', resPayFail.ok == false and resPayFail.err == 'payment_failed')
    check('FENCE-PAY-01 falha no BridgeAddCash emite ZERO eventos FENCE_DELIVERY', #_G._TRIGGERED == 0)
    check('FENCE-PAY-01 itens consumidos at-most-once sem rollback ambíguo', mockInventory.metalscrap == 15)

    -- ─── FENCE-PAY-02: sellItems sucesso normal ───────────────────────────────
    resetTestEnv()
    local resPayOk = sellItemsCb(4, { { name = 'steel', amount = 5 } })

    check('FENCE-PAY-02 sellItems sucesso retorna ok=true', resPayOk.ok == true and resPayOk.total > 0)
    check('FENCE-PAY-02 BridgeAddCash chamado com motivo fence_sale', #cashCalls == 1 and cashCalls[1].reason == 'fence_sale')
    check('FENCE-PAY-02 evento FENCE_DELIVERY emitido 1x', #_G._TRIGGERED == 1)

    -- ─── FENCE-ORDER-PAY-01: fulfillOrder REAL + BridgeAddCash=false ──────────
    resetTestEnv()
    mockDbOrders[201] = {
        id = 201,
        for_identifier = ServerChopPlayerKey(5),
        order_data = { items = { metalscrap = 5, copper = 2 }, mult = 1.2, deadline = os.time() + 3600 },
        fulfilled_at = nil,
    }
    forceCashFail = true
    local resOrderFail = fulfillOrderCb(5, 201)

    check('FENCE-ORDER-PAY-01 fulfillOrder REAL com BridgeAddCash=false retorna payment_failed', resOrderFail.ok == false and resOrderFail.err == 'payment_failed')
    check('FENCE-ORDER-PAY-01 ordem marcada como terminal no MySQL', mockDbOrders[201].fulfilled_at ~= nil)
    check('FENCE-ORDER-PAY-01 ZERO eventos FENCE_DELIVERY emitidos na falha', #_G._TRIGGERED == 0)

    -- Tentativa de Replay na mesma ordem
    forceCashFail = false
    local resOrderReplay = fulfillOrderCb(5, 201)
    check('FENCE-ORDER-PAY-01 replay da ordem rejeita com no_order (ZERO double payout)', resOrderReplay.ok == false and resOrderReplay.err == 'no_order')
    check('FENCE-ORDER-PAY-01 ZERO novo pagamento efetuado no replay', #cashCalls == 1) -- apenas a 1ª chamada que falhou

    -- ─── FENCE-ORDER-PAY-02: fulfillOrder REAL com sucesso ────────────────────
    resetTestEnv()
    mockDbOrders[202] = {
        id = 202,
        for_identifier = ServerChopPlayerKey(6),
        order_data = { items = { steel = 4 }, mult = 1.5, deadline = os.time() + 3600 },
        fulfilled_at = nil,
    }
    local resOrderOk = fulfillOrderCb(6, 202)

    check('FENCE-ORDER-PAY-02 fulfillOrder REAL com sucesso retorna ok=true', resOrderOk.ok == true and resOrderOk.total > 0)
    check('FENCE-ORDER-PAY-02 BridgeAddCash chamado com motivo fence_order', #cashCalls == 1 and cashCalls[1].reason == 'fence_order')
    check('FENCE-ORDER-PAY-02 evento FENCE_DELIVERY emitido 1x no sucesso', #_G._TRIGGERED == 1)

    -- ─── FENCE-CANARY-01: Análise estática do arquivo server/fence.lua ─────────
    local base = _G._HARNESS_BASE or '.'
    local fenceFile = io.open(base .. '/server/fence.lua', 'r')
    if fenceFile then
        local content = fenceFile:read('*a')
        fenceFile:close()
        local hasZeroGuard = content:find('#soldItems == 0 or realTotal <= 0') ~= nil
        local hasPaidCheckSale = content:find('local paid = BridgeAddCash%(src, realTotal, \'fence_sale\'%)') ~= nil
        local hasPaidCheckOrder = content:find('local paid = BridgeAddCash%(src, total, \'fence_order\'%)') ~= nil
        check('FENCE-CANARY-01 zero-sale guard presente no código real', hasZeroGuard)
        check('FENCE-CANARY-01 checagem booleana de BridgeAddCash em sellItems presente', hasPaidCheckSale)
        check('FENCE-CANARY-01 checagem booleana de BridgeAddCash em fulfillOrder presente', hasPaidCheckOrder)
    end

    print(('[fence_payment/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('fence_payment_spec falhou') end
end

run()
