-- bridge/workshop_community.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.19 P5.2] MULTI-API WORKSHOP ADAPTERS (QS-MECHANICS / RENZU / CUSTOM)
--  Conectores para ecossistemas mecânicos populares da comunidade FiveM com
--  envelopamento transacional em 2 fases e isolamento de falha.
-- ═══════════════════════════════════════════════════════════════════════════════

local CommunityAdapters = {}
local _mocks = {}
local _qsEscrow = {}
local _qsCommitted = {}
local _qsAborted = {}

local _renzuEscrow = {}
local _renzuCommitted = {}
local _renzuAborted = {}

local function dbg(...)
    if Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.Debug then
        print('[vp_chopshop:workshop_community]', ...)
    end
end

local function getResourceStateSafe(resName)
    if _mocks[resName] and _mocks[resName].GetResourceState then
        return _mocks[resName].GetResourceState(resName)
    end
    if GetResourceState then
        return GetResourceState(resName)
    end
    return 'missing'
end

-- ─── 1. QS-Mechanic Adapter ───────────────────────────────────────────────────

local QSMechanicAdapter = {
    ResourceName = 'qs-mechanics',
}

function QSMechanicAdapter.IsAvailable()
    if _mocks['qs-mechanics'] and _mocks['qs-mechanics'].IsAvailable ~= nil then
        return _mocks['qs-mechanics'].IsAvailable()
    end
    return getResourceStateSafe('qs-mechanics') == 'started'
end

function QSMechanicAdapter.PreparePurchase(txnId, context)
    if not txnId or type(context) ~= 'table' then
        return { ok = false, err = 'invalid_args' }
    end
    if _qsCommitted[txnId] then return { ok = false, err = 'already_committed' } end
    if _qsAborted[txnId] then return { ok = false, err = 'already_aborted' } end

    local price = tonumber(context.price) or 3200
    local maxPrice = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.MaxPrice) or 50000
    if price > maxPrice then price = maxPrice end

    -- Se mock injetado, verificar saldo
    if _mocks['qs-mechanics'] and _mocks['qs-mechanics'].GetBalance then
        local bal = _mocks['qs-mechanics'].GetBalance()
        if bal < price then
            return { ok = false, err = 'insufficient_funds' }
        end
    end

    local ttl = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.PrepareMaxTtlSec) or 60
    local expiresAt = os.time() + ttl

    _qsEscrow[txnId] = {
        price     = price,
        partKey   = context.partKey or context.commodity,
        metadata  = context.metadata,
        expiresAt = expiresAt,
    }

    dbg('QS-Mechanic PREPARED:', txnId, 'preço:', price)
    return {
        ok        = true,
        price     = price,
        expiresAt = expiresAt,
    }
end

function QSMechanicAdapter.CommitPurchase(txnId)
    if _qsCommitted[txnId] then return { ok = true, paid = true } end
    if _qsAborted[txnId] then return { ok = false, err = 'transaction_aborted' } end

    local escrow = _qsEscrow[txnId]
    if not escrow then return { ok = false, err = 'escrow_not_found' } end

    -- Chamar export real ou mock
    if _mocks['qs-mechanics'] and _mocks['qs-mechanics'].Commit then
        local ok = _mocks['qs-mechanics'].Commit(txnId, escrow.price, escrow.partKey)
        if not ok then return { ok = false, err = 'debit_failed' } end
    elseif GetResourceStateSafe('qs-mechanics') == 'started' and exports['qs-mechanics'] then
        pcall(function()
            exports['qs-mechanics']:AddPartToWorkshopStash(escrow.partKey, 1, escrow.metadata)
        end)
    end

    _qsCommitted[txnId] = true
    _qsEscrow[txnId] = nil
    dbg('QS-Mechanic COMMITTED:', txnId)
    return { ok = true, paid = true }
end

function QSMechanicAdapter.AbortPurchase(txnId, reason)
    if _qsCommitted[txnId] then return false end
    _qsEscrow[txnId] = nil
    _qsAborted[txnId] = reason or 'aborted'
    dbg('QS-Mechanic ABORTED:', txnId)
    return true
end

function QSMechanicAdapter.GetTransactionStatus(txnId)
    if _qsCommitted[txnId] then return 'COMMITTED' end
    if _qsAborted[txnId] then return 'ABORTED' end
    if _qsEscrow[txnId] then return 'PREPARED' end
    return 'UNKNOWN'
