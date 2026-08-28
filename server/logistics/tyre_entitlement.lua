-- server/logistics/tyre_entitlement.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-E] TYRE ENTITLEMENT — LEDGER LOGÍSTICO INDEPENDENTE da ChopSession.
--
--  Substitui o workaround `PlayerTyreStock[src]` (contador genérico que só provava
--  "removeu ALGUMA roda"). Agora cada roda REAL removida (peça committed
--  `origin='base'`, `kind='tyre'`) emite UM entitlement single-use que segue por:
--    REMOVED → STORED (no truck) → SOLD
--       └──────────────────────→ LOST (player saiu / truck sumiu)
--
--  POR QUE INDEPENDENTE: o veículo de origem pode ser deletado/descartado/despawnar
--  enquanto o pneu já separado continua na mão / no chão / no truck.
--  `ChopSession.CleanupVehicle` NÃO pode apagar pneus já fisicamente separados.
--  A referência à sessão de origem (sessionId/vsid/partKey) vira só PROVENANCE.
--
--  NÃO é ActionSession: não prova que o prop foi carregado honestamente nem que a
--  animação/minigame rodou. A autoridade aqui é: PEÇA COMMITTED + SINGLE-USE +
--  OWNER + STORAGE + LIFECYCLE.
--
--  IN-MEMORY: restart do resource perde os entitlements (mesma limitação da
--  ChopSession — sem persistência nesta série).
-- ═══════════════════════════════════════════════════════════════════════════════

TyreEntitlement = {}

---@alias TyreEntitlementState 'REMOVED'|'STORED'|'SOLD'|'LOST'

---@type table<string, table>              entitlementId → entitlement
local Entitlements = {}
---@type table<string, string>             (sessionId..':'..partKey) → entitlementId  (idempotência)
local BySourcePart = {}
local _seq = 0

local function dbg(...)
    if Config.Debug or (Config.TyreLogistics and Config.TyreLogistics.Debug) then
        print(('[vp_chopshop][TyreEntitlement] %s'):format(table.concat({ ... }, ' ')))
    end
end

local function isTyrePart(partKey)
    return VPChopPartGtaClass(partKey) == 'tyre'
end

-- ─── Emissão ───────────────────────────────────────────────────────────────────

--- Emite (ou devolve, se já existe) o entitlement de uma roda committed.
--- IDEMPOTENTE por (sessionId, partKey): PART_CHOPPED duplicado / retry / replay
--- nunca geram um 2º entitlement.
---@param sessionId string
---@param src number
---@param partKey string
---@return string|nil entitlementId, boolean|string isNewOrErr
function TyreEntitlement.Issue(sessionId, src, partKey)
    if not (Config.TyreSelling and Config.TyreSelling.Enable) then return nil, 'disabled' end
    if type(sessionId) ~= 'string' or type(partKey) ~= 'string' then return nil, 'args' end
    if not isTyrePart(partKey) then return nil, 'not_tyre' end          -- servidor deriva do Part Def

    -- ⚠ Issue DEVE permanecer SEM YIELD entre este check e a escrita de
    -- BySourcePart abaixo — é o que torna a idempotência atômica (Lua single-thread).
    -- O call site (server/main.lua chopPart) já é síncrono + protegido por
    -- _chopPartRateLimit + ChopInProgress. Não adicionar await/log assíncrono aqui.
    local key = sessionId .. ':' .. partKey
    local existing = BySourcePart[key]
    if existing and Entitlements[existing] then
        return existing, false                                          -- já emitido → mesmo id
    end

    local session = ChopSession.Get(sessionId)                          -- ACTIVE (terminal → nil)
    if not session then return nil, 'no_session' end
    if ChopSession.GetPartState(sessionId, partKey) ~= 'REMOVED' then return nil, 'not_committed' end
    if ChopSession.GetPartOrigin(sessionId, partKey) ~= 'base' then return nil, 'origin' end

    _seq = _seq + 1
    local now = os.time()
    local e = {
        id       = ('te:%d'):format(_seq),
        source   = {
            sessionId = sessionId,
            vsid      = session.vehicle and session.vehicle.identity or nil,
            partKey   = partKey,
            model     = session.vehicle and session.vehicle.model or nil,
        },
        removedBy = src,
        state     = 'REMOVED',
        storageId = nil,
        createdAt = now,
        updatedAt = now,
    }
    Entitlements[e.id] = e
    BySourcePart[key]  = e.id
    dbg('Issue', e.id, 'partKey', partKey, 'session', sessionId, 'by', src)
    return e.id, true
end

-- ─── Leitura ───────────────────────────────────────────────────────────────────

