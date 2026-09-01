-- bridge/workshop.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-4.1] WORKSHOP BRIDGE & PERSISTENT SAGA JOURNAL
--
--  Integração modular com sistemas externos de oficina via SAGA distribuída:
--  1) Provider default = 'none' (zero dependência externa de resource).
--  2) Persistent Transaction Journal (tabela vp_chop_workshop_journal).
--  3) At-most-once cross-resource & idempotência estrita por txnId.
--  4) Restart recovery seguro via stablePartIdentity.
--  5) External reservation de PartEntitlement (RESERVED_EXTERNAL).
--  6) Background reconciliation & quarantine fail-closed.
--  7) Handoff seguro de stolen_plate com metadados server-authoritative.
--  8) Registro de provedores externo via export seguro com validação de contrato.
-- ═══════════════════════════════════════════════════════════════════════════════

WorkshopBridge = {}

---@type table<string, table>
local _providers = {}

---@type table<string, string> stablePartId -> txnId
local _activeSagasByStableId = {}

---@type table<string, boolean> stablePartId -> in-memory lock
local _stablePartLock = {}

local _workshopIntegrityLocked = false
local _ready = false
local _db = nil
local _clock = os.time
local _rng = math.random
local _seq = 0
local _bootNonce = ('%x_%x'):format(os.time(), math.random(100000, 999999))
local _reconcileRunning = false
local _racePauseHook = nil

local VALID_ASSET_KINDS = { part_entitlement = true, stolen_plate = true }
local VALID_STATES = {
    PREPARED = true, RESERVED = true, COMMITTING = true,
    COMMITTED = true, FINALIZED = true, RECONCILING = true,
    QUARANTINE = true, ABORTED = true,
}
local VALID_COMMODITIES = {
    door_dside_f = true, door_pside_f = true,
    door_dside_r = true, door_pside_r = true,
    bonnet = true, boot = true,
    adv_engine = true, catalytic_converter = true,
    tyre = true, carcass = true,
}
local VALID_URGENCY = {
    low = true, normal = true, high = true, critical = true,
}

local function dbg(...)
    if Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.Debug then
        print(('[vp_chopshop][WorkshopBridge] %s'):format(table.concat({ ... }, ' ')))
    end
end

local function generateTxnId(providerName)
    _seq = _seq + 1
    local now = _clock and _clock() or os.time()
    return ('ws:%s:%s:%d:%d'):format(
        tostring(providerName or 'none'),
        _bootNonce,
        now,
        _seq
    )
end

local function deepCopy(orig)
    if type(orig) ~= 'table' then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = type(v) == 'table' and deepCopy(v) or v
    end
    return copy
end

local function validatePrice(price)
    if type(price) ~= 'number' then return false end
    if price ~= price or price == math.huge or price == -math.huge then return false end
    if price <= 0 then return false end
    local maxP = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.MaxPrice) or 50000
    if price > maxP then return false end
    return true
end

local function validateExpiry(exp, now)
    if type(exp) ~= 'number' then return false end
    if exp ~= exp or exp == math.huge or exp == -math.huge then return false end
    if exp <= now then return false end
    local maxTtl = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.PrepareMaxTtlSec) or 60
    if exp > (now + maxTtl) then return false end
    return true
end

local function validateJournalRow(row)
    if type(row) ~= 'table' then return false, 'invalid_row' end
    if type(row.txn_id) ~= 'string' or row.txn_id == '' then return false, 'invalid_txn_id' end
    if type(row.provider) ~= 'string' or row.provider == '' then return false, 'invalid_provider' end
    if not VALID_ASSET_KINDS[row.asset_kind] then return false, 'invalid_asset_kind' end
    if type(row.stable_part_id) ~= 'string' or row.stable_part_id == '' then return false, 'invalid_stable_id' end
    if not VALID_STATES[row.state] then return false, 'invalid_state' end
    if type(row.price) ~= 'number' or row.price ~= row.price or row.price <= 0 then return false, 'invalid_price' end
    return true
end

local function validateAndSanitizeSignal(rawSignal)
    if type(rawSignal) ~= 'table' then return nil end
    local clean = {
        activeDemand = {},
        urgency = 'normal',
    }
    if type(rawSignal.activeDemand) == 'table' then
        for k, v in pairs(rawSignal.activeDemand) do
            if VALID_COMMODITIES[k] and type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then
                if v >= 0.1 and v <= 5.0 then
                    clean.activeDemand[k] = v
                end
            end
        end
    else
        return nil
    end

    if type(rawSignal.urgency) == 'string' and VALID_URGENCY[rawSignal.urgency] then
        clean.urgency = rawSignal.urgency
    end

    return clean
end

local function execQuery(query, params)
    if not _db or not _db.query or type(_db.query.await) ~= 'function' then
        return nil, 'no_db'
    end
    local ok, res = pcall(function()
        return _db.query.await(query, params or {})
    end)
    if not ok then return nil, res end
    return res
end

local function execInsert(query, params)
    if not _db or not _db.insert or type(_db.insert.await) ~= 'function' then
        return nil, 'no_db'
    end
    local ok, res = pcall(function()
        return _db.insert.await(query, params or {})
    end)
    if not ok then return nil, res end
    return res
end

-- ─── Provider Call Wrappers ───────────────────────────────────────────────────

