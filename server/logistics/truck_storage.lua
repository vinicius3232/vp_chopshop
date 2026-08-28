-- server/logistics/truck_storage.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-E] TRUCK STORAGE — identidade própria p/ a caçamba do truck.
--
--  ANTES: `ServerTyreCounts[truckNetId]` — sofria de netId reuse (outro veículo
--  herdando o netId "herdava" a carga econômica) e a contagem era um inteiro solto.
--
--  AGORA: `storageId = 'ts:<n>'` cunhado no 1º load + MARCADOR server-local
--  `vpChopTyreStorageId` na entidade (WRITE + READBACK). Como este state protege
--  ESTADO ECONÔMICO, marcador não-confirmável ⇒ FAIL-CLOSED (`storage_identity`).
--  netId é só lookup; a identidade autoritativa é storageId + marcador + model.
--
--  A CONTAGEM é DERIVADA: nº de entitlementIds STORED no storage. `chopTyreCount`
--  (state bag replicado) continua só p/ UX — nunca autoridade.
--
--  IN-MEMORY (sem persistência nesta série).
-- ═══════════════════════════════════════════════════════════════════════════════

TruckStorage = {}

---@type table<string, table>            storageId → storage
local Storages = {}
---@type table<integer, string>          truckNetId → storageId   (SÓ lookup)
local ByTruckNetId = {}
local _seq = 0

local MARKER_KEY = 'vpChopTyreStorageId'

local function dbg(...)
    if Config.Debug or (Config.TyreLogistics and Config.TyreLogistics.Debug) then
        print(('[vp_chopshop][TruckStorage] %s'):format(table.concat({ ... }, ' ')))
    end
end

-- Acesso a entidade com seam de teste (mesma ideia da ChopSession).
local EntityAPI = {
    get    = function(netId) return NetworkGetEntityFromNetworkId(netId) end,
    exists = function(e) return e and e ~= 0 and DoesEntityExist(e) end,
    model  = function(e) return GetEntityModel(e) end,
    tag    = function(e, sid)
        local ok = pcall(function() Entity(e).state:set(MARKER_KEY, sid, false) end)
        if not ok then return false end
        local rOk, v = pcall(function() return Entity(e).state[MARKER_KEY] end)
        return rOk and v == sid
    end,
    marker = function(e)
        local ok, v = pcall(function() return Entity(e).state[MARKER_KEY] end)
        return ok and v or nil
    end,
    setCount = function(e, n)
        pcall(function() Entity(e).state:set('chopTyreCount', n, true) end)   -- SÓ UX
    end,
}