end

-- ─── 2. Renzu Customs Adapter ─────────────────────────────────────────────────

local RenzuAdapter = {
    ResourceName = 'renzu_customs',
}

function RenzuAdapter.IsAvailable()
    if _mocks['renzu_customs'] and _mocks['renzu_customs'].IsAvailable ~= nil then
        return _mocks['renzu_customs'].IsAvailable()
    end
    return getResourceStateSafe('renzu_customs') == 'started'
end

function RenzuAdapter.PreparePurchase(txnId, context)
    if not txnId or type(context) ~= 'table' then
        return { ok = false, err = 'invalid_args' }
    end
    if _renzuCommitted[txnId] then return { ok = false, err = 'already_committed' } end
    if _renzuAborted[txnId] then return { ok = false, err = 'already_aborted' } end

    local price = tonumber(context.price) or 3400
    local maxPrice = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.MaxPrice) or 50000
    if price > maxPrice then price = maxPrice end

    if _mocks['renzu_customs'] and _mocks['renzu_customs'].GetBalance then
        local bal = _mocks['renzu_customs'].GetBalance()
        if bal < price then
            return { ok = false, err = 'insufficient_funds' }
        end
    end

    local ttl = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.PrepareMaxTtlSec) or 60
    local expiresAt = os.time() + ttl

    _renzuEscrow[txnId] = {
        price     = price,
        partKey   = context.partKey or context.commodity,
        metadata  = context.metadata,
        expiresAt = expiresAt,
    }

    dbg('Renzu Customs PREPARED:', txnId, 'preço:', price)
    return {
        ok        = true,
        price     = price,
        expiresAt = expiresAt,
    }
end

function RenzuAdapter.CommitPurchase(txnId)
    if _renzuCommitted[txnId] then return { ok = true, paid = true } end
    if _renzuAborted[txnId] then return { ok = false, err = 'transaction_aborted' } end

    local escrow = _renzuEscrow[txnId]
    if not escrow then return { ok = false, err = 'escrow_not_found' } end

    if _mocks['renzu_customs'] and _mocks['renzu_customs'].Commit then
        local ok = _mocks['renzu_customs'].Commit(txnId, escrow.price, escrow.partKey)
        if not ok then return { ok = false, err = 'debit_failed' } end
    elseif GetResourceStateSafe('renzu_customs') == 'started' and exports['renzu_customs'] then
        pcall(function()
            exports['renzu_customs']:AddVehiclePart(escrow.partKey, 1, escrow.metadata)
        end)
    end

    _renzuCommitted[txnId] = true
    _renzuEscrow[txnId] = nil
    dbg('Renzu Customs COMMITTED:', txnId)
    return { ok = true, paid = true }
end

function RenzuAdapter.AbortPurchase(txnId, reason)
    if _renzuCommitted[txnId] then return false end
    _renzuEscrow[txnId] = nil
    _renzuAborted[txnId] = reason or 'aborted'
    dbg('Renzu Customs ABORTED:', txnId)
    return true
end

function RenzuAdapter.GetTransactionStatus(txnId)
    if _renzuCommitted[txnId] then return 'COMMITTED' end
    if _renzuAborted[txnId] then return 'ABORTED' end
    if _renzuEscrow[txnId] then return 'PREPARED' end
    return 'UNKNOWN'
end

-- ─── Test Seams & Registration ────────────────────────────────────────────────

function CommunityAdapters.__setMock(resName, mock)
    _mocks[resName] = mock
    if not mock then
        if resName == 'qs-mechanics' then
            _qsEscrow = {}
            _qsCommitted = {}
            _qsAborted = {}
        elseif resName == 'renzu_customs' then
            _renzuEscrow = {}
            _renzuCommitted = {}
            _renzuAborted = {}
        end
    end
end

if WorkshopBridge and WorkshopBridge.RegisterProvider then
    WorkshopBridge.RegisterProvider('qs-mechanics', QSMechanicAdapter)
    WorkshopBridge.RegisterProvider('renzu_customs', RenzuAdapter)
end

CommunityAdapters.QSMechanic = QSMechanicAdapter
CommunityAdapters.Renzu = RenzuAdapter

return CommunityAdapters