local function safeProviderIsAvailable(provider)
    if not provider or type(provider.IsAvailable) ~= 'function' then return false end
    local ok, res = pcall(provider.IsAvailable)
    return ok and (res == true)
end

local function safeProviderPrepare(provider, txnId, context)
    if not provider or type(provider.PreparePurchase) ~= 'function' then
        return false, { ok = false, err = 'prepare_unsupported' }
    end
    local ok, res = pcall(provider.PreparePurchase, txnId, context)
    if not ok or type(res) ~= 'table' then
        return false, { ok = false, err = 'prepare_exception' }
    end
    return true, res
end

local function safeProviderCommit(provider, txnId)
    if not provider or type(provider.CommitPurchase) ~= 'function' then
        return false, { ok = false, err = 'commit_unsupported' }
    end
    local ok, res = pcall(provider.CommitPurchase, txnId)
    if not ok or type(res) ~= 'table' then
        return false, { ok = false, err = 'commit_exception' }
    end
    return true, res
end

local function safeProviderStatus(provider, txnId)
    if not provider or type(provider.GetTransactionStatus) ~= 'function' then
        return 'UNKNOWN'
    end
    local ok, res = pcall(provider.GetTransactionStatus, txnId)
    if ok and type(res) == 'string' then
        return res
    end
    return 'UNKNOWN'
end

local function authoritativeAbort(provider, txnId)
    if not provider or type(provider.AbortPurchase) ~= 'function' then
        return false, 'abort_unsupported'
    end
    local ok, res = pcall(provider.AbortPurchase, txnId)
    if ok and res == true then
        return true, true
    end
    return false, 'abort_unconfirmed'
end

local function safeProviderMarketSignal(provider, query)
    if not provider or type(provider.GetMarketSignal) ~= 'function' then
        return false, 'signal_unsupported'
    end
    local ok, res = pcall(provider.GetMarketSignal, query or {})
    if not ok or type(res) ~= 'table' then
        return false, 'signal_failed'
    end
    return true, res
end

-- ─── Centralized Post-Commit Finalization Helper ──────────────────────────────

local function finalizeCommittedTransaction(providerName, txnId, stablePartId, entitlementId, isStolenPlate)
    -- 1. Assegurar persistência do estado COMMITTED no Journal
    execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTED' WHERE txn_id = ? AND state IN ('COMMITTING', 'RECONCILING', 'QUARANTINE')", { txnId })

    -- 2. Finalizar localmente no PartEntitlement com strict stable identity
    if not isStolenPlate and stablePartId and stablePartId ~= '' then
        local okFin, errFin = PartEntitlement.FinalizeExternal(entitlementId, txnId, stablePartId, 'workshop_' .. tostring(providerName or 'none'))
        if not okFin and errFin ~= 'already_consumed' then
            _workshopIntegrityLocked = true
            print(('[vp_chopshop][WorkshopBridge] CRITICAL: FinalizeExternal failed for paid txn %s (stable %s): %s'):format(
                tostring(txnId), tostring(stablePartId), tostring(errFin)))
            return false, 'local_finalize_failed'
        end
    end

    -- 3. Transicionar journal para FINALIZED com affectedRows == 1
    local qFin = execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ? AND state = 'COMMITTED'", { txnId })
    if not qFin or (qFin.affectedRows or 0) ~= 1 then
        _workshopIntegrityLocked = true
        print(('[vp_chopshop][WorkshopBridge] CRITICAL: finalization journal update failed for txnId %s'):format(tostring(txnId)))
        return false, 'journal_finalize_failed'
    end

    if stablePartId then
        _activeSagasByStableId[stablePartId] = nil
    end
    return true
end

-- ─── Provider Registry ─────────────────────────────────────────────────────────

--- Registra um adaptador de oficina interna.
---@param name string
---@param adapter table
function WorkshopBridge.RegisterProvider(name, adapter)
    if type(name) ~= 'string' or name == '' or type(adapter) ~= 'table' then
        return false, 'invalid_args'
    end
    _providers[name] = adapter
    dbg('Provider registrado internamente:', name)
    return true
end

--- Obtém o adaptador de um provedor registrado.
---@param name string
---@return table|nil
function WorkshopBridge.GetProvider(name)
    return _providers[name]
end

-- Registrar provider padrão 'none'
WorkshopBridge.RegisterProvider('none', {
    ResourceName = 'none',
    IsAvailable = function() return false end,
    PreparePurchase = function(...) return { ok = false, err = 'workshop_unavailable' } end,
    CommitPurchase = function(...) return { ok = false, err = 'workshop_unavailable' } end,
    GetTransactionStatus = function(...) return 'UNKNOWN' end,
    AbortPurchase = function(...) return true end,
    GetMarketSignal = function(...) return nil end,
})

-- ─── Caller Identity Verification ─────────────────────────────────────────────

--- Verifica se a chamada provém do resource configurado para o provider.
---@param providerName string
---@param externalCaller? string
---@return boolean ok, string? err
function WorkshopBridge.VerifyCaller(providerName, externalCaller)
    local invoking = externalCaller or (GetInvokingResource and GetInvokingResource())
    if not invoking or invoking == GetCurrentResourceName() then
        return true
    end

    local cfg = Config and Config.Broker and Config.Broker.Workshop
    local expectedRes = cfg and cfg.ProviderResource
    if not expectedRes then
        local prov = _providers[providerName]
        expectedRes = prov and prov.ResourceName
    end

    if not expectedRes or invoking ~= expectedRes then
        return false, 'provider_identity_mismatch'
    end

    return true