local function maxTyres()
    return math.max(1, math.floor(tonumber(Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4))
end

--- Nº de entitlements REALMENTE STORED neste storage (DERIVADO, nunca um contador).
---@param storageId string
---@return integer
function TruckStorage.Count(storageId)
    local st = Storages[storageId]
    if not st or st.state ~= 'ACTIVE' then return 0 end
    local c = 0
    for id in pairs(st.entitlementIds) do
        if TyreEntitlement.State(id) == 'STORED' then c = c + 1 end
    end
    return c
end

---@param storageId string
---@return string[]   entitlementIds STORED
function TruckStorage.SnapshotStored(storageId)
    local st = Storages[storageId]
    local out = {}
    if not st then return out end
    for id in pairs(st.entitlementIds) do
        if TyreEntitlement.State(id) == 'STORED' then out[#out + 1] = id end
    end
    return out
end

--- Resolve o storage do truck OU cunha um novo (no 1º load). Fail-closed em
--- qualquer ambiguidade de identidade.
---@param truckNetId integer
---@return string|nil storageId, string|nil err
function TruckStorage.Resolve(truckNetId)
    truckNetId = tonumber(truckNetId)
    if not truckNetId then return nil, 'net' end
    local ent = EntityAPI.get(truckNetId)
    if not EntityAPI.exists(ent) then return nil, 'no_truck' end
    local model = EntityAPI.model(ent)

    local existingId = ByTruckNetId[truckNetId]
    if existingId then
        local st = Storages[existingId]
        if st and st.state == 'ACTIVE' then
            -- netId reuse: a entidade atual precisa AINDA carregar o marcador certo
            -- E ser o mesmo modelo. Senão o netId foi reciclado → fail-closed.
            if EntityAPI.marker(ent) == existingId and st.truck.model == model then
                return existingId
            end
            dbg('Resolve: netId', truckNetId, 'não bate mais com', existingId, '→ storage_identity')
            return nil, 'storage_identity'
        end
        ByTruckNetId[truckNetId] = nil
    end

    -- Cunhar novo storage + marcador WRITE+READBACK.
    _seq = _seq + 1
    local storageId = ('ts:%d'):format(_seq)
    if EntityAPI.tag(ent, storageId) ~= true then
        _seq = _seq - 1
        dbg('Resolve: marcador não confirmou p/ netId', truckNetId, '→ storage_identity (fail-closed)')
        return nil, 'storage_identity'
    end
    Storages[storageId] = {
        id             = storageId,
        truck          = { netId = truckNetId, model = model },
        entitlementIds = {},
        state          = 'ACTIVE',
        createdAt      = os.time(),
    }
    ByTruckNetId[truckNetId] = storageId
    EntityAPI.setCount(ent, 0)
    dbg('Resolve: novo storage', storageId, 'netId', truckNetId)
    return storageId
end

--- Guarda UM entitlement no storage. Atômico (o lock por storageId é do chamador).
--- Valida capacidade + estado do entitlement. NÃO valida owner/range/truck-model
--- (isso é do fence, antes de chamar).
---@param storageId string
---@param entitlementId string
---@return boolean ok, integer|string countOrErr
function TruckStorage.Load(storageId, entitlementId)
    local st = Storages[storageId]
    if not st or st.state ~= 'ACTIVE' then return false, 'storage' end
    local eState = TyreEntitlement.State(entitlementId)
    if eState == nil then return false, 'no_entitlement' end
    if eState == 'STORED' then return false, 'already_stored' end
    if eState ~= 'REMOVED' then return false, 'bad_state' end

    if TruckStorage.Count(storageId) >= maxTyres() then return false, 'truck_full' end

    local ok, err = TyreEntitlement.MarkStored(entitlementId, storageId)
    if not ok then return false, err or 'store_failed' end
    st.entitlementIds[entitlementId] = true

    local n = TruckStorage.Count(storageId)
    local ent = EntityAPI.get(st.truck.netId)
    if EntityAPI.exists(ent) then EntityAPI.setCount(ent, n) end
    return true, n
end

--- Fecha a venda: cada id STORED → SOLD, storage esvaziado. `ids` = snapshot
--- capturado ANTES do pagamento (chamador). Idempotente por entitlement.
---@param storageId string
---@param ids string[]
---@return integer soldCount
function TruckStorage.CommitSold(storageId, ids)
    local st = Storages[storageId]
    local sold = 0
    for _, id in ipairs(ids or {}) do
        if TyreEntitlement.MarkSold(id) then
            sold = sold + 1
            if st then st.entitlementIds[id] = nil end
        end
    end
    if st then
        local ent = EntityAPI.get(st.truck.netId)
        if EntityAPI.exists(ent) then EntityAPI.setCount(ent, TruckStorage.Count(storageId)) end
    end
    return sold
end

--- Lookup read-only (sem cunhar). Usado por sellTyres.
---@param truckNetId integer
---@return string|nil storageId, string|nil err
function TruckStorage.Peek(truckNetId)
    truckNetId = tonumber(truckNetId)
    if not truckNetId then return nil, 'net' end
    local id = ByTruckNetId[truckNetId]
    if not id then return nil, 'no_storage' end
    local st = Storages[id]
    if not st or st.state ~= 'ACTIVE' then return nil, 'no_storage' end
    local ent = EntityAPI.get(truckNetId)
    if not EntityAPI.exists(ent) then return nil, 'no_truck' end
    if EntityAPI.marker(ent) ~= id or st.truck.model ~= EntityAPI.model(ent) then
        return nil, 'storage_identity'
    end
    return id
end

-- ─── Cleanup ───────────────────────────────────────────────────────────────────

--- Truck sumiu: todos os entitlements STORED naquele storage → LOST. Sem payout
--- futuro. Preserva a semântica econômica "truck sumiu = carga perdida".
---@param truckNetId integer
function TruckStorage.OnTruckRemoved(truckNetId)
    local id = ByTruckNetId[truckNetId]
    if not id then return end
    local st = Storages[id]
    ByTruckNetId[truckNetId] = nil
    if not st then return end
    for eid in pairs(st.entitlementIds) do
        if TyreEntitlement.State(eid) == 'STORED' then
            TyreEntitlement.MarkLost(eid, 'truck_removed')
        end
    end
    st.state = 'REMOVED'
    Storages[id] = nil
    dbg('OnTruckRemoved', truckNetId, 'storage', id, '→ carga LOST')
end

AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId and netId ~= 0 and ByTruckNetId[netId] then
        TruckStorage.OnTruckRemoved(netId)
    end
end)

-- ─── Seam de teste ─────────────────────────────────────────────────────────────
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    TruckStorage._test = {
        setEntityAPI = function(tbl) for k, v in pairs(tbl) do EntityAPI[k] = v end end,
        reset = function() Storages, ByTruckNetId, _seq = {}, {}, 0 end,
        _all  = function() return Storages end,
    }
end

dbg('módulo carregado')
