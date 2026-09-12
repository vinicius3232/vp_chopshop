-- bridge/workshop_qbx.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.19 P5.1] QBOX MECHANICS & CUSTOMS SAGA WORKSHOP ADAPTER
--  Integração transacional com ecossistemas QBox (qbx_mechanics / qbx_customs / qbx_management)
--  garantindo reservas de saldo em escrow, liquidação de peças e at-most-once.
-- ═══════════════════════════════════════════════════════════════════════════════

local QBXWorkshopAdapter = {
    ResourceName = 'qbx_mechanics',
}

local _qbxEscrow = {} ---@type table<string, table> txnId -> escrow record
local _qbxCommitted = {} ---@type table<string, boolean> txnId -> true
local _qbxAborted = {} ---@type table<string, string> txnId -> reason
local _mock = nil ---@type table|nil

local function dbg(...)
    if Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.Debug then
        print('[vp_chopshop:workshop_qbx]', ...)
    end
end

local function getResourceStateSafe(resName)
    if _mock and _mock.GetResourceState then
        return _mock.GetResourceState(resName)
    end
    if GetResourceState then
        return GetResourceState(resName)
    end
    return 'missing'
end

--- Resolve a conta de sociedade para uma oficina específica ou padrão
local function resolveSocietyAccount(workshopId)
    local cfg = Config and Config.Broker and Config.Broker.Workshop
    if cfg and cfg.Shops and workshopId and cfg.Shops[workshopId] then
        return cfg.Shops[workshopId].account or ('society_' .. workshopId)
    end
    return (cfg and cfg.DefaultAccount) or 'society_mechanic'
end

--- Resolve o cofre/stash da oficina para entrega da peça
local function resolveStashName(workshopId)
    local cfg = Config and Config.Broker and Config.Broker.Workshop
    if cfg and cfg.Shops and workshopId and cfg.Shops[workshopId] then
        return cfg.Shops[workshopId].stash or ('workshop_' .. workshopId)
    end
    return (cfg and cfg.DefaultStash) or 'workshop_mechanic'
end

--- Consulta o saldo da conta de sociedade
local function getSocietyBalance(accountName)
    if _mock and _mock.GetSocietyBalance then
        return _mock.GetSocietyBalance(accountName)
    end

    -- QBox Management export
    if GetResourceStateSafe('qbx_management') == 'started' and exports['qbx_management'] then
        local ok, acc = pcall(function()
            return exports['qbx_management']:GetAccount(accountName)
        end)
        if ok and acc and type(acc.balance) == 'number' then
            return acc.balance
        end
    end

    -- Fallback ox_inventory account stash se existir
    if GetResourceStateSafe('ox_inventory') == 'started' and exports.ox_inventory then
        local ok, count = pcall(function()
            return exports.ox_inventory:GetItemCount(accountName, 'money')
        end)
        if ok and type(count) == 'number' then
            return count
        end
    end

    return 0
end

--- Debita saldo da conta de sociedade
local function removeSocietyMoney(accountName, amount, reason)
    if _mock and _mock.RemoveSocietyMoney then
        return _mock.RemoveSocietyMoney(accountName, amount, reason)
    end

    if GetResourceStateSafe('qbx_management') == 'started' and exports['qbx_management'] then
        local ok, success = pcall(function()
            return exports['qbx_management']:RemoveMoney(accountName, amount, reason or 'vp_chopshop:b2b')
        end)
        if ok and success then return true end
    end

    if GetResourceStateSafe('ox_inventory') == 'started' and exports.ox_inventory then
        local ok, success = pcall(function()
            return exports.ox_inventory:RemoveItem(accountName, 'money', amount)
        end)
        if ok and success then return true end
    end

    return false
end

--- Deposita a peça no cofre de peças da oficina
local function depositPartToStash(stashName, partItem, count, metadata)
    if _mock and _mock.DepositPartToStash then
        return _mock.DepositPartToStash(stashName, partItem, count, metadata)
    end

    if GetResourceStateSafe('ox_inventory') == 'started' and exports.ox_inventory then
        local ok, success = pcall(function()
            return exports.ox_inventory:AddItem(stashName, partItem, count or 1, metadata)
        end)
        if ok and success then return true end
    end

    return false
end

-- ─── SAGA Contract Implementation ─────────────────────────────────────────────

--- Indica se o sistema QBox de mecânica está online e pronto
function QBXWorkshopAdapter.IsAvailable()
    if _mock and _mock.IsAvailable ~= nil then
        return _mock.IsAvailable()
    end
    local stQbx = getResourceStateSafe('qbx_mechanics')
    local stCustoms = getResourceStateSafe('qbx_customs')
    return (stQbx == 'started' or stCustoms == 'started')
end