end

-- ─── Circuit Breaker & Status ─────────────────────────────────────────────────

function WorkshopBridge.IsIntegrityLocked()
    return _workshopIntegrityLocked
end

function WorkshopBridge.SetIntegrityLock(state)
    _workshopIntegrityLocked = (state == true)
end

function WorkshopBridge.IsReady()
    return _ready
end

-- ─── SAGA: PartEntitlement Handoff ────────────────────────────────────────────

--- Executa a SAGA distribuída para entrega de uma peça física para a oficina externa.
---@param src number
---@param entitlementId string
---@param opts? table
---@param externalCaller? string
---@return { ok: boolean, err?: string, paid?: boolean, price?: number, txnId?: string, workshopDegraded?: boolean, terminalReserved?: boolean }
function WorkshopBridge.HandoffPart(src, entitlementId, opts, externalCaller)
    if _workshopIntegrityLocked then
        return { ok = false, err = 'workshop_integrity_locked' }
    end

    local cfg = Config and Config.Broker and Config.Broker.Workshop
    if not cfg or cfg.Enable == false then
        return { ok = false, err = 'workshop_disabled' }
    end

    local providerName = cfg.Provider or 'none'
    local provider = _providers[providerName]
    if not provider or not safeProviderIsAvailable(provider) then
        return { ok = false, err = 'workshop_unavailable' }
    end

    local okCaller, callerErr = WorkshopBridge.VerifyCaller(providerName, externalCaller)
    if not okCaller then
        return { ok = false, err = callerErr or 'provider_identity_mismatch' }
    end

    if not IsValidSource(src) or not ServerPlayerIsReady(src) then
        return { ok = false, err = 'player' }
    end

    local playerKey = ServerChopPlayerKey(src)
    if not playerKey or playerKey == '' then
        return { ok = false, err = 'player_key' }
    end

    -- 1. Validar PartEntitlement
    local okVal, entOrErr = PartEntitlement.Validate(entitlementId, src)
    if not okVal then
        return { ok = false, err = entOrErr }
    end

    local stableId = entOrErr.stablePartIdentity
    if not stableId or stableId == '' then
        return { ok = false, err = 'invalid_stable_identity' }
    end

    if _activeSagasByStableId[stableId] or _stablePartLock[stableId] then
        return { ok = false, err = 'external_reserved' }
    end

    _stablePartLock[stableId] = true
    local function unlockStable()
        _stablePartLock[stableId] = nil
    end

    -- Hook para simulação controlada de race interleaved em testes
    if _racePauseHook and type(_racePauseHook) == 'function' then
        _racePauseHook(stableId)
    end

    -- 2. Snapshot server-authoritative
    local snapshot = {
        entitlementId      = entitlementId,
        stablePartIdentity = stableId,
        ownerKey           = entOrErr.ownerKey,
        ownerSrc           = src,
        partKey            = entOrErr.partKey,
        sessionId          = entOrErr.sessionId,
        sourceNetId        = entOrErr.sourceNetId,
        origin             = entOrErr.origin,
        provenance         = entOrErr.provenance and deepCopy(entOrErr.provenance) or nil,
        createdAt          = entOrErr.createdAt,
    }

    local trust = 0
    if _G.VPChopFenceGetTrust then
        trust = _G.VPChopFenceGetTrust(src) or 0
    end
    local tier = 1
    if _G.VPChopGetProgression then
        local pData = _G.VPChopGetProgression(src)
        tier = (pData and pData.tier) or 1
    end

    local txnId = generateTxnId(providerName)
    local context = {
        txnId              = txnId,
        playerKey          = playerKey,
        source             = src,
        assetKind          = 'part_entitlement',
        partKey            = entOrErr.partKey,
        commodity          = entOrErr.partKey,
        stablePartIdentity = stableId,
        provenance         = snapshot.provenance,
        metadata           = snapshot,
        trustLevel         = trust,
        progressionTier    = tier,
    }

    -- 3. Provider PreparePurchase
    local okPrep, resPrep = safeProviderPrepare(provider, txnId, context)
    if not okPrep or not resPrep or resPrep.ok ~= true then
        unlockStable()
        return { ok = false, err = (resPrep and resPrep.err) or 'prepare_failed' }
    end

    local now = _clock and _clock() or os.time()
    if not validatePrice(resPrep.price) or not validateExpiry(resPrep.expiresAt, now) then
        authoritativeAbort(provider, txnId)
        unlockStable()
        return { ok = false, err = 'invalid_price' }
    end

    local agreedPrice = math.floor(resPrep.price)

    -- 4. Persistir Journal em PREPARED
    local okEnc, metaJson = pcall(json.encode, snapshot)
    if not okEnc or not metaJson then
        authoritativeAbort(provider, txnId)
        unlockStable()
        return { ok = false, err = 'metadata_serialization_failed' }
    end

    local insertRes = execInsert([[
        INSERT INTO vp_chop_workshop_journal (
            txn_id, provider, player_key, asset_kind, entitlement_id,
            stable_part_id, part_key, price, state, metadata
        ) VALUES (?, ?, ?, 'part_entitlement', ?, ?, ?, ?, 'PREPARED', ?)
    ]], {
        txnId, providerName, playerKey, entitlementId,
        stableId, entOrErr.partKey, agreedPrice, metaJson
    })

    if not insertRes then
        authoritativeAbort(provider, txnId)
        unlockStable()
        return { ok = false, err = 'journal_write_failed' }
    end

    -- 5. Reservar PartEntitlement na memória
    local resReserve = PartEntitlement.ReserveForExternal(entitlementId, src, txnId)
    if not resReserve.ok then
        authoritativeAbort(provider, txnId)
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
        unlockStable()
        return { ok = false, err = resReserve.err or 'reserve_failed' }
    end

    _activeSagasByStableId[stableId] = txnId

    -- 6. Transição de Journal: PREPARED -> RESERVED com verificação estrita
    local resUpdRes = execQuery("UPDATE vp_chop_workshop_journal SET state = 'RESERVED' WHERE txn_id = ? AND state = 'PREPARED'", { txnId })
    if not resUpdRes or (resUpdRes.affectedRows or 0) ~= 1 then
        local okAbort, isAborted = authoritativeAbort(provider, txnId)
        if okAbort and isAborted then
            PartEntitlement.ReleaseExternalReservation(entitlementId, txnId, stableId)
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
            _activeSagasByStableId[stableId] = nil
        else
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { txnId })
        end
        unlockStable()
        return { ok = false, err = 'journal_update_failed' }
    end

    -- 7. Transição de Journal: RESERVED -> COMMITTING com verificação estrita
    local resUpdComm = execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTING' WHERE txn_id = ? AND state = 'RESERVED'", { txnId })
    if not resUpdComm or (resUpdComm.affectedRows or 0) ~= 1 then
        local okAbort, isAborted = authoritativeAbort(provider, txnId)
        if okAbort and isAborted then
            PartEntitlement.ReleaseExternalReservation(entitlementId, txnId, stableId)
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
            _activeSagasByStableId[stableId] = nil
        else
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { txnId })
        end
        unlockStable()
        return { ok = false, err = 'journal_update_failed' }
    end

    -- 8. SOMENTE APÓS COMMITTING PERSISTIDO NO DB: Chamar CommitPurchase
    local okCommit, resCommit = safeProviderCommit(provider, txnId)
    if okCommit and resCommit and resCommit.ok == true and resCommit.paid == true then
        local okFin = finalizeCommittedTransaction(providerName, txnId, stableId, entitlementId, false)
        unlockStable()
        if not okFin then
            return {
                ok               = true,
                paid             = true,
                price            = agreedPrice,
                txnId            = txnId,
                workshopDegraded = true,
                terminalReserved = true,
            }
        end
        return {
            ok    = true,
            paid  = true,
            price = agreedPrice,
            txnId = txnId,
        }
    end

    -- Se CommitPurchase falhar/for incerto, verificar estado com GetTransactionStatus
    local status = safeProviderStatus(provider, txnId)
    if status == 'COMMITTED' then
        local okFin = finalizeCommittedTransaction(providerName, txnId, stableId, entitlementId, false)
        unlockStable()
        if not okFin then
            return {
                ok               = true,
                paid             = true,
                price            = agreedPrice,
                txnId            = txnId,
                workshopDegraded = true,
                terminalReserved = true,
            }
        end
        return {
            ok    = true,
            paid  = true,
            price = agreedPrice,
            txnId = txnId,
        }
    elseif status == 'ABORTED' then
        local okAbort, isAborted = authoritativeAbort(provider, txnId)
        if okAbort and isAborted then
            PartEntitlement.ReleaseExternalReservation(entitlementId, txnId, stableId)
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
            _activeSagasByStableId[stableId] = nil
            unlockStable()
            return { ok = false, err = 'provider_aborted' }
        else
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { txnId })
            unlockStable()
            return { ok = false, err = 'abort_unconfirmed_quarantined' }
        end
    elseif status == 'PREPARED' then
        -- Retry com o MESMO txnId
        local okRetry, resRetry = safeProviderCommit(provider, txnId)
        if okRetry and resRetry and resRetry.ok == true and resRetry.paid == true then
            local okFin = finalizeCommittedTransaction(providerName, txnId, stableId, entitlementId, false)
            unlockStable()
            if not okFin then
                return {
                    ok               = true,
                    paid             = true,
                    price            = agreedPrice,
                    txnId            = txnId,
                    workshopDegraded = true,
                    terminalReserved = true,
                }
            end
            return {
                ok    = true,
                paid  = true,
                price = agreedPrice,
                txnId = txnId,
            }
        else
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { txnId })
            unlockStable()
            return { ok = false, err = 'commit_reconciling' }
        end
    else
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { txnId })
        unlockStable()
        return { ok = false, err = 'commit_reconciling' }
    end
