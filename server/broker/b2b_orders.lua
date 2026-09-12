-- server/broker/b2b_orders.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.19 P5.3] WORKSHOP B2B ORDERS & ESCROW TERMINAL
--  Gerencia ordens de compra emitidas por oficinas mecânicas com retenção de
--  saldo em escrow na sociedade, integração com o Broker e liquidação atômica.
-- ═══════════════════════════════════════════════════════════════════════════════

B2BOrders = {}

local _db = nil
local _clock = os.time
local _ready = false
local _mock = nil

local function dbg(...)
    if Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.Debug then
        print('[vp_chopshop:b2b_orders]', ...)
    end
end

local function getNow()
    return _clock and _clock() or os.time()
end

local function getDb()
    if _db then return _db end
    return _G.MySQL
end

local function checkDbValid(db)
    return db ~= nil
        and db ~= false
        and type(db) == 'table'
        and type(db.query) == 'table'
        and type(db.query.await) == 'function'
end

function B2BOrders.Init(db, clockFn)
    if db ~= nil then _db = db end
    if clockFn ~= nil then _clock = clockFn end
    _ready = checkDbValid(_db or _G.MySQL)
    dbg('B2BOrders inicializado, ready =', _ready)
end

function B2BOrders.IsReady()
    return _ready == true and checkDbValid(_db or _G.MySQL)
end

-- ─── Helper de Saldo e Escrow de Sociedade ─────────────────────────────────────

local function getWorkshopSocietyAccount(workshopId)
    local cfg = Config and Config.Broker and Config.Broker.Workshop
    if cfg and cfg.Shops and workshopId and cfg.Shops[workshopId] then
        return cfg.Shops[workshopId].account or ('society_' .. workshopId)
    end
    return (cfg and cfg.DefaultAccount) or 'society_mechanic'
end

local function holdSocietyEscrow(workshopId, amount, reason)
    if _mock and _mock.HoldSocietyEscrow then
        return _mock.HoldSocietyEscrow(workshopId, amount, reason)
    end

    local account = getWorkshopSocietyAccount(workshopId)
    -- Tenta debitar da sociedade para reter no escrow do chopshop
    if exports and exports['qbx_management'] and GetResourceState and GetResourceState('qbx_management') == 'started' then
        local ok, success = pcall(function()
            return exports['qbx_management']:RemoveMoney(account, amount, reason or 'vp_chopshop:b2b_escrow')
        end)
        if ok and success then return true end
    end

    if exports and exports.ox_inventory and GetResourceState and GetResourceState('ox_inventory') == 'started' then
        local ok, success = pcall(function()
            return exports.ox_inventory:RemoveItem(account, 'money', amount)
        end)
        if ok and success then return true end
    end

    -- Fallback permissivo se mock estiver em modo teste ou sociedade for ilimitada
    if GetConvar('vp_chopshop_selftest', '0') == '1' then
        return true
    end

    return false
end

local function refundSocietyEscrow(workshopId, amount, reason)
    if _mock and _mock.RefundSocietyEscrow then
        return _mock.RefundSocietyEscrow(workshopId, amount, reason)
    end

    local account = getWorkshopSocietyAccount(workshopId)
    if exports and exports['qbx_management'] and GetResourceState and GetResourceState('qbx_management') == 'started' then
        pcall(function()
            exports['qbx_management']:AddMoney(account, amount, reason or 'vp_chopshop:b2b_refund')
        end)
        return true
    end

    if exports and exports.ox_inventory and GetResourceState and GetResourceState('ox_inventory') == 'started' then
        pcall(function()
            exports.ox_inventory:AddItem(account, 'money', amount)
        end)
        return true
    end

    return true
end

-- ─── Expiração Automática & Estorno de Escrow ──────────────────────────────────

