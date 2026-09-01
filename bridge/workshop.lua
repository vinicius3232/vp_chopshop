-- bridge/workshop.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-4] WORKSHOP BRIDGE & PERSISTENT SAGA JOURNAL
--
--  Integração modular com sistemas externos de oficina via SAGA distribuída:
--  1) Provider default = 'none' (zero dependência externa de resource).
--  2) Persistent Transaction Journal (tabela vp_chop_workshop_journal).
--  3) At-most-once cross-resource & idempotência por txnId.
--  4) Restart recovery seguro via stablePartIdentity.
--  5) External reservation de PartEntitlement (RESERVED_EXTERNAL).
--  6) Background reconciliation & quarantine.
--  7) Handoff seguro de stolen_plate com metadados server-authoritative.
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

-- ─── Provider Registry ─────────────────────────────────────────────────────────

--- Registra um adaptador de oficina externa.
---@param name string
---@param adapter table
function WorkshopBridge.RegisterProvider(name, adapter)
    if type(name) ~= 'string' or name == '' or type(adapter) ~= 'table' then
        return false, 'invalid_args'
    end
    _providers[name] = adapter
    dbg('Provider registrado:', name)
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
---@return boolean ok, string? err
function WorkshopBridge.VerifyCaller(providerName)
    local invoking = GetInvokingResource and GetInvokingResource()
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
---@return { ok: boolean, err?: string, paid?: boolean, price?: number, txnId?: string, workshopDegraded?: boolean, terminalReserved?: boolean }
function WorkshopBridge.HandoffPart(src, entitlementId, opts)
    if _workshopIntegrityLocked then
        return { ok = false, err = 'workshop_integrity_locked' }
    end

    local cfg = Config and Config.Broker and Config.Broker.Workshop
    if not cfg or cfg.Enable == false then
        return { ok = false, err = 'workshop_disabled' }
    end

    local providerName = cfg.Provider or 'none'
    local provider = _providers[providerName]
    if not provider or not provider.IsAvailable or not provider.IsAvailable() then
        return { ok = false, err = 'workshop_unavailable' }
    end

    local okCaller, callerErr = WorkshopBridge.VerifyCaller(providerName)
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
    local okPrep, resPrep = pcall(provider.PreparePurchase, txnId, context)
    if not okPrep or not resPrep or resPrep.ok ~= true then
        unlockStable()
        return { ok = false, err = (resPrep and resPrep.err) or 'prepare_failed' }
    end

    local now = _clock and _clock() or os.time()
    if not validatePrice(resPrep.price) or not validateExpiry(resPrep.expiresAt, now) then
        pcall(provider.AbortPurchase, txnId)
        unlockStable()
        return { ok = false, err = 'invalid_price' }
    end

    local agreedPrice = math.floor(resPrep.price)

    -- 4. Persistir Journal em PREPARED
    local okEnc, metaJson = pcall(json.encode, snapshot)
    if not okEnc or not metaJson then
        pcall(provider.AbortPurchase, txnId)
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
        pcall(provider.AbortPurchase, txnId)
        unlockStable()
        return { ok = false, err = 'journal_write_failed' }
    end

    -- 5. Reservar PartEntitlement na memória
    local resReserve = PartEntitlement.ReserveForExternal(entitlementId, src, txnId)
    if not resReserve.ok then
        pcall(provider.AbortPurchase, txnId)
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
        unlockStable()
        return { ok = false, err = resReserve.err or 'reserve_failed' }
    end

    _activeSagasByStableId[stableId] = txnId

    -- 6. Transição de Journal: PREPARED -> RESERVED
    local resUpdRes = execQuery("UPDATE vp_chop_workshop_journal SET state = 'RESERVED' WHERE txn_id = ? AND state = 'PREPARED'", { txnId })
    if not resUpdRes or (resUpdRes.affectedRows or 0) ~= 1 then
        PartEntitlement.ReleaseExternalReservation(entitlementId, txnId)
        pcall(provider.AbortPurchase, txnId)
        _activeSagasByStableId[stableId] = nil
        unlockStable()
        return { ok = false, err = 'journal_update_failed' }
    end

    -- 7. Transição de Journal: RESERVED -> COMMITTING
    local resUpdComm = execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTING' WHERE txn_id = ? AND state = 'RESERVED'", { txnId })
    if not resUpdComm or (resUpdComm.affectedRows or 0) ~= 1 then
        local okAbort, resAbort = pcall(provider.AbortPurchase, txnId)
        if okAbort and resAbort == true then
            PartEntitlement.ReleaseExternalReservation(entitlementId, txnId)
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
            _activeSagasByStableId[stableId] = nil
        else
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'QUARANTINE' WHERE txn_id = ?", { txnId })
        end
        unlockStable()
        return { ok = false, err = 'journal_update_failed' }
    end

    -- 8. SOMENTE APÓS COMMITTING PERSISTIDO NO DB: Chamar CommitPurchase
    local okCommit, resCommit = pcall(provider.CommitPurchase, txnId)
    if okCommit and resCommit and resCommit.ok == true and resCommit.paid == true then
        local qComm = execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTED' WHERE txn_id = ? AND state = 'COMMITTING'", { txnId })
        if not qComm or (qComm.affectedRows or 0) ~= 1 then
            _workshopIntegrityLocked = true
            print(('[vp_chopshop][WorkshopBridge] CRITICAL: post-pay journal update failed for txnId %s'):format(txnId))
            unlockStable()
            return {
                ok               = true,
                paid             = true,
                price            = agreedPrice,
                txnId            = txnId,
                workshopDegraded = true,
                terminalReserved = true,
            }
        end

        PartEntitlement.FinalizeExternal(entitlementId, txnId, 'workshop_' .. providerName)
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ? AND state = 'COMMITTED'", { txnId })
        _activeSagasByStableId[stableId] = nil
        unlockStable()
        return {
            ok    = true,
            paid  = true,
            price = agreedPrice,
            txnId = txnId,
        }
    end

    -- Se CommitPurchase falhar, verificar estado com GetTransactionStatus
    local okStat, status = pcall(provider.GetTransactionStatus, txnId)
    if okStat and status == 'COMMITTED' then
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTED' WHERE txn_id = ?", { txnId })
        PartEntitlement.FinalizeExternal(entitlementId, txnId, 'workshop_' .. providerName)
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ?", { txnId })
        _activeSagasByStableId[stableId] = nil
        unlockStable()
        return {
            ok    = true,
            paid  = true,
            price = agreedPrice,
            txnId = txnId,
        }
    elseif okStat and status == 'ABORTED' then
        PartEntitlement.ReleaseExternalReservation(entitlementId, txnId)
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
        _activeSagasByStableId[stableId] = nil
        unlockStable()
        return { ok = false, err = 'provider_aborted' }
    elseif okStat and status == 'PREPARED' then
        -- Retry com o MESMO txnId
        local okRetry, resRetry = pcall(provider.CommitPurchase, txnId)
        if okRetry and resRetry and resRetry.ok == true and resRetry.paid == true then
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTED' WHERE txn_id = ?", { txnId })
            PartEntitlement.FinalizeExternal(entitlementId, txnId, 'workshop_' .. providerName)
            execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ?", { txnId })
            _activeSagasByStableId[stableId] = nil
            unlockStable()
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
---@return { ok: boolean, err?: string, paid?: boolean, price?: number, txnId?: string, workshopDegraded?: boolean }
function WorkshopBridge.HandoffStolenPlate(src, slot, opts)
    if _workshopIntegrityLocked then
        return { ok = false, err = 'workshop_integrity_locked' }
    end

    local cfg = Config and Config.Broker and Config.Broker.Workshop
    if not cfg or cfg.Enable == false then
        return { ok = false, err = 'workshop_disabled' }
    end

    local providerName = cfg.Provider or 'none'
    local provider = _providers[providerName]
    if not provider or not provider.IsAvailable or not provider.IsAvailable() then
        return { ok = false, err = 'workshop_unavailable' }
    end

    local okCaller, callerErr = WorkshopBridge.VerifyCaller(providerName)
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

    local okPrep, resPrep = pcall(provider.PreparePurchase, txnId, context)
    if not okPrep or not resPrep or resPrep.ok ~= true then
        return { ok = false, err = (resPrep and resPrep.err) or 'prepare_failed' }
    end

    local now = _clock and _clock() or os.time()
    if not validatePrice(resPrep.price) or not validateExpiry(resPrep.expiresAt, now) then
        pcall(provider.AbortPurchase, txnId)
        return { ok = false, err = 'invalid_price' }
    end

    local agreedPrice = math.floor(resPrep.price)
    local okEnc, metaJson = pcall(json.encode, itemMeta)
    if not okEnc or not metaJson then
        pcall(provider.AbortPurchase, txnId)
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
        pcall(provider.AbortPurchase, txnId)
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
        pcall(provider.AbortPurchase, txnId)
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { txnId })
        return { ok = false, err = 'item_remove_failed' }
    end

    execQuery("UPDATE vp_chop_workshop_journal SET state = 'RESERVED' WHERE txn_id = ? AND state = 'PREPARED'", { txnId })
    execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTING' WHERE txn_id = ? AND state = 'RESERVED'", { txnId })

    local okCommit, resCommit = pcall(provider.CommitPurchase, txnId)
    if okCommit and resCommit and resCommit.ok == true and resCommit.paid == true then
        local qComm = execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTED' WHERE txn_id = ? AND state = 'COMMITTING'", { txnId })
        if not qComm or (qComm.affectedRows or 0) ~= 1 then
            _workshopIntegrityLocked = true
            print(('[vp_chopshop][WorkshopBridge] CRITICAL: post-pay journal update failed for stolen_plate txnId %s'):format(txnId))
            return {
                ok               = true,
                paid             = true,
                price            = agreedPrice,
                txnId            = txnId,
                workshopDegraded = true,
            }
        end
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ? AND state = 'COMMITTED'", { txnId })
        return {
            ok    = true,
            paid  = true,
            price = agreedPrice,
            txnId = txnId,
        }
    end

    -- Status check & reconcile
    local okStat, status = pcall(provider.GetTransactionStatus, txnId)
    if okStat and status == 'COMMITTED' then
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'COMMITTED' WHERE txn_id = ?", { txnId })
        execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ?", { txnId })
        return {
            ok    = true,
            paid  = true,
            price = agreedPrice,
            txnId = txnId,
        }
    elseif okStat and status == 'ABORTED' then
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
    if not provider or not provider.IsAvailable or not provider.IsAvailable() then
        return { ok = false, err = 'workshop_unavailable' }
    end

    if type(provider.GetMarketSignal) ~= 'function' then
        return { ok = false, err = 'signal_unsupported' }
    end

    local ok, res = pcall(provider.GetMarketSignal, query or {})
    if not ok or type(res) ~= 'table' then
        return { ok = false, err = 'signal_failed' }
    end

    return {
        ok     = true,
        signal = deepCopy(res),
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
        local prov = _providers[row.provider]
        local meta = nil
        if row.metadata and row.metadata ~= '' then
            pcall(function() meta = json.decode(row.metadata) end)
        end

        local currentEntId = row.entitlement_id
        if row.asset_kind == 'part_entitlement' and meta then
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

        if not prov or not prov.IsAvailable or not prov.IsAvailable() then
            -- Manter em RECONCILING/QUARANTINE se o provider histórico não estiver disponível
            if row.state ~= 'QUARANTINE' and row.state ~= 'RECONCILING' then
                execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { row.txn_id })
            end
        else
            if row.state == 'COMMITTED' then
                if row.asset_kind == 'part_entitlement' then
                    PartEntitlement.FinalizeExternal(currentEntId, row.txn_id, 'workshop_' .. row.provider)
                end
                execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ?", { row.txn_id })
                if row.stable_part_id then _activeSagasByStableId[row.stable_part_id] = nil end
            elseif row.state == 'COMMITTING' or row.state == 'RECONCILING' or row.state == 'RESERVED' or row.state == 'PREPARED' then
                local okStat, status = pcall(prov.GetTransactionStatus, row.txn_id)
                if okStat and status == 'COMMITTED' then
                    if row.asset_kind == 'part_entitlement' then
                        PartEntitlement.FinalizeExternal(currentEntId, row.txn_id, 'workshop_' .. row.provider)
                    end
                    execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ?", { row.txn_id })
                    if row.stable_part_id then _activeSagasByStableId[row.stable_part_id] = nil end
                elseif okStat and status == 'ABORTED' then
                    if row.asset_kind == 'part_entitlement' then
                        PartEntitlement.ReleaseExternalReservation(currentEntId, row.txn_id)
                    end
                    execQuery("UPDATE vp_chop_workshop_journal SET state = 'ABORTED' WHERE txn_id = ?", { row.txn_id })
                    if row.stable_part_id then _activeSagasByStableId[row.stable_part_id] = nil end
                elseif okStat and status == 'PREPARED' and row.state == 'COMMITTING' then
                    -- Retry commit
                    local okRetry, resRetry = pcall(prov.CommitPurchase, row.txn_id)
                    if okRetry and resRetry and resRetry.ok == true and resRetry.paid == true then
                        if row.asset_kind == 'part_entitlement' then
                            PartEntitlement.FinalizeExternal(currentEntId, row.txn_id, 'workshop_' .. row.provider)
                        end
                        execQuery("UPDATE vp_chop_workshop_journal SET state = 'FINALIZED' WHERE txn_id = ?", { row.txn_id })
                        if row.stable_part_id then _activeSagasByStableId[row.stable_part_id] = nil end
                    else
                        execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { row.txn_id })
                    end
                else
                    execQuery("UPDATE vp_chop_workshop_journal SET state = 'RECONCILING' WHERE txn_id = ?", { row.txn_id })
                end
            end
        end
    end

    return true