end

-- ─── SAGA: stolen_plate Handoff ───────────────────────────────────────────────

--- Executa a SAGA distribuída para entrega de uma stolen_plate para a oficina externa.
---@param src number
---@param slot number
---@param opts? table
---@param externalCaller? string
---@return { ok: boolean, err?: string, paid?: boolean, price?: number, txnId?: string, workshopDegraded?: boolean }
function WorkshopBridge.HandoffStolenPlate(src, slot, opts, externalCaller)
    if _workshopIntegrityLocked then
        return { ok = false, err = 'workshop_integrity_locked' }
    end

    local cfg = Config and Config.Broker and Config.Broker.Workshop
    if not cfg or cfg.Enable == false then
        return { ok = false, err = 'workshop_disabled' }
    end

    local providerName = cfg.Provider or 'none'
    local provider = _providers[providerName]
    if not provider or not safeProviderIsAvailable(provider) then
        return { ok = false, err = 'workshop_unavailable' }
    end

    local okCaller, callerErr = WorkshopBridge.VerifyCaller(providerName, externalCaller)
    if not okCaller then
        return { ok = false, err = callerErr or 'provider_identity_mismatch' }
    end

    if not IsValidSource(src) or not ServerPlayerIsReady(src) then
        return { ok = false, err = 'player' }
    end

    local playerKey = ServerChopPlayerKey(src)
    if not playerKey or playerKey == '' then
        return { ok = false, err = 'player_key' }
    end

    -- Obter item do slot de forma server-authoritative
    local item = nil
    if _G.BridgeGetSlot then
        item = _G.BridgeGetSlot(src, slot)
    elseif _G.exports and _G.exports.ox_inventory and type(_G.exports.ox_inventory.GetSlot) == 'function' then
        local okSlot, sRes = pcall(_G.exports.ox_inventory.GetSlot, _G.exports.ox_inventory, src, slot)
        if okSlot and sRes and type(sRes) == 'table' and sRes.name then item = sRes end
    end

    if not item or item.name ~= 'stolen_plate' or (item.count or 0) < 1 then
        return { ok = false, err = 'invalid_item' }
    end

    local itemMeta = item.metadata and deepCopy(item.metadata) or {}
    local plate = itemMeta.plate or 'unknown'

    local txnId = generateTxnId(providerName)
    local stableId = ('spi:plate:%s:%s'):format(plate, txnId)

    local trust = 0
    if _G.VPChopFenceGetTrust then trust = _G.VPChopFenceGetTrust(src) or 0 end
    local tier = 1
    if _G.VPChopGetProgression then
        local pData = _G.VPChopGetProgression(src)
        tier = (pData and pData.tier) or 1
    end

    local context = {
        txnId              = txnId,
        playerKey          = playerKey,
        source             = src,
        assetKind          = 'stolen_plate',
        partKey            = 'stolen_plate',
        commodity          = 'stolen_plate',
        stablePartIdentity = stableId,
        provenance         = itemMeta,
        metadata           = itemMeta,
        trustLevel         = trust,
        progressionTier    = tier,
    }

    local okPrep, resPrep = safeProviderPrepare(provider, txnId, context)
    if not okPrep or not resPrep or resPrep.ok ~= true then
        return { ok = false, err = (resPrep and resPrep.err) or 'prepare_failed' }
    end

    local now = _clock and _clock() or os.time()
    if not validatePrice(resPrep.price) or not validateExpiry(resPrep.expiresAt, now) then
        authoritativeAbort(provider, txnId)
        return { ok = false, err = 'invalid_price' }
    end

    local agreedPrice = math.floor(resPrep.price)
    local okEnc, metaJson = pcall(json.encode, itemMeta)
    if not okEnc or not metaJson then
        authoritativeAbort(provider, txnId)
        return { ok = false, err = 'metadata_serialization_failed' }
    end

    local insertRes = execInsert([[
        INSERT INTO vp_chop_workshop_journal (
            txn_id, provider, player_key, asset_kind, entitlement_id,
            stable_part_id, part_key, price, state, metadata
        ) VALUES (?, ?, ?, 'stolen_plate', NULL, ?, 'stolen_plate', ?, 'PREPARED', ?)
    ]], {
        txnId, providerName, playerKey,
        stableId, agreedPrice, metaJson
    })

    if not insertRes then
        authoritativeAbort(provider, txnId)
        return { ok = false, err = 'journal_write_failed' }
    end

    -- Remover o item específico do inventário
    local removed = false
    if _G.BridgeRemoveItem then
        removed = _G.BridgeRemoveItem(src, 'stolen_plate', 1, item.metadata, slot)
    elseif _G.exports and _G.exports.ox_inventory and type(_G.exports.ox_inventory.RemoveItem) == 'function' then
        local okRem, rRes = pcall(_G.exports.ox_inventory.RemoveItem, _G.exports.ox_inventory, src, 'stolen_plate', 1, item.metadata, slot)
        if okRem and (rRes == true or rRes == 1) then removed = true end
    end

    if not removed then
        authoritativeAbort(provider, txnId)
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
        return { ok = false, err = 'item_remove_failed' }
    end

    -- Transição PREPARED -> RESERVED com verificação estrita
    local resUpdRes = execQuery("UPDATE vp_chop_workshop_journal SET state = 'RESERVED' WHERE txn_id = ? AND state = 'PREPARED'", { txnId })
    if not resUpdRes or (resUpdRes.affectedRows or 0) ~= 1 then
        local okAbort, isAborted = authoritativeAbort(provider, txnId)
        if okAbort and isAborted then
            -- Item já removido mas abort comprovado: manter em QUARANTINE para admin sem fingir ABORTED limpo
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { txnId })
        else
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { txnId })
        end
        return { ok = false, err = 'journal_update_failed' }
    end

    -- Transição RESERVED -> COMMITTING com verificação estrita
    local resUpdComm = execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTING' WHERE txn_id = ? AND state = 'RESERVED'", { txnId })
    if not resUpdComm or (resUpdComm.affectedRows or 0) ~= 1 then
        local okAbort, isAborted = authoritativeAbort(provider, txnId)
        if okAbort and isAborted then
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { txnId })
        else
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { txnId })
        end
        return { ok = false, err = 'journal_update_failed' }
    end

    -- SOMENTE APÓS COMMITTING PERSISTIDO NO DB: Chamar CommitPurchase
    local okCommit, resCommit = safeProviderCommit(provider, txnId)
    if okCommit and resCommit and resCommit.ok == true and resCommit.paid == true then
        local okFin = finalizeCommittedTransaction(providerName, txnId, stableId, nil, true)
        if not okFin then
            return {
                ok               = true,
                paid             = true,
                price            = agreedPrice,
                txnId            = txnId,
                workshopDegraded = true,
            }
        end
        return {
            ok    = true,
            paid  = true,
            price = agreedPrice,
            txnId = txnId,
        }
    end

    -- Status check & reconcile
    local status = safeProviderStatus(provider, txnId)
    if status == 'COMMITTED' then
        local okFin = finalizeCommittedTransaction(providerName, txnId, stableId, nil, true)
        if not okFin then
            return {
                ok               = true,
                paid             = true,
                price            = agreedPrice,
                txnId            = txnId,
                workshopDegraded = true,
            }
        end
        return {
            ok    = true,
            paid  = true,
            price = agreedPrice,
            txnId = txnId,
        }
    elseif status == 'ABORTED' then
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { txnId })
        return { ok = false, err = 'provider_aborted_quarantined' }
    else
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { txnId })
        return { ok = false, err = 'commit_reconciling' }
    end