---@param id string
---@return table|nil   cópia rasa (chamadores não mutam direto)
function TyreEntitlement.Get(id)
    local e = Entitlements[id]
    if not e then return nil end
    return {
        id = e.id, state = e.state, removedBy = e.removedBy, storageId = e.storageId,
        source = { sessionId = e.source.sessionId, vsid = e.source.vsid,
                   partKey = e.source.partKey, model = e.source.model },
        createdAt = e.createdAt, updatedAt = e.updatedAt,
    }
end

---@param id string
---@return TyreEntitlementState|nil
function TyreEntitlement.State(id)
    local e = Entitlements[id]
    return e and e.state or nil
end

--- Entitlements RECUPERÁVEIS de um jogador (só p/ UX/diagnóstico — NÃO cria nada,
--- NÃO recompensa). Limite pequeno.
---@param src number
---@param limit? integer
---@return { id: string, partKey: string, model: any, createdAt: integer }[]
function TyreEntitlement.GetPendingForPlayer(src, limit)
    limit = math.min(math.floor(tonumber(limit) or 12), 24)
    local out = {}
    for _, e in pairs(Entitlements) do
        if e.state == 'REMOVED' and e.removedBy == src then
            out[#out + 1] = { id = e.id, partKey = e.source.partKey, model = e.source.model, createdAt = e.createdAt }
            if #out >= limit then break end
        end
    end
    return out
end

-- ─── Transições (usadas SÓ pelo truck_storage / fence, nunca pelo client) ───────

--- Marca STORED. Só de REMOVED. `storageId` obrigatório.
---@param id string
---@param storageId string
---@return boolean ok, string|nil err
function TyreEntitlement.MarkStored(id, storageId)
    local e = Entitlements[id]
    if not e then return false, 'unknown' end
    if e.state == 'STORED' and e.storageId == storageId then return true end   -- idempotente
    if e.state ~= 'REMOVED' then return false, e.state == 'STORED' and 'already_stored' or 'bad_state' end
    if type(storageId) ~= 'string' then return false, 'storage' end
    e.state, e.storageId, e.updatedAt = 'STORED', storageId, os.time()
    dbg('MarkStored', id, '→', storageId)
    return true
end

--- Marca SOLD. Só de STORED. SOLD é PERMANENTE — nunca volta p/ STORED (replay-safe).
---@param id string
---@return boolean ok, string|nil err
function TyreEntitlement.MarkSold(id)
    local e = Entitlements[id]
    if not e then return false, 'unknown' end
    if e.state == 'SOLD' then return true end                                  -- idempotente
    if e.state ~= 'STORED' then return false, 'bad_state' end
    e.state, e.updatedAt = 'SOLD', os.time()
    -- storageId preservado como histórico/provenance.
    dbg('MarkSold', id)
    return true
end

--- Marca LOST (player saiu com REMOVED / truck sumiu com STORED). Terminal.
---@param id string
---@param reason? string
---@return boolean ok
function TyreEntitlement.MarkLost(id, reason)
    local e = Entitlements[id]
    if not e then return false end
    if e.state == 'SOLD' or e.state == 'LOST' then return e.state == 'LOST' end -- SOLD nunca vira LOST
    e.state, e.updatedAt, e.lostReason = 'LOST', os.time(), reason or 'lost'
    dbg('MarkLost', id, '(' .. tostring(reason) .. ')')
    return true
end

-- ─── Cleanup ───────────────────────────────────────────────────────────────────

--- Player saiu: entitlements REMOVED (na mão / no chão / não guardados) atribuídos
--- a ele → LOST. Preserva a política atual de `PlayerTyreStock[src]=nil`.
--- STORED no truck NÃO dependem do player — continuam STORED enquanto o truck existir.
---@param src number
function TyreEntitlement.CleanupPlayer(src)
    for _, e in pairs(Entitlements) do
        if e.state == 'REMOVED' and e.removedBy == src then
            e.state, e.updatedAt, e.lostReason = 'LOST', os.time(), 'player_dropped'
        end
    end
end

AddEventHandler('playerDropped', function()
    TyreEntitlement.CleanupPlayer(source)
end)

-- NÃO há hook em ChopSession.CleanupVehicle: o entitlement já emitido SOBREVIVE
-- ao sumiço do veículo de origem (o pneu foi separado fisicamente).

-- ─── Seam de teste ─────────────────────────────────────────────────────────────
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    TyreEntitlement._test = {
        reset = function() Entitlements, BySourcePart, _seq = {}, {}, 0 end,
        _all  = function() return Entitlements end,
    }
end

dbg('módulo carregado')
