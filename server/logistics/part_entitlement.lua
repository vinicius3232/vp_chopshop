-- server/logistics/part_entitlement.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 SEC-1] PART ENTITLEMENT — LEDGER LOGÍSTICO AUTORITATIVO DE PEÇAS FÍSICAS.
--
--  Resolve P0-SEC-01 e P0-SEC-02:
--  Elimina a confiança cega em partKey ou carry visual enviado pelo client.
--  Toda peça física removida (portas, capô, porta-malas, motor, catalisador)
--  possui um entitlement server-authoritative com ciclo de vida:
--    ISSUED → CONSUMED (bancada / fence)
--       └─→ LOST (player drop / cleanup)
--
--  INVARIANTE ECONÔMICO:
--  1) O client NUNCA dita partKey nem recompensa: o servidor deriva partKey do entitlement.
--  2) Consumo AT-MOST-ONCE: chamar 2× o mesmo entitlementId resulta em 0 recompensa na 2ª vez.
--  3) Concorrência: atomic consume sem yields intermediários.
--  4) Replay: ActionSession COMPLETE devolve exatamente o mesmo entitlementId sem novo Issue.
--  5) Ownership: apenas o jogador que removeu a peça pode consumi-la.
-- ═══════════════════════════════════════════════════════════════════════════════

PartEntitlement = {}

---@alias PartEntitlementState 'ISSUED'|'RESERVED_EXTERNAL'|'CONSUMED'|'LOST'

---@type table<string, table>              entitlementId → entitlement
local Entitlements = {}
---@type table<string, string>             (sessionId..':'..partKey) → entitlementId (idempotência)
local BySourcePart = {}
local _seq = 0
local _bootNonce = ('%x_%x'):format(os.time(), math.random(100000, 999999))

---@type table<string, table<number, number>> bucket → src → expiryMs
local RateLimits = {}

local function dbg(...)
    if Config.Debug then
        print(('[vp_chopshop][PartEntitlement] %s'):format(table.concat({ ... }, ' ')))
    end
end

--- Normaliza a chave do jogador para comparação exata livre de falsos-positivos.
--- Remove prefixos como 'qbx:', 'qb:', 'esx:', 'src:' mantendo o ID real.
---@param val string|number|nil
---@return string
local function normalizeKey(val)
    if not val then return '' end
    local s = tostring(val)
    s = s:gsub('^%a+:', '')
    return string.upper(s:gsub('%s+', ''))
end

-- ─── Provenance Canônica ───────────────────────────────────────────────────────