end

-- ─── Market Signal ────────────────────────────────────────────────────────────

--- Obtém o sinal de demanda da oficina ativa.
---@param query? table
---@return { ok: boolean, err?: string, signal?: table }
function WorkshopBridge.GetMarketSignal(query)
    local cfg = Config and Config.Broker and Config.Broker.Workshop
    if not cfg or cfg.Enable == false then
        return { ok = false, err = 'workshop_disabled' }
    end

    local providerName = cfg.Provider or 'none'
    local provider = _providers[providerName]
    if not provider or not safeProviderIsAvailable(provider) then
        return { ok = false, err = 'workshop_unavailable' }
    end

    local ok, res = safeProviderMarketSignal(provider, query or {})
    if not ok or type(res) ~= 'table' then
        return { ok = false, err = 'signal_failed' }
    end

    local cleanSignal = validateAndSanitizeSignal(res)
    if not cleanSignal then
        return { ok = false, err = 'signal_invalid' }
    end

    return {
        ok     = true,
        signal = cleanSignal,
    }
end

-- ─── Boot Recovery & Reconciliation ───────────────────────────────────────────

--- Executa a reconciliação e restauração de transações pendentes após o boot.
function WorkshopBridge.BootstrapRecovery()
    if not _db or not _db.query or type(_db.query.await) ~= 'function' then
        return false, 'no_db'
    end

    local rows = execQuery([[
        SELECT txn_id, provider, player_key, asset_kind, entitlement_id,
               stable_part_id, part_key, price, state, reconcile_count, metadata
        FROM vp_chop_workshop_journal
        WHERE state IN ('PREPARED', 'RESERVED', 'COMMITTING', 'COMMITTED', 'RECONCILING', 'QUARANTINE')
    ]])

    if not rows or type(rows) ~= 'table' then return true end

    dbg('Bootstrap recovery processando', #rows, 'transações pendentes')

    for _, row in ipairs(rows) do
        local okVal, valErr = validateJournalRow(row)
        if not okVal then
            print(('[vp_chopshop][WorkshopBridge] CRITICAL: Corrupted/legacy journal row %s (%s) -> QUARANTINE'):format(
                tostring(row.txn_id), tostring(valErr)))
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { row.txn_id })
            goto continue_recovery_row
        end

        local isStolenPlate = (row.asset_kind == 'stolen_plate')
        local prov = _providers[row.provider]
        local meta = nil
        if row.metadata and row.metadata ~= '' then
            pcall(function() meta = json.decode(row.metadata) end)
        end

        local currentEntId = row.entitlement_id
        if not isStolenPlate then
            if not meta or type(meta) ~= 'table' or meta.stablePartIdentity ~= row.stable_part_id or (meta.partKey and meta.partKey ~= row.part_key) then
                print(('[vp_chopshop][WorkshopBridge] CRITICAL: Invalid/mismatched metadata for part txn %s (stable %s) -> QUARANTINE'):format(
                    tostring(row.txn_id), tostring(row.stable_part_id)))
                execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { row.txn_id })
                goto continue_recovery_row
            end

            -- Restaurar snapshot como RESERVED_EXTERNAL para proteger o ativo contra reutilização
            if row.state == 'RESERVED' or row.state == 'COMMITTING' or row.state == 'COMMITTED' or row.state == 'RECONCILING' then
                local restoredId = PartEntitlement.RestoreExternalSnapshot(meta, row.txn_id)
                if restoredId and restoredId ~= currentEntId then
                    currentEntId = restoredId
                    execQuery("UPDATE vp_chop_workshop_journal SET entitlement_id = ? WHERE txn_id = ?", { restoredId, row.txn_id })
                end
                if row.stable_part_id and row.stable_part_id ~= '' then
                    _activeSagasByStableId[row.stable_part_id] = row.txn_id
                end
            end
        end

        if not prov or not safeProviderIsAvailable(prov) then
            -- Manter em RECONCILING/QUARANTINE se o provider histórico não estiver disponível
            if row.state ~= 'QUARANTINE' and row.state ~= 'RECONCILING' then
                execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { row.txn_id })
            end
        else
            if row.state == 'COMMITTED' then
                finalizeCommittedTransaction(row.provider, row.txn_id, row.stable_part_id, currentEntId, isStolenPlate)
            elseif row.state == 'COMMITTING' or row.state == 'RECONCILING' or row.state == 'RESERVED' or row.state == 'PREPARED' then
                local status = safeProviderStatus(prov, row.txn_id)
                if status == 'COMMITTED' then
                    finalizeCommittedTransaction(row.provider, row.txn_id, row.stable_part_id, currentEntId, isStolenPlate)
                elseif status == 'ABORTED' then
                    if isStolenPlate then
                        execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { row.txn_id })
                    else
                        local okAbort, isAborted = authoritativeAbort(prov, row.txn_id)
                        if okAbort and isAborted then
                            PartEntitlement.ReleaseExternalReservation(currentEntId, row.txn_id, row.stable_part_id)
                            execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { row.txn_id })
                            if row.stable_part_id then _activeSagasByStableId[row.stable_part_id] = nil end
                        else
                            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { row.txn_id })
                        end
                    end
                elseif status == 'PREPARED' and row.state == 'COMMITTING' then
                    -- Retry commit com o MESMO txnId
                    local okRetry, resRetry = safeProviderCommit(prov, row.txn_id)
                    if okRetry and resRetry and resRetry.ok == true and resRetry.paid == true then
                        finalizeCommittedTransaction(row.provider, row.txn_id, row.stable_part_id, currentEntId, isStolenPlate)
                    else
                        execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { row.txn_id })
                    end
                else
                    execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { row.txn_id })
                end
            end
        end
        ::continue_recovery_row::
    end

    return true