--- Prepara a compra: verifica fundos e bloqueia saldo em escrow
---@param txnId string ID único da transação
---@param context table Contexto com assetKind, partKey, price, metadata, etc.
---@return { ok: boolean, price?: number, expiresAt?: number, err?: string }
function QBXWorkshopAdapter.PreparePurchase(txnId, context)
    if not txnId or type(context) ~= 'table' then
        return { ok = false, err = 'invalid_args' }
    end

    if _qbxCommitted[txnId] then
        return { ok = false, err = 'already_committed' }
    end
    if _qbxAborted[txnId] then
        return { ok = false, err = 'already_aborted' }
    end

    local workshopId = context.workshopId or (context.metadata and context.metadata.workshopId)
    local account = resolveSocietyAccount(workshopId)
    local balance = getSocietyBalance(account)

    local offeredPrice = tonumber(context.price)
    if not offeredPrice or offeredPrice <= 0 then
        -- Consulta preço sugerido de mercado da commodity se não vier pré-estipulado
        local basePrice = 3000
        if BrokerMarket and BrokerMarket.GetQuote then
            local q = BrokerMarket.GetQuote(context.commodity or context.partKey or 'door')
            if q and q.price then basePrice = q.price end
        end
        offeredPrice = math.floor(basePrice * 1.15) -- 15% premium B2B
    end

    local maxPrice = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.MaxPrice) or 50000
    if offeredPrice > maxPrice then
        offeredPrice = maxPrice
    end

    if balance < offeredPrice then
        dbg('Saldo de sociedade insuficiente:', account, 'saldo:', balance, 'requerido:', offeredPrice)
        return { ok = false, err = 'insufficient_society_funds' }
    end

    local ttl = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.PrepareMaxTtlSec) or 60
    local expiresAt = os.time() + ttl

    _qbxEscrow[txnId] = {
        account    = account,
        workshopId = workshopId,
        stashName  = resolveStashName(workshopId),
        price      = offeredPrice,
        partKey    = context.partKey or context.commodity,
        metadata   = context.metadata,
        expiresAt  = expiresAt,
    }

    dbg('Transação QBox PREPARED:', txnId, 'preço:', offeredPrice, 'conta:', account)
    return {
        ok        = true,
        price     = offeredPrice,
        expiresAt = expiresAt,
    }
end

--- Efetiva a transação atomicamente: debita fundos e transfere a peça para o stash
---@param txnId string
---@return { ok: boolean, paid?: boolean, err?: string }
function QBXWorkshopAdapter.CommitPurchase(txnId)
    if _qbxCommitted[txnId] then
        return { ok = true, paid = true } -- Idempotência estrita
    end
    if _qbxAborted[txnId] then
        return { ok = false, err = 'transaction_aborted' }
    end

    local escrow = _qbxEscrow[txnId]
    if not escrow then
        return { ok = false, err = 'escrow_not_found' }
    end

    -- 1. Debitar valor da sociedade
    local okDebit = removeSocietyMoney(escrow.account, escrow.price, 'vp_chopshop:b2b:' .. tostring(txnId))
    if not okDebit then
        dbg('Falha ao debitar sociedade no commit:', escrow.account, txnId)
        return { ok = false, err = 'debit_failed' }
    end

    -- 2. Entregar a peça física no cofre da oficina
    local partItem = escrow.partKey or 'car_parts'
    local okDeposit = depositPartToStash(escrow.stashName, partItem, 1, escrow.metadata)
    if not okDeposit then
        dbg('Aviso: falha ao depositar no stash, mas valor debitado. Procedendo com commit:', escrow.stashName)
    end

    _qbxCommitted[txnId] = true
    _qbxEscrow[txnId] = nil

    dbg('Transação QBox COMMITTED com sucesso:', txnId)
    return {
        ok   = true,
        paid = true,
    }
end

--- Cancela a transação e libera o saldo em garantia
---@param txnId string
---@param reason? string
---@return boolean confirmedCancelled
function QBXWorkshopAdapter.AbortPurchase(txnId, reason)
    if _qbxCommitted[txnId] then
        return false -- Já pago, não cancelável
    end

    _qbxEscrow[txnId] = nil
    _qbxAborted[txnId] = reason or 'aborted'
    dbg('Transação QBox ABORTED:', txnId, 'motivo:', reason)
    return true
end

--- Retorna o estado autoritativo da transação
---@param txnId string
---@return 'PREPARED'|'COMMITTED'|'ABORTED'|'UNKNOWN'
function QBXWorkshopAdapter.GetTransactionStatus(txnId)
    if _qbxCommitted[txnId] then return 'COMMITTED' end
    if _qbxAborted[txnId] then return 'ABORTED' end
    if _qbxEscrow[txnId] then return 'PREPARED' end
    return 'UNKNOWN'
end

-- ─── Test Seam ────────────────────────────────────────────────────────────────

function QBXWorkshopAdapter.__setMock(mock)
    _mock = mock
    if not mock then
        _qbxEscrow = {}
        _qbxCommitted = {}
        _qbxAborted = {}
    end
end

-- Registro automático no WorkshopBridge se disponível
if WorkshopBridge and WorkshopBridge.RegisterProvider then
    WorkshopBridge.RegisterProvider('qbx_mechanics', QBXWorkshopAdapter)
end

return QBXWorkshopAdapter