--- Captura de forma canônica, segura e server-authoritative a proveniência do veículo.
---@param veh number Entity handle do veículo server-side
---@return { realPlate: string, model: number }|nil provenance
function PartEntitlement.CaptureVehicleProvenance(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return nil
    end

    local rawPlate = GetVehicleNumberPlateText(veh)
    if not rawPlate or type(rawPlate) ~= 'string' then
        return nil
    end

    local cleanPlate = rawPlate:gsub('%s+', '')
    if cleanPlate == '' then
        return nil
    end

    local canonicalRealPlate = nil
    if _G.VPChopMDT and type(_G.VPChopMDT.GetRealPlate) == 'function' then
        local ok, res = pcall(function()
            return _G.VPChopMDT.GetRealPlate(cleanPlate)
        end)
        if ok and type(res) == 'string' then
            local cleanedRes = res:gsub('%s+', '')
            if cleanedRes ~= '' then
                canonicalRealPlate = cleanedRes
            end
        end
    else
        canonicalRealPlate = cleanPlate
    end

    if not canonicalRealPlate or canonicalRealPlate == '' then
        return nil
    end

    local model = GetEntityModel(veh)
    local numModel = tonumber(model) or 0

    local classNum = nil
    if rawget(_G, 'GetVehicleClass') then
        local ok, vc = pcall(GetVehicleClass, veh)
        if ok and type(vc) == 'number' and vc >= 0 then
            classNum = vc
        end
    end

    if not classNum and rawget(_G, 'GetVehicleClassFromName') and numModel ~= 0 then
        local ok, vc = pcall(GetVehicleClassFromName, numModel)
        if ok and type(vc) == 'number' and vc >= 0 then
            classNum = vc
        end
    end

    local className = nil
    if classNum ~= nil then
        local classMap = Config.Broker and Config.Broker.Contracts and Config.Broker.Contracts.VehicleClasses
        if classMap and classMap[classNum] then
            className = classMap[classNum]
        end
    end

    return {
        realPlate    = canonicalRealPlate,
        model        = numModel,
        vehicleClass = classNum,
        className    = className,
    }
end

-- ─── Emissão ───────────────────────────────────────────────────────────────────

--- Emite (ou devolve o existente) o entitlement de uma peça física removida.
--- IDEMPOTENTE por (sessionId, partKey): replays/retries nunca geram um 2º entitlement.
---@param sessionId string
---@param src number
---@param partKey string
---@param sourceNetId? number
---@param opts? { origin?: string, meta?: table }
---@return string|nil entitlementId, boolean|string isNewOrErr
function PartEntitlement.Issue(sessionId, src, partKey, sourceNetId, opts)
    if type(sessionId) ~= 'string' or type(partKey) ~= 'string' then return nil, 'args' end
    if not src or src <= 0 then return nil, 'invalid_src' end

    local ownerKey = ServerChopPlayerKey(src)
    if not ownerKey or ownerKey == '' then return nil, 'no_owner' end

    -- Idempotência atômica síncrona sem yield
    local key = sessionId .. ':' .. partKey
    local existing = BySourcePart[key]
    if existing and Entitlements[existing] then
        return existing, false
    end

    _seq = _seq + 1
    local now = os.time()
    local stablePartId = ('spi:%s:%d:%d:%d'):format(_bootNonce, now, _seq, math.random(1000, 9999))

    local e = {
        id                 = ('pe:%d'):format(_seq),
        stablePartIdentity = stablePartId,
        ownerKey           = ownerKey,
        ownerSrc           = src,
        partKey            = partKey,
        sessionId          = sessionId,
        sourceNetId        = tonumber(sourceNetId) or 0,
        origin             = (opts and opts.origin) or 'advanced',
        provenance         = (opts and opts.provenance and {
            realPlate    = opts.provenance.realPlate,
            model        = opts.provenance.model,
            vehicleClass = opts.provenance.vehicleClass,
            className    = opts.provenance.className,
        }) or nil,
        state              = 'ISSUED',
        externalTxnId      = nil,
        createdAt          = now,
        updatedAt          = now,
        consumedAt         = nil,
        consumedBy         = nil,
        consumedAction     = nil,
    }
    Entitlements[e.id] = e
    BySourcePart[key]  = e.id
    dbg('Issue', e.id, 'stableId', stablePartId, 'partKey', partKey, 'session', sessionId, 'owner', ownerKey)
    return e.id, true
end

-- ─── Leitura ───────────────────────────────────────────────────────────────────

---@param id string
---@return table|nil
function PartEntitlement.Get(id)
    local e = Entitlements[id]
    if not e then return nil end
    return {
        id                 = e.id,
        stablePartIdentity = e.stablePartIdentity,
        ownerKey           = e.ownerKey,
        ownerSrc           = e.ownerSrc,
        partKey            = e.partKey,
        sessionId          = e.sessionId,
        sourceNetId        = e.sourceNetId,
        origin             = e.origin,
        provenance         = e.provenance and {
            realPlate    = e.provenance.realPlate,
            model        = e.provenance.model,
            vehicleClass = e.provenance.vehicleClass,
            className    = e.provenance.className,
        } or nil,
        state              = e.state,
        externalTxnId      = e.externalTxnId,
        createdAt          = e.createdAt,
        updatedAt          = e.updatedAt,
        consumedAt         = e.consumedAt,
        consumedBy         = e.consumedBy,
        consumedAction     = e.consumedAction,
    }
end

--- Busca o entitlement pela stablePartIdentity única durável.
---@param stableId string
---@return table|nil
function PartEntitlement.GetByStableId(stableId)
    if not stableId or stableId == '' then return nil end
    for id, e in pairs(Entitlements) do
        if e.stablePartIdentity == stableId then
            return PartEntitlement.Get(id)
        end
    end
    return nil
end

--- Retorna o entitlementId mapeado para a combinação sessionId:partKey (lookup replay).
---@param sessionId string
---@param partKey string
---@return string|nil
function PartEntitlement.GetBySourcePart(sessionId, partKey)
    local key = tostring(sessionId or '') .. ':' .. tostring(partKey or '')
    return BySourcePart[key]
end

---@param id string
---@return PartEntitlementState|nil
function PartEntitlement.State(id)
    local e = Entitlements[id]
    return e and e.state or nil
end

-- ─── Validação ─────────────────────────────────────────────────────────────────

--- Valida se o entitlement existe, pertence ao jogador e está com estado ISSUED.
---@param id string
---@param src number
---@param expectedPartKey? string
---@return boolean ok, string|table errOrEntitlement
function PartEntitlement.Validate(id, src, expectedPartKey)
    if type(id) ~= 'string' or id == '' then return false, 'invalid_id' end
    local e = Entitlements[id]
    if not e then return false, 'not_found' end

    if e.state == 'CONSUMED' then return false, 'already_consumed' end
    if e.state == 'RESERVED_EXTERNAL' then return false, 'external_reserved' end
    if e.state ~= 'ISSUED' then return false, 'bad_state' end

    local playerKey = ServerChopPlayerKey(src)
    if normalizeKey(e.ownerKey) ~= normalizeKey(playerKey) then
        return false, 'owner_mismatch'
    end

    if expectedPartKey and e.partKey ~= expectedPartKey then
        return false, 'invalid_type'
    end

    return true, e
end

-- ─── Reserva Externa (Workshop SAGA) ──────────────────────────────────────────

--- Reserva atomicamente a peça para liquidação externa (SAGA Workshop).
---@param id string
---@param src number
---@param externalTxnId string
---@return { ok: boolean, err?: string, entitlement?: table, stablePartIdentity?: string }
function PartEntitlement.ReserveForExternal(id, src, externalTxnId)
    local okVal, valRes = PartEntitlement.Validate(id, src)
    if not okVal then
        return { ok = false, err = valRes }
    end

    local e = valRes
    e.state         = 'RESERVED_EXTERNAL'
    e.externalTxnId = externalTxnId
    e.updatedAt     = os.time()

    dbg('ReserveForExternal', id, 'txn', externalTxnId, 'stableId', e.stablePartIdentity)
    return {
        ok                 = true,
        entitlement        = PartEntitlement.Get(id),
        stablePartIdentity = e.stablePartIdentity,
    }
end

--- Libera uma reserva externa retornando a peça ao estado ISSUED após ABORT comprovado.
--- Exige estritamente externalTxnId e expectedStablePartIdentity.
---@param runtimeId? string
---@param externalTxnId string
---@param expectedStablePartIdentity string
---@return boolean ok, string? err
function PartEntitlement.ReleaseExternalReservation(runtimeId, externalTxnId, expectedStablePartIdentity)
    if type(externalTxnId) ~= 'string' or externalTxnId == '' then
        return false, 'invalid_txn_id'
    end
    if type(expectedStablePartIdentity) ~= 'string' or expectedStablePartIdentity == '' then
        return false, 'invalid_stable_identity'
    end

    local e = nil
    for _, item in pairs(Entitlements) do
        if item.externalTxnId == externalTxnId then
            e = item
            break
        end
    end

    if not e and runtimeId and Entitlements[runtimeId] then
        local cand = Entitlements[runtimeId]
        if cand.externalTxnId == externalTxnId then
            e = cand
        end
    end

    if not e then return false, 'not_found' end

    if e.stablePartIdentity ~= expectedStablePartIdentity then
        print(('[vp_chopshop][PartEntitlement] CRITICAL: ReleaseExternalReservation stable mismatch: expected %s got %s (txn %s)'):format(
            tostring(expectedStablePartIdentity), tostring(e.stablePartIdentity), tostring(externalTxnId)))
        return false, 'stable_identity_mismatch'
    end

    if e.externalTxnId ~= externalTxnId then
        return false, 'txn_mismatch'
    end

    if e.state ~= 'RESERVED_EXTERNAL' then return false, 'not_reserved' end

    e.state         = 'ISSUED'
    e.externalTxnId = nil
    e.updatedAt     = os.time()
    dbg('ReleaseExternalReservation', e.id, 'stableId', e.stablePartIdentity, 'txn', externalTxnId)
    return true
end

--- Finaliza definitivamente o consumo da peça após liquidação externa confirmada.
--- Exige estritamente externalTxnId e expectedStablePartIdentity.
---@param runtimeId? string
---@param externalTxnId string
---@param expectedStablePartIdentity string
---@param actionName? string
---@return boolean ok, string? err
function PartEntitlement.FinalizeExternal(runtimeId, externalTxnId, expectedStablePartIdentity, actionName)
    if type(externalTxnId) ~= 'string' or externalTxnId == '' then
        return false, 'invalid_txn_id'
    end
    if type(expectedStablePartIdentity) ~= 'string' or expectedStablePartIdentity == '' then
        return false, 'invalid_stable_identity'
    end

    local e = nil
    for _, item in pairs(Entitlements) do
        if item.externalTxnId == externalTxnId then
            e = item
            break
        end
    end

    if not e and runtimeId and Entitlements[runtimeId] then
        local cand = Entitlements[runtimeId]
        if cand.externalTxnId == externalTxnId or cand.stablePartIdentity == expectedStablePartIdentity then
            e = cand
        end
    end

    if not e then return false, 'not_found' end

    if e.stablePartIdentity ~= expectedStablePartIdentity then
        print(('[vp_chopshop][PartEntitlement] CRITICAL: FinalizeExternal stable mismatch: expected %s got %s (txn %s)'):format(
            tostring(expectedStablePartIdentity), tostring(e.stablePartIdentity), tostring(externalTxnId)))
        return false, 'stable_identity_mismatch'
    end

    -- Idempotência: se já CONSUMED com a mesma stable identity
    if e.state == 'CONSUMED' then
        return true, 'already_consumed'
    end

    if e.externalTxnId and e.externalTxnId ~= externalTxnId then
        return false, 'txn_mismatch'
    end

    if e.state ~= 'RESERVED_EXTERNAL' then
        return false, 'bad_state'
    end

    e.state          = 'CONSUMED'
    e.consumedAt     = os.time()
    e.consumedAction = actionName or 'workshop'
    e.externalTxnId  = nil
    e.updatedAt      = os.time()
    dbg('FinalizeExternal', e.id, 'stableId', e.stablePartIdentity, 'action', actionName)
    return true
end

--- Restaura um snapshot externo na memória durante o boot recovery.
--- Se o ID em runtime original estiver ocupado por OUTRA stablePartIdentity, não sobrescreve.
---@param snapshot table
---@param externalTxnId string
---@return string|nil restoredId, boolean|string isNewOrErr
function PartEntitlement.RestoreExternalSnapshot(snapshot, externalTxnId)
    if not snapshot or type(snapshot) ~= 'table' then return nil, 'invalid_snapshot' end
    local stableId = snapshot.stablePartIdentity
    if not stableId or stableId == '' then return nil, 'invalid_stable_identity' end

    -- Verificar se já existe em memória pela stable identity
    for id, item in pairs(Entitlements) do
        if item.stablePartIdentity == stableId then
            item.state         = 'RESERVED_EXTERNAL'
            item.externalTxnId = externalTxnId
            item.updatedAt     = os.time()
            return id, false
        end
    end

    local targetId = snapshot.entitlementId or snapshot.id
    -- Se targetId está ocupado por OUTRA peça com stable identity diferente: NÃO sobrescrever!
    if targetId and Entitlements[targetId] and Entitlements[targetId].stablePartIdentity ~= stableId then
        _seq = _seq + 1
        targetId = ('pe:restored_%d'):format(_seq)
    end

    if not targetId or targetId == '' then
        _seq = _seq + 1
        targetId = ('pe:restored_%d'):format(_seq)
    end

    local now = os.time()
    local e = {
        id                 = targetId,
        stablePartIdentity = stableId,
        ownerKey           = snapshot.ownerKey,
        ownerSrc           = snapshot.ownerSrc or 0,
        partKey            = snapshot.partKey,
        sessionId          = snapshot.sessionId or ('restored_' .. targetId),
        sourceNetId        = tonumber(snapshot.sourceNetId) or 0,
        origin             = snapshot.origin or 'advanced',
        provenance         = snapshot.provenance and {
            realPlate    = snapshot.provenance.realPlate,
            model        = snapshot.provenance.model,
            vehicleClass = snapshot.provenance.vehicleClass,
            className    = snapshot.provenance.className,
        } or nil,
        state              = 'RESERVED_EXTERNAL',
        externalTxnId      = externalTxnId,
        createdAt          = snapshot.createdAt or now,
        updatedAt          = now,
        consumedAt         = nil,
        consumedBy         = nil,
        consumedAction     = nil,
    }

    Entitlements[targetId] = e
    local key = e.sessionId .. ':' .. e.partKey
    -- Snapshots restaurados de recovery externo NÃO sobrescrevem mappings ativos de BySourcePart
    if not BySourcePart[key] then
        BySourcePart[key] = targetId
    end
    dbg('RestoreExternalSnapshot', targetId, 'stableId', stableId, 'txn', externalTxnId)
    return targetId, true
end

-- ─── Consumo Atômico (At-Most-Once) ────────────────────────────────────────────

--- Consome atômica e definitivamente o entitlement.
--- Garante que apenas a primeira chamada tem sucesso e concede os dados da peça.
---@param id string
---@param src number
---@param actionName string
---@param expectedPartKey? string
---@return { ok: boolean, err?: string, partKey?: string, sourceNetId?: number, sessionId?: string, provenance?: table, entitlement?: table, stablePartIdentity?: string }
function PartEntitlement.Consume(id, src, actionName, expectedPartKey)
    local okVal, valRes = PartEntitlement.Validate(id, src, expectedPartKey)
    if not okVal then
        return { ok = false, err = valRes }
    end

    local e = valRes
    -- ⚠ Consumo atômico sem yield entre a validação e a mudança de estado
    e.state          = 'CONSUMED'
    e.consumedAt     = os.time()
    e.consumedBy     = ServerChopPlayerKey(src)
    e.consumedAction = actionName or 'unknown'
    e.updatedAt      = os.time()

    dbg('Consume', id, 'partKey', e.partKey, 'action', actionName, 'by', src)
    return {
        ok                 = true,
        partKey            = e.partKey,
        sourceNetId        = e.sourceNetId,
        sessionId          = e.sessionId,
        stablePartIdentity = e.stablePartIdentity,
        provenance         = e.provenance and {
            realPlate    = e.provenance.realPlate,
            model        = e.provenance.model,
            vehicleClass = e.provenance.vehicleClass,
            className    = e.provenance.className,
        } or nil,
        entitlement        = PartEntitlement.Get(id),
    }
end

-- ─── Rate Limiting Defensivo ───────────────────────────────────────────────────

---@param src number
---@param bucket string
---@param cooldownMs number
---@return boolean allowed
function PartEntitlement.CheckRateLimit(src, bucket, cooldownMs)
    if not src or src <= 0 then return false end
    RateLimits[bucket] = RateLimits[bucket] or {}
    local now = GetGameTimer()
    local expiry = RateLimits[bucket][src] or 0
    if now < expiry then
        return false
    end
    RateLimits[bucket][src] = now + (tonumber(cooldownMs) or 500)
    return true
end

--- Log de atividade suspeita
---@param src number
---@param reason string
---@param details? string
function PartEntitlement.LogSuspicious(src, reason, details)
    local msg = ('[SECURITY][PartEntitlement] src: %s (%s) | reason: %s | details: %s'):format(
        tostring(src),
        tostring(ServerChopPlayerKey(src)),
        tostring(reason),
        tostring(details or 'none')
    )
    print(('[vp_chopshop] %s'):format(msg))
    if type(VPChopDiscordLog) == 'function' then
        pcall(VPChopDiscordLog, 'Alerta de Segurança - PartEntitlement', msg)
    end
end

-- ─── Cleanup ───────────────────────────────────────────────────────────────────

AddEventHandler('playerDropped', function()
    local src = source
    for _, bucket in pairs(RateLimits) do
        bucket[src] = nil
    end
end)

-- ─── Seam de Teste ─────────────────────────────────────────────────────────────
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    PartEntitlement._test = {
        reset = function() Entitlements, BySourcePart, RateLimits, _seq = {}, {}, {}, 0 end,
        _all  = function() return Entitlements end,
        normalizeKey = normalizeKey,
        setBootNonce = function(n) _bootNonce = n end,
    }
end

dbg('módulo PartEntitlement carregado')