end

--- Sweeper de reconciliação periódica de transações pendentes.
function WorkshopBridge.ReconcilePending()
    if _reconcileRunning then return end
    _reconcileRunning = true

    local maxAttempts = (Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.MaxReconcileAttempts) or 4

    local rows = execQuery([[
        SELECT txn_id, provider, player_key, asset_kind, entitlement_id,
               stable_part_id, part_key, price, state, reconcile_count
        FROM vp_chop_workshop_journal
        WHERE state = 'RECONCILING'
    ]])

    if rows and type(rows) == 'table' then
        for _, row in ipairs(rows) do
            local nextCount = (row.reconcile_count or 0) + 1
            local prov = _providers[row.provider]
            if not prov or not prov.IsAvailable or not prov.IsAvailable() or nextCount > maxAttempts then
                execQuery('UPDATE vp_chop_workshop_journal SET state = "QUARANTINE", reconcile_count = ? WHERE txn_id = ?', { nextCount, row.txn_id })
                print(('[vp_chopshop][WorkshopBridge] CRITICAL: txnId %s (provider %s, stable %s) transicionada para QUARANTINE após %d tentativas'):format(
                    row.txn_id, row.provider, tostring(row.stable_part_id), nextCount))
            else
                local okStat, status = pcall(prov.GetTransactionStatus, row.txn_id)
                if okStat and status == 'COMMITTED' then
                    if row.asset_kind == 'part_entitlement' then
                        PartEntitlement.FinalizeExternal(row.entitlement_id, row.txn_id, 'workshop_' .. row.provider)
                    end
                    execQuery('UPDATE vp_chop_workshop_journal SET state = "FINALIZED", reconcile_count = ? WHERE txn_id = ?', { nextCount, row.txn_id })
                    if row.stable_part_id then _activeSagasByStableId[row.stable_part_id] = nil end
                elseif okStat and status == 'ABORTED' then
                    if row.asset_kind == 'part_entitlement' then
                        PartEntitlement.ReleaseExternalReservation(row.entitlement_id, row.txn_id)
                    end
                    execQuery('UPDATE vp_chop_workshop_journal SET state = "ABORTED", reconcile_count = ? WHERE txn_id = ?', { nextCount, row.txn_id })
                    if row.stable_part_id then _activeSagasByStableId[row.stable_part_id] = nil end
                else
                    execQuery('UPDATE vp_chop_workshop_journal SET reconcile_count = ? WHERE txn_id = ?', { nextCount, row.txn_id })
                end
            end
        end
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

    _ready = (_db ~= nil and _db ~= false and type(_db) == 'table' and type(_db.query) == 'table' and type(_db.query.await) == 'function')
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

exports('WorkshopHandoffPart', function(source, entitlementId, opts)
    return WorkshopBridge.HandoffPart(source, entitlementId, opts)
end)

exports('WorkshopHandoffStolenPlate', function(source, slot, opts)
    return WorkshopBridge.HandoffStolenPlate(source, slot, opts)
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
        end,
        setBootNonce = function(n) _bootNonce = n end,
        setClock = function(fn) _clock = fn end,
        setRng = function(fn) _rng = fn end,
        setDb = function(db) _db = db; _ready = (db ~= nil) end,
        getActiveSagas = function() return _activeSagasByStableId end,
        getProviders = function() return _providers end,
    }
end

dbg('módulo WorkshopBridge carregado')