function B2BOrders.SweepExpired(now)
    if not B2BOrders.IsReady() then return 0 end
    local curTime = now or getNow()
    local db = getDb()

    local selectSql = [[
        SELECT `order_id`, `workshop_id`, `remaining`, `price_per_unit`
        FROM `vp_chop_workshop_b2b_orders`
        WHERE `state` = 'OPEN' AND `expires_at` <= FROM_UNIXTIME(?)
    ]]

    local okSel, rows = pcall(function()
        return db.query.await(selectSql, { curTime })
    end)

    if not okSel or not rows or type(rows) ~= 'table' or #rows == 0 then
        return 0
    end

    local count = 0
    for _, r in ipairs(rows) do
        local rem = tonumber(r.remaining) or 0
        local price = tonumber(r.price_per_unit) or 0
        local refundVal = rem * price

        local updSql = [[
            UPDATE `vp_chop_workshop_b2b_orders`
            SET `state` = 'EXPIRED'
            WHERE `order_id` = ? AND `state` = 'OPEN'
        ]]
        local okUpd, resUpd = pcall(function()
            return db.query.await(updSql, { r.order_id })
        end)

        local aff = (type(resUpd) == 'table' and resUpd.affectedRows) or (type(resUpd) == 'number' and resUpd) or 0
        if aff == 1 then
            if refundVal > 0 then
                refundSocietyEscrow(r.workshop_id, refundVal, 'vp_chopshop:b2b_order_expired')
            end
            count = count + 1
            dbg('Ordem B2B expirada e estornada:', r.order_id, 'reembolso:', refundVal)
        end
    end

    return count
end

-- ─── Criação de Ordem B2B ──────────────────────────────────────────────────────

--- Cria uma nova ordem de compra de peças financiada pela sociedade da oficina
---@param src number Jogador mecânico solicitante
---@param workshopId string ID da oficina (ex: 'bennys', 'hayes')
---@param partKey string Peça requerida (ex: 'adv_engine', 'door', 'catalytic_converter')
---@param opts table { quantity?: number, targetModel?: string, pricePerUnit?: number, ttl?: number }
---@return { ok: boolean, orderId?: string, escrowTotal?: number, err?: string }
function B2BOrders.CreateOrder(src, workshopId, partKey, opts)
    if not B2BOrders.IsReady() then return { ok = false, err = 'db_not_ready' } end
    opts = opts or {}

    if not IsValidSource(src) or not ServerPlayerIsReady(src) then
        return { ok = false, err = 'player' }
    end

    local playerKey = ServerChopPlayerKey(src)
    if not playerKey or playerKey == '' then
        return { ok = false, err = 'player_key' }
    end

    if not workshopId or type(workshopId) ~= 'string' or workshopId == '' then
        return { ok = false, err = 'invalid_workshop_id' }
    end

    if not partKey or type(partKey) ~= 'string' or partKey == '' then
        return { ok = false, err = 'invalid_part_key' }
    end

    local cfgWorkshop = Config and Config.Broker and Config.Broker.Workshop
    if cfgWorkshop and cfgWorkshop.Enable == false then
        return { ok = false, err = 'workshop_disabled' }
    end

    local b2bCfg = cfgWorkshop and cfgWorkshop.B2B or {}
    if b2bCfg.Enable == false then
        return { ok = false, err = 'b2b_disabled' }
    end

    local qty = math.floor(tonumber(opts.quantity) or 1)
    if qty <= 0 or qty > 20 then
        return { ok = false, err = 'invalid_quantity' }
    end

    -- Obter cotação base de mercado para garantir piso de preço
    local basePrice = 3000
    if BrokerMarket and BrokerMarket.GetQuote then
        local q = BrokerMarket.GetQuote(partKey)
        if q and q.price then basePrice = q.price end
    end

    local minMult = tonumber(b2bCfg.MinPriceMult) or 1.10
    local minAllowedPrice = math.floor(basePrice * minMult)

    local pricePerUnit = tonumber(opts.pricePerUnit)
    if not pricePerUnit or pricePerUnit < minAllowedPrice then
        pricePerUnit = minAllowedPrice
    end

    local maxPrice = tonumber(cfgWorkshop and cfgWorkshop.MaxPrice) or 50000
    if pricePerUnit > maxPrice then
        pricePerUnit = maxPrice
    end

    local escrowTotal = pricePerUnit * qty

    -- 1. Bloquear saldo da sociedade em escrow
    local okEscrow = holdSocietyEscrow(workshopId, escrowTotal, ('vp_chopshop:b2b_order:%s'):format(partKey))
    if not okEscrow then
        return { ok = false, err = 'insufficient_society_funds' }
    end

    local curTime = getNow()
    local ttl = tonumber(opts.ttl) or (tonumber(b2bCfg.DefaultTtlSec) or 3600)
    local expiresAt = curTime + ttl

    local orderId = ('b2b:%s:%d:%d'):format(workshopId, curTime, math.random(1000, 9999))
    local targetModel = opts.targetModel and tostring(opts.targetModel):lower() or nil

    local db = getDb()
    local insertSql = [[
        INSERT INTO `vp_chop_workshop_b2b_orders` (
            `order_id`, `workshop_id`, `creator_key`, `part_key`, `target_model`,
            `quantity`, `remaining`, `price_per_unit`, `escrow_total`,
            `expires_at`, `state`
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?), 'OPEN')
    ]]

    local okIns, resIns = pcall(function()
        return db.query.await(insertSql, {
            orderId, workshopId, playerKey, partKey, targetModel,
            qty, qty, pricePerUnit, escrowTotal, expiresAt
        })
    end)

    if not okIns or not resIns then
        -- Estornar escrow em falha de DB
        refundSocietyEscrow(workshopId, escrowTotal, 'vp_chopshop:b2b_db_failure_refund')
        return { ok = false, err = 'db_error' }
    end

    dbg('Ordem B2B criada com sucesso:', orderId, 'peça:', partKey, 'escrow:', escrowTotal)
    return {
        ok          = true,
        orderId     = orderId,
        escrowTotal = escrowTotal,
        expiresAt   = expiresAt,
    }