end

--- Sweeper de reconciliação periódica de transações pendentes (RECONCILING e QUARANTINE).
function WorkshopBridge.ReconcilePending()
    if _reconcileRunning then return end
    _reconcileRunning = true

    local function sweepBody()
        local maxAttempts = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.MaxReconcileAttempts) or 4

        local rows = execQuery([[
            SELECT txn_id, provider, player_key, asset_kind, entitlement_id,
                   stable_part_id, part_key, price, state, reconcile_count, metadata
            FROM vp_chop_workshop_journal
            WHERE state IN ('RECONCILING', 'QUARANTINE')
        ]])

        if rows and type(rows) == 'table' then
            for _, row in ipairs(rows) do
                local okVal = validateJournalRow(row)
                if not okVal then
                    execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { row.txn_id })
                    goto next_reconcile_row
                end

                local isStolenPlate = (row.asset_kind == 'stolen_plate')
                local nextCount = (row.reconcile_count or 0) + 1
                local prov = _providers[row.provider]
                local meta = nil
                if row.metadata and row.metadata ~= '' then
                    pcall(function() meta = json.decode(row.metadata) end)
                end

                local currentEntId = row.entitlement_id
                if not isStolenPlate and meta and type(meta) == 'table' and meta.stablePartIdentity == row.stable_part_id then
                    if not PartEntitlement.GetByStableId(row.stable_part_id) then
                        local restoredId = PartEntitlement.RestoreExternalSnapshot(meta, row.txn_id)
                        if restoredId and restoredId ~= currentEntId then
                            currentEntId = restoredId
                            execQuery("UPDATE vp_chop_workshop_journal SET entitlement_id = ? WHERE txn_id = ?", { restoredId, row.txn_id })
                        end
                    end
                end

                if not prov or not safeProviderIsAvailable(prov) then
                    if row.state == 'RECONCILING' then
                        if nextCount > maxAttempts then
                            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE', reconcile_count = ? WHERE txn_id = ?", { nextCount, row.txn_id })
                            print(('[vp_chopshop][WorkshopBridge] CRITICAL: txnId %s transicionada para QUARANTINE após %d tentativas'):format(
                                tostring(row.txn_id), nextCount))
                        else
                            execQuery("UPDATE vp_chop_workshop_journal SET reconcile_count = ? WHERE txn_id = ?", { nextCount, row.txn_id })
                        end
                    end
                else
                    local status = safeProviderStatus(prov, row.txn_id)
                    if status == 'COMMITTED' then
                        finalizeCommittedTransaction(row.provider, row.txn_id, row.stable_part_id, currentEntId, isStolenPlate)
                    elseif status == 'ABORTED' then
                        if isStolenPlate then
                            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE', reconcile_count = ? WHERE txn_id = ?", { nextCount, row.txn_id })
                        else
                            local okAbort, isAborted = authoritativeAbort(prov, row.txn_id)
                            if okAbort and isAborted then
                                PartEntitlement.ReleaseExternalReservation(currentEntId, row.txn_id, row.stable_part_id)
                                execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED', reconcile_count = ? WHERE txn_id = ?", { nextCount, row.txn_id })
                                if row.stable_part_id then _activeSagasByStableId[row.stable_part_id] = nil end
                            else
                                execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE', reconcile_count = ? WHERE txn_id = ?", { nextCount, row.txn_id })
                            end
                        end
                    else
                        if row.state == 'RECONCILING' then
                            if nextCount > maxAttempts then
                                execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE', reconcile_count = ? WHERE txn_id = ?", { nextCount, row.txn_id })
                                print(('[vp_chopshop][WorkshopBridge] CRITICAL: txnId %s transicionada para QUARANTINE após %d tentativas com status UNKNOWN'):format(
                                    tostring(row.txn_id), nextCount))
                            else
                                execQuery("UPDATE vp_chop_workshop_journal SET reconcile_count = ? WHERE txn_id = ?", { nextCount, row.txn_id })
                            end
                        end
                    end
                end
                ::next_reconcile_row::
            end
        end
    end

    local ok, err = pcall(sweepBody)
    if not ok then
        print(('[vp_chopshop][WorkshopBridge] ERROR in ReconcilePending: %s'):format(tostring(err)))
    end
    _reconcileRunning = false
