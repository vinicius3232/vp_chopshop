-- server/broker/b2b_orders_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.19 P5.3] B2B WORKSHOP ORDERS SPEC SUITE
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[b2b/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[b2b/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local B2B = dofile('server/broker/b2b_orders.lua')
    local BC = BrokerContracts
    local PE = PartEntitlement
    local WB = WorkshopBridge

    -- Mock Database em memória para vp_chop_workshop_b2b_orders
    local ordersDb = {}
    local societyEscrows = {}
    local societyRefunds = {}

    local mockDb = {
        insert = {
            await = function(sql, params)
                return 1
            end,
        },
        query = {
            await = function(sql, params)
                params = params or {}
                -- SELECT for SweepExpired
                if sql:find('expires_at` <=') then
                    local rows = {}
                    local threshold = params[1] or 0
                    for _, o in pairs(ordersDb) do
                        if o.state == 'OPEN' and (o.expires_at <= threshold) then
                            table.insert(rows, o)
                        end
                    end
                    return rows
                end

                -- SELECT open orders or by order_id
                if sql:find('SELECT `order_id`') or sql:find('SELECT %* FROM `vp_chop_workshop_b2b_orders`') then
                    local rows = {}
                    local orderIdFilter = nil
                    for _, p in ipairs(params) do
                        if type(p) == 'string' and p:find('^b2b:') then
                            orderIdFilter = p
                        end
                    end

                    if orderIdFilter then
                        if ordersDb[orderIdFilter] then
                            table.insert(rows, ordersDb[orderIdFilter])
                        end
                    else
                        local curTime = params[1] or 0
                        for _, o in pairs(ordersDb) do
                            if o.state == 'OPEN' and (not sql:find('expires_at` >') or o.expires_at > curTime) then
                                table.insert(rows, o)
                            end
                        end
                    end
                    return rows
                end

                -- INSERT INTO
                if sql:find('INSERT INTO `vp_chop_workshop_b2b_orders`') then
                    local orderId = params[1]
                    ordersDb[orderId] = {
                        order_id       = orderId,
                        workshop_id    = params[2],
                        creator_key    = params[3],
                        part_key       = params[4],
                        target_model   = params[5],
                        quantity       = params[6],
                        remaining      = params[7],
                        price_per_unit = params[8],
                        escrow_total   = params[9],
                        expires_at     = params[10],
                        state          = 'OPEN',
                    }
                    return { affectedRows = 1 }
                end

                -- UPDATE state or remaining
                if sql:find('UPDATE `vp_chop_workshop_b2b_orders`') then
                    local orderId = nil
                    for _, p in ipairs(params) do
                        if type(p) == 'string' and p:find('^b2b:') then
                            orderId = p
                        end
                    end
                    if not orderId or not ordersDb[orderId] then
                        return { affectedRows = 0 }
                    end

                    local o = ordersDb[orderId]
                    if sql:find("SET `state` = 'CANCELLED'") then
                        if o.state == 'OPEN' then
                            o.state = 'CANCELLED'
                            return { affectedRows = 1 }
                        end
                        return { affectedRows = 0 }
                    end

                    if sql:find("SET `state` = 'EXPIRED'") then
                        if o.state == 'OPEN' then
                            o.state = 'EXPIRED'
                            return { affectedRows = 1 }
                        end
                        return { affectedRows = 0 }
                    end

                    if sql:find('SET `remaining` = `remaining` %- 1') then
                        local reqRemaining = params[3]
                        if o.state == 'OPEN' and o.remaining == reqRemaining and o.remaining >= 1 then
                            o.remaining = o.remaining - 1
                            o.state = params[1] -- 'FULFILLED' or 'OPEN'
                            return { affectedRows = 1 }
                        end
                        return { affectedRows = 0 }
                    end

                    if sql:find('SET `remaining` = `remaining` %+ 1') then
                        o.remaining = o.remaining + 1
                        o.state = 'OPEN'
                        return { affectedRows = 1 }
                    end

                    return { affectedRows = 1 }
                end

                return {}
            end
        }
    }

    local fakeClock = 1700000000
    B2B.Init(mockDb, function() return fakeClock end)
    check('B2B-INIT-01 B2BOrders initialized and ready', B2B.IsReady() == true)

    -- Mock de Escrow de Sociedade
    B2B.__setMock({
        HoldSocietyEscrow = function(shop, amt, reason)
            if amt > 100000 then return false end -- Limite teste
            societyEscrows[shop] = (societyEscrows[shop] or 0) + amt
            return true
        end,
        RefundSocietyEscrow = function(shop, amt, reason)
            societyRefunds[shop] = (societyRefunds[shop] or 0) + amt
            return true
        end,
    })

    -- ─── 1. Criação de Ordem B2B ────────────────────────────────────────────────
    local testSrc = 1
    -- Rejeita quantidade inválida
    local resQtyFail = B2B.CreateOrder(testSrc, 'bennys', 'adv_engine', { quantity = 0 })
    check('B2B-CREATE-01 Rejects quantity <= 0', resQtyFail.ok == false and resQtyFail.err == 'invalid_quantity')

    local resQtyFail2 = B2B.CreateOrder(testSrc, 'bennys', 'adv_engine', { quantity = 25 })
    check('B2B-CREATE-02 Rejects quantity > 20', resQtyFail2.ok == false and resQtyFail2.err == 'invalid_quantity')

    -- Criação válida
    local createRes = B2B.CreateOrder(testSrc, 'bennys', 'adv_engine', {
        quantity = 2,
        pricePerUnit = 6000,
        targetModel = 'sultan',
        ttl = 3600,
    })
    check('B2B-CREATE-03 Order created successfully', createRes.ok == true and createRes.orderId ~= nil)
    check('B2B-CREATE-04 Escrow total held in society', createRes.escrowTotal == 12000 and societyEscrows['bennys'] == 12000)

    local orderId1 = createRes.orderId
    check('B2B-DB-01 Order persisted in DB', ordersDb[orderId1] ~= nil and ordersDb[orderId1].state == 'OPEN')

    -- Rejeição por saldo de sociedade insuficiente
    local createFail = B2B.CreateOrder(testSrc, 'bennys', 'adv_engine', {
        quantity = 10,
        pricePerUnit = 25000, -- 250000 > 100000 limite mock
    })
    check('B2B-CREATE-05 Fails when society funds insufficient', createFail.ok == false and createFail.err == 'insufficient_society_funds')

    -- ─── 2. Consulta de Ordens em Aberto ─────────────────────────────────────────
    local openOrders = B2B.GetOpenOrders()
    check('B2B-QUERY-01 GetOpenOrders returns open orders', #openOrders >= 1 and openOrders[1].order_id == orderId1)

    -- ─── 3. Integração com BrokerContracts Catalog ──────────────────────────────
    BC.Init(mockDb, function() return fakeClock end)
    local availableContracts = BC.GetAvailable('license:test_player', 1, fakeClock)
    local b2bFoundInCatalog = false
    for _, c in ipairs(availableContracts) do
        if c.isB2B and c.id == orderId1 then
            b2bFoundInCatalog = true
            break
        end
    end
    check('B2B-CATALOG-01 B2B order merged into BrokerContracts catalog', b2bFoundInCatalog == true)

    -- ─── 4. Fulfill B2B Order (Entrega com SAGA) ────────────────────────────────
    -- Criar PartEntitlement mock no inventário
    local entId = PE.Issue('sess_b2b_1', testSrc, 'adv_engine', 55, {
        provenance = { model = 'sultan', vehicleClass = 0 },
    })
    check('B2B-FULFILL-01 Issued PartEntitlement for test delivery', entId ~= nil)

    -- Mock do WorkshopBridge.HandoffPart
    local oldHandoff = WB.HandoffPart
    WB.HandoffPart = function(src, eId, opts)
        check('B2B-SAGA-01 HandoffPart receives workshopId and price', opts.workshopId == 'bennys' and opts.price == 6000)
        return { ok = true, paid = true }
    end

    -- Fulfill unit 1 of 2
    local fulfillRes1 = B2B.FulfillB2B(testSrc, orderId1, entId)
    check('B2B-FULFILL-02 Unit 1 fulfilled ok', fulfillRes1.ok == true and fulfillRes1.paid == true)
    check('B2B-FULFILL-03 Remaining quota is 1', fulfillRes1.remaining == 1 and ordersDb[orderId1].state == 'OPEN')

    -- Fulfill unit 2 of 2 (transição para FULFILLED)
    local entId2 = PE.Issue('sess_b2b_2', testSrc, 'adv_engine', 56, {
        provenance = { model = 'sultan', vehicleClass = 0 },
    })

    local fulfillRes2 = B2B.FulfillB2B(testSrc, orderId1, entId2)
    check('B2B-FULFILL-04 Unit 2 fulfilled ok', fulfillRes2.ok == true and fulfillRes2.paid == true)
    check('B2B-FULFILL-05 Remaining quota is 0, state FULFILLED', fulfillRes2.remaining == 0 and ordersDb[orderId1].state == 'FULFILLED')

    -- Cannot fulfill already fulfilled order
    local fulfillFail = B2B.FulfillB2B(testSrc, orderId1, entId2)
    check('B2B-FULFILL-06 Cannot fulfill completed order', fulfillFail.ok == false)

    -- ─── 5. Cancelamento de Ordem & Estorno de Escrow ───────────────────────────
    local createCancel = B2B.CreateOrder(testSrc, 'hayes', 'door', {
        quantity = 3,
        pricePerUnit = 4000,
    })
    local orderIdCancel = createCancel.orderId
    check('B2B-CANCEL-01 Hayes order created for cancellation', orderIdCancel ~= nil)

    local cancelRes = B2B.CancelOrder(testSrc, orderIdCancel)
    check('B2B-CANCEL-02 CancelOrder returns ok', cancelRes.ok == true)
    check('B2B-CANCEL-03 Full remaining escrow refunded to society', cancelRes.refunded == 12000 and societyRefunds['hayes'] == 12000)
    check('B2B-CANCEL-04 DB state updated to CANCELLED', ordersDb[orderIdCancel].state == 'CANCELLED')

    -- Cannot cancel already cancelled order
    local cancelFail = B2B.CancelOrder(testSrc, orderIdCancel)
    check('B2B-CANCEL-05 Cannot re-cancel cancelled order', cancelFail.ok == false and cancelFail.err == 'not_open')

    -- Restore seams
    WB.HandoffPart = oldHandoff
    B2B.__setMock(nil)

    print(('─── RESUMO B2B ORDERS: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('b2b_orders_spec failed: %d assertions failed'):format(fail))
end

run()