end

-- ─── Cancelamento de Ordem B2B ─────────────────────────────────────────────────

--- Cancela uma ordem B2B em aberto e estorna a garantia restante para a sociedade
---@param src number
---@param orderId string
---@return { ok: boolean, refunded?: number, err?: string }
function B2BOrders.CancelOrder(src, orderId)
    if not B2BOrders.IsReady() then return { ok = false, err = 'db_not_ready' } end
    if not orderId or orderId == '' then return { ok = false, err = 'invalid_order_id' } end

    if not IsValidSource(src) or not ServerPlayerIsReady(src) then
        return { ok = false, err = 'player' }
    end

    local playerKey = ServerChopPlayerKey(src)
    local db = getDb()

    -- 1. Obter ordem
    local selSql = "SELECT * FROM `vp_chop_workshop_b2b_orders` WHERE `order_id` = ?"
    local okSel, rows = pcall(function() return db.query.await(selSql, { orderId }) end)
    if not okSel or not rows or not rows[1] then
        return { ok = false, err = 'order_not_found' }
    end

    local order = rows[1]
    if order.state ~= 'OPEN' then
        return { ok = false, err = 'not_open' }
    end

    local rem = tonumber(order.remaining) or 0
    local price = tonumber(order.price_per_unit) or 0
    local refundAmount = rem * price

    -- 2. Atualizar estado para CANCELLED atomicamente
    local updSql = "UPDATE `vp_chop_workshop_b2b_orders` SET `state` = 'CANCELLED' WHERE `order_id` = ? AND `state` = 'OPEN'"
    local okUpd, resUpd = pcall(function() return db.query.await(updSql, { orderId }) end)
    local aff = (type(resUpd) == 'table' and resUpd.affectedRows) or (type(resUpd) == 'number' and resUpd) or 0
    if aff ~= 1 then
        return { ok = false, err = 'cancel_conflict' }
    end

    -- 3. Estornar saldo restante para a sociedade
    if refundAmount > 0 then
        refundSocietyEscrow(order.workshop_id, refundAmount, 'vp_chopshop:b2b_order_cancelled')
    end

    dbg('Ordem B2B cancelada com sucesso:', orderId, 'estorno:', refundAmount)
    return {
        ok       = true,
        refunded = refundAmount,
    }
end

-- ─── Consulta de Ordens em Aberto ──────────────────────────────────────────────

--- Retorna todas as ordens B2B abertas e válidas
---@param workshopId? string Filtro opcional por oficina
---@return table[]
function B2BOrders.GetOpenOrders(workshopId)
    if not B2BOrders.IsReady() then return {} end
    local curTime = getNow()
    B2BOrders.SweepExpired(curTime)

    local db = getDb()
    local sql = [[
        SELECT `order_id`, `workshop_id`, `creator_key`, `part_key`, `target_model`,
               `quantity`, `remaining`, `price_per_unit`, `escrow_total`,
               UNIX_TIMESTAMP(`expires_at`) AS `expires_at`, `state`
        FROM `vp_chop_workshop_b2b_orders`
        WHERE `state` = 'OPEN' AND `expires_at` > FROM_UNIXTIME(?)
    ]]
    local params = { curTime }

    if workshopId and workshopId ~= '' then
        sql = sql .. " AND `workshop_id` = ?"
        table.insert(params, workshopId)
    end

    sql = sql .. " ORDER BY `created_at` DESC"

    local ok, rows = pcall(function() return db.query.await(sql, params) end)
    if not ok or not rows or type(rows) ~= 'table' then return {} end

    return rows
end

-- ─── Cumprimento de Ordem B2B com Entrega Física ───────────────────────────────