end

-- ─── Inicialização ─────────────────────────────────────────────────────────────

function WorkshopBridge.Init(db, clockFn, rngFn)
    if clockFn then _clock = clockFn end
    if rngFn then _rng = rngFn end
    if db then
        _db = db
    elseif _db == nil then
        _db = _G.MySQL
    end

    _ready = (_db ~= nil and _db ~= false and type(_db) == 'table' and
              type(_db.query) == 'table' and type(_db.query.await) == 'function' and
              type(_db.insert) == 'table' and type(_db.insert.await) == 'function')
    dbg('WorkshopBridge inicializado, ready =', _ready)

    if _ready then
        WorkshopBridge.BootstrapRecovery()
    end
end

if AddEventHandler or _G.AddEventHandler then
    local regEvt = AddEventHandler or _G.AddEventHandler
    regEvt('vp_chopshop:server:dbReady', function()
        WorkshopBridge.Init()
    end)
end

if _G.VPChopDBReady == true then
    WorkshopBridge.Init()
end

-- Thread periódica de reconciliação
CreateThread(function()
    while true do
        local intervalSec = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.ReconcileIntervalSec) or 15
        Wait(intervalSec * 1000)
        if _ready and not _workshopIntegrityLocked then
            pcall(WorkshopBridge.ReconcilePending)
        end
    end