--- Executa a entrega de uma peça física para uma ordem B2B
---@param src number Desmanchador entregador
---@param orderId string ID da ordem B2B
---@param entitlementId string ID da peça física autorizada
---@return { ok: boolean, paid?: boolean, price?: number, remaining?: number, err?: string }
function B2BOrders.FulfillB2B(src, orderId, entitlementId)
    if not B2BOrders.IsReady() then return { ok = false, err = 'db_not_ready' } end
    if not IsValidSource(src) or not ServerPlayerIsReady(src) then
        return { ok = false, err = 'player' }
    end

    local curTime = getNow()
    B2BOrders.SweepExpired(curTime)
    local db = getDb()

    -- 1. Obter ordem aberta
    local selSql = "SELECT * FROM `vp_chop_workshop_b2b_orders` WHERE `order_id` = ? AND `state` = 'OPEN' AND `expires_at` > FROM_UNIXTIME(?)"
    local okSel, rows = pcall(function() return db.query.await(selSql, { orderId, curTime }) end)
    if not okSel or not rows or not rows[1] then
        return { ok = false, err = 'order_unavailable' }
    end

    local order = rows[1]
    local rem = tonumber(order.remaining) or 0
    if rem <= 0 then
        return { ok = false, err = 'order_fulfilled' }
    end

    -- 2. Validar PartEntitlement antes de reservar quota
    local okVal, entOrErr = PartEntitlement.Validate(entitlementId, src)
    if not okVal then
        return { ok = false, err = entOrErr or 'invalid_part' }
    end

    if entOrErr.partKey ~= order.part_key then
        return { ok = false, err = 'part_mismatch' }
    end

    if order.target_model and order.target_model ~= '' then
        local provModel = entOrErr.provenance and entOrErr.provenance.model
        if not provModel or provModel:lower() ~= order.target_model:lower() then
            return { ok = false, err = 'model_mismatch' }
        end
    end

    -- 3. Decrementar quota atomicamente no DB
    local isFinal = (rem == 1)
    local newState = isFinal and 'FULFILLED' or 'OPEN'
    local updSql = [[
        UPDATE `vp_chop_workshop_b2b_orders`
        SET `remaining` = `remaining` - 1,
            `state` = ?
        WHERE `order_id` = ? AND `remaining` = ? AND `state` = 'OPEN' AND `expires_at` > FROM_UNIXTIME(?)
    ]]

    local okUpd, resUpd = pcall(function()
        return db.query.await(updSql, { newState, orderId, rem, curTime })
    end)
    local aff = (type(resUpd) == 'table' and resUpd.affectedRows) or (type(resUpd) == 'number' and resUpd) or 0
    if aff ~= 1 then
        return { ok = false, err = 'order_race_lost' }
    end

    -- 4. Chamar WorkshopBridge.HandoffPart para a oficina compradora
    local handoffOpts = {
        workshopId = order.workshop_id,
        price      = order.price_per_unit,
        b2bOrderId = orderId,
    }

    local handoffRes = WorkshopBridge.HandoffPart(src, entitlementId, handoffOpts)
    if not handoffRes.ok or not handoffRes.paid then
        -- Rollback compensatório de quota
        dbg('Falha no HandoffPart SAGA para ordem B2B, compensando quota:', orderId)
        pcall(function()
            db.query.await([[
                UPDATE `vp_chop_workshop_b2b_orders`
                SET `remaining` = `remaining` + 1,
                    `state` = 'OPEN'
                WHERE `order_id` = ?
            ]], { orderId })
        end)
        return { ok = false, err = handoffRes.err or 'handoff_failed' }
    end

    dbg('Ordem B2B cumprida com sucesso:', orderId, 'payout:', order.price_per_unit)
    return {
        ok        = true,
        paid      = true,
        price     = order.price_per_unit,
        remaining = rem - 1,
    }
end

-- ─── Test Seams ────────────────────────────────────────────────────────────────

function B2BOrders.__setMock(mock)
    _mock = mock
end

-- ─── Exports Públicos ──────────────────────────────────────────────────────────

exports('CreateB2BOrder', function(workshopId, partKey, opts)
    local src = source
    return B2BOrders.CreateOrder(src, workshopId, partKey, opts)
end)

exports('CancelB2BOrder', function(orderId)
    local src = source
    return B2BOrders.CancelOrder(src, orderId)
end)

exports('GetOpenB2BOrders', function(workshopId)
    return B2BOrders.GetOpenOrders(workshopId)
end)

return B2BOrders