end)

-- ─── Exports Públicos ──────────────────────────────────────────────────────────

exports('WorkshopRegisterProvider', function(providerName, adapter)
    local caller = GetInvokingResource and GetInvokingResource()
    if not caller or caller == '' or caller == GetCurrentResourceName() then
        return false, 'forbidden_caller'
    end
    if type(providerName) ~= 'string' or providerName == '' or type(adapter) ~= 'table' then
        return false, 'invalid_args'
    end
    if adapter.ResourceName ~= caller then
        return false, 'resource_mismatch'
    end
    if type(adapter.IsAvailable) ~= 'function' or
       type(adapter.PreparePurchase) ~= 'function' or
       type(adapter.CommitPurchase) ~= 'function' or
       type(adapter.GetTransactionStatus) ~= 'function' or
       type(adapter.AbortPurchase) ~= 'function' then
        return false, 'invalid_contract'
    end
    local existing = _providers[providerName]
    if existing and existing.ResourceName and existing.ResourceName ~= caller then
        return false, 'provider_hijack_forbidden'
    end
    _providers[providerName] = adapter
    dbg('Provider registrado via export externo:', providerName, 'resource:', caller)
    return true
end)

exports('WorkshopHandoffPart', function(source, entitlementId, opts)
    local caller = GetInvokingResource and GetInvokingResource()
    if not caller or caller == '' or caller == GetCurrentResourceName() then
        return { ok = false, err = 'forbidden_caller' }
    end
    return WorkshopBridge.HandoffPart(source, entitlementId, opts, caller)
end)

exports('WorkshopHandoffStolenPlate', function(source, slot, opts)
    local caller = GetInvokingResource and GetInvokingResource()
    if not caller or caller == '' or caller == GetCurrentResourceName() then
        return { ok = false, err = 'forbidden_caller' }
    end
    return WorkshopBridge.HandoffStolenPlate(source, slot, opts, caller)
end)

exports('WorkshopGetMarketSignal', function(query)
    return WorkshopBridge.GetMarketSignal(query)
end)

-- ─── Seam de Teste ─────────────────────────────────────────────────────────────
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    WorkshopBridge._test = {
        reset = function()
            _activeSagasByStableId = {}
            _stablePartLock = {}
            _workshopIntegrityLocked = false
            _seq = 0
            _reconcileRunning = false
            _racePauseHook = nil
        end,
        setBootNonce = function(n) _bootNonce = n end,
        setClock = function(fn) _clock = fn end,
        setRng = function(fn) _rng = fn end,
        setDb = function(db)
            _db = db
            _ready = (db ~= nil and db ~= false and type(db) == 'table' and
                      type(db.query) == 'table' and type(db.query.await) == 'function' and
                      type(db.insert) == 'table' and type(db.insert.await) == 'function')
        end,
        getActiveSagas = function() return _activeSagasByStableId end,
        getProviders = function() return _providers end,
        setRacePauseHook = function(fn) _racePauseHook = fn end,
        authoritativeAbort = authoritativeAbort,
        finalizeCommittedTransaction = finalizeCommittedTransaction,
        validateAndSanitizeSignal = validateAndSanitizeSignal,
        validateJournalRow = validateJournalRow,
    }
end

dbg('módulo WorkshopBridge carregado')