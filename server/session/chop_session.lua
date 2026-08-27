-- server/session/chop_session.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  ChopSession — fonte server-authoritative ÚNICA do estado de um desmanche.
--  v1.15 arch/chop-session · FASE: FUNDAÇÃO (core + lifecycle + jackstand).
--
--  NESTA FASE o core NÃO substitui ainda ChoppedByNetId (server/chop.lua) nem
--  AdvState (server/advanced_chop.lua). Ele existe, é testável, e o jackstand é
--  o primeiro consumidor real (server/session/jackstand.lua). A migração do
--  estado de peças (base → advanced) vem nas próximas PRs, com aprovação.
--
--  API pública (tabela global `ChopSession`):
--    Create(netId, src)            → session | nil, err     (idempotente por netId)
--    Get(sessionId)                → session | nil          (revalida liveness)
--    GetByVehicle(netId)           → session | nil          (revalida liveness)
--    AddParticipant(id, src)       → boolean
--    HasParticipant(id, src)       → boolean
--    SetState(id, newState)        → boolean, err           (bloqueia estados terminais)
--    CanTransition(from, to)       → boolean
--    MarkRaised(id, src)           → boolean
--    ClearRaised(id)               → boolean
--    IsRaised(netId)               → boolean                (conveniência p/ consumidores)
--    GetPartState(id, partKey)     → 'REMOVED' | nil
--    MarkPart(id, partKey, src)    → boolean, dup           (idempotente)
--    LockPart(id, partKey)         → boolean, token         (mutex de ação)
--    UnlockPart(id, partKey, tok)  → boolean
--    Touch(id)                     → nil
--    Complete(id)                  → boolean                (terminal, idempotente)
--    Cancel(id, reason)            → boolean                (terminal, idempotente)
--    CleanupVehicle(netId)         → nil                    (entityRemoved)
--    CleanupPlayer(src)            → nil                    (playerDropped)
--    Debug()                       → tabela snapshot (só p/ testes/observabilidade)
--
--  NÃO é um God object: só o mínimo p/ migrar o gameplay atual. YAGNI.
-- ═══════════════════════════════════════════════════════════════════════════════

local CFG = function() return Config.ChopSession or {} end
local function cfgNum(key, default)
    return math.floor(tonumber(CFG()[key]) or default)
end
local function enabled()
    local c = Config.ChopSession
    return c == nil or c.Enable ~= false   -- default ON quando o bloco não existe
end
local function dbg(...)
    if CFG().Debug or Config.Debug then
        print(('[vp_chopshop][ChopSession] %s'):format(table.concat({ ... }, ' ')))
    end
end

-- ─── Acesso a entidade (com seam de teste) ─────────────────────────────────────
-- Todo acesso a natives de veículo passa por esta tabela para que o self-test
-- (server/session/chop_session_spec.lua) possa injetar veículos falsos sem
-- OneSync. Em produção são exatamente os natives; nenhuma diferença de custo.
local EntityAPI = {
    get    = function(netId) return NetworkGetEntityFromNetworkId(netId) end,
    exists = function(ent) return ent and ent ~= 0 and DoesEntityExist(ent) end,
    model  = function(ent) return GetEntityModel(ent) end,
    plate  = function(ent) return (GetVehicleNumberPlateText(ent) or ''):gsub('%s+', '') end,
    owned  = function(ent)
        local st = Entity(ent).state
        return st and (st.vehicleid or (st.vehicleData and st.vehicleData.id)) or nil
    end,
}

-- ─── Estado em memória ──────────────────────────────────────────────────────────

---@type table<string, table>          sessionId → session
local Sessions       = {}
---@type table<integer, string>        netId    → sessionId  (índice reverso)
local ByVehicleNetId = {}

--- Sequência do VehicleSessionId. Monotônica pela vida do resource. Não persiste.
local _vsidSeq = 0
--- Sequência do sessionId.
local _sidSeq  = 0

-- ─── VehicleSessionId ──────────────────────────────────────────────────────────
-- Ver docs/audit/VEHICLE_SESSION_ID.md. Resumo:
--   • netId sozinho é reciclável → não serve de identidade persistente.
--   • Nenhum primitivo de QBox/OneSync/ox_lib cobre veículos NÃO-owned (o caso comum).
--   • VSID = id opaco cunhado 1× por sessão + fingerprint {netId, model, plate}.
--   • Invalidação: entityRemoved (imediata) + recheck de liveness (modelo!) em todo
--     Get/GetByVehicle + timeout por inatividade. Placa é forense, nunca identidade.

---@param netId integer
---@return string vsid, table fingerprint
local function mintVehicleIdentity(netId)
    _vsidSeq = _vsidSeq + 1
    local ent = EntityAPI.get(netId)
    local ok = EntityAPI.exists(ent)
    local fp = {
        netId    = netId,
        model    = ok and EntityAPI.model(ent) or nil,
        plate    = ok and EntityAPI.plate(ent) or nil,
        -- qbx_core: presente só em veículo owned/persistido; quando existe, reforça o match.
        ownedId  = ok and EntityAPI.owned(ent) or nil,
        mintedAt = os.time(),
    }
    return ('vsid:%d'):format(_vsidSeq), fp
end

--- Recheck barato: a entidade do netId ainda é o MESMO veículo que cunhou o VSID?
---@param session table
---@return boolean alive
local function vehicleStillValid(session)
    local fp = session.vehicle._fp
    local ent = EntityAPI.get(fp.netId)
    if not EntityAPI.exists(ent) then return false end
    -- Fail-closed: sessão sem modelo no fingerprint (mint degenerado) não pode
    -- ser revalidada contra netId reuse → tratada como stale.
    if not fp.model then return false end
    -- Modelo mudou ⇒ netId foi reciclado noutro veículo.
    if EntityAPI.model(ent) ~= fp.model then return false end
    -- Se ambos os lados têm ownedId, exigir match (mais forte, custo zero).
    if fp.ownedId then
        local liveOwned = EntityAPI.owned(ent)
        if liveOwned and liveOwned ~= fp.ownedId then return false end
    end
    return true
end

-- ─── Máquina de estados (coarse — regras de peça ficam no Part Registry depois) ──

local STATES = {
    CREATED           = true,
    RAISED            = true,
    DISMANTLING       = true,
    READY_FOR_DISCARD = true,
    COMPLETED         = true,   -- terminal
    CANCELLED         = true,   -- terminal
}
local TERMINAL = { COMPLETED = true, CANCELLED = true }
local TRANSITIONS = {
    CREATED           = { RAISED = true, DISMANTLING = true, CANCELLED = true },
    RAISED            = { DISMANTLING = true, READY_FOR_DISCARD = true, CREATED = true, CANCELLED = true },
    DISMANTLING       = { RAISED = true, READY_FOR_DISCARD = true, CANCELLED = true },
    READY_FOR_DISCARD = { DISMANTLING = true, COMPLETED = true, CANCELLED = true },
    COMPLETED         = {},
    CANCELLED         = {},
}

-- ─── Núcleo ────────────────────────────────────────────────────────────────────

ChopSession = {}

---@param from string
---@param to string
---@return boolean
function ChopSession.CanTransition(from, to)
    if not STATES[to] then return false end
    if from == to then return true end
    return (TRANSITIONS[from] or {})[to] == true
end

--- Resolve + revalida. Sessão stale (veículo sumiu / netId reciclado / terminal
--- há muito tempo) é limpa aqui e retorna nil.
---@param sessionId string
---@return table|nil
function ChopSession.Get(sessionId)
    local s = Sessions[sessionId]
    if not s then return nil end
    if TERMINAL[s.state] then return s end   -- terminal: devolve p/ leitura, não revalida
    if not vehicleStillValid(s) then
        dbg('Get: sessão', sessionId, 'stale (veículo inválido) → cleanup')
        ChopSession.CleanupVehicle(s.vehicle.netId)
        return nil
    end
    return s
end

---@param netId integer
---@return table|nil
function ChopSession.GetByVehicle(netId)
    netId = tonumber(netId)
    if not netId then return nil end
    local id = ByVehicleNetId[netId]
    if not id then return nil end
    return ChopSession.Get(id)
end

--- Idempotente: se já existe sessão viva p/ o netId, devolve-a (não cunha nova).
---@param netId integer
---@param src number
---@return table|nil session, string|nil err
function ChopSession.Create(netId, src)
    if not enabled() then return nil, 'disabled' end
    netId = tonumber(netId)
    if not netId then return nil, 'net' end
    if not (src and GetPlayerName(src)) then return nil, 'src' end

    local existing = ChopSession.GetByVehicle(netId)
    if existing then
        ChopSession.AddParticipant(existing.id, src)
        return existing
    end

    local ent = EntityAPI.get(netId)
    if not EntityAPI.exists(ent) then return nil, 'vehicle' end

    _sidSeq = _sidSeq + 1
    local vsid, fp = mintVehicleIdentity(netId)
    local now = os.time()
    local s = {
        id           = ('cs:%d'):format(_sidSeq),
        vehicle      = {
            netId     = netId,
            identity  = vsid,
            model     = fp.model,
            realPlate = fp.plate,
            _fp       = fp,
        },
        state        = 'CREATED',
        startedBy    = src,
        participants = { [src] = true },
        createdAt    = now,
        lastActivity = now,
        parts        = {},           -- partKey → { state, by, at }
        _partLocks   = {},           -- partKey → token
        raised       = false,
        raisedBy     = nil,
        completed    = false,
    }
    Sessions[s.id]         = s
    ByVehicleNetId[netId]  = s.id
    dbg('Create', s.id, 'netId', netId, 'vsid', vsid, 'by', src)
    return s
end

---@param id string
---@param src number
---@return boolean
function ChopSession.AddParticipant(id, src)
    local s = Sessions[id]
    if not s or TERMINAL[s.state] then return false end
    if not (src and GetPlayerName(src)) then return false end
    s.participants[src] = true
    s.lastActivity = os.time()
    return true
end

---@param id string
---@param src number
---@return boolean
function ChopSession.HasParticipant(id, src)
    local s = Sessions[id]
    return (s and s.participants[src] == true) or false
end

---@param id string
---@param newState string
---@return boolean ok, string|nil err
function ChopSession.SetState(id, newState)
    local s = Sessions[id]
    if not s then return false, 'no_session' end
    if TERMINAL[s.state] then return false, 'terminal' end
    if not ChopSession.CanTransition(s.state, newState) then
        dbg('SetState BLOQUEADO', id, s.state, '→', newState)
        return false, 'bad_transition'
    end
    s.state = newState
    s.lastActivity = os.time()
    return true
end

--- Elevação é um booleano dedicado (independente da FSM coarse), como no design.
---@param id string
---@param src number
---@return boolean
function ChopSession.MarkRaised(id, src)
    local s = Sessions[id]
    if not s or TERMINAL[s.state] then return false end
    s.raised   = true
    s.raisedBy = src
    s.lastActivity = os.time()
    if s.state == 'CREATED' then ChopSession.SetState(id, 'RAISED') end
    return true
end

---@param id string
---@return boolean
function ChopSession.ClearRaised(id)
    local s = Sessions[id]
    if not s then return false end
    s.raised   = false
    s.raisedBy = nil
    s.lastActivity = os.time()
    if s.state == 'RAISED' then ChopSession.SetState(id, 'DISMANTLING') end
    return true
end

--- Conveniência p/ consumidores (advanced chop, etc.) que só têm o netId.
---@param netId integer
---@return boolean
function ChopSession.IsRaised(netId)
    local s = ChopSession.GetByVehicle(netId)
    return (s and s.raised == true) or false
end

-- ─── Peças (API pronta; consumo pelo gameplay vem nas próximas PRs) ─────────────

---@param id string
---@param partKey string
---@return string|nil
function ChopSession.GetPartState(id, partKey)
    local s = Sessions[id]
    local p = s and s.parts[partKey]
    return p and p.state or nil
end

--- Idempotente: marcar peça já removida devolve (true, true) sem duplicar.
---@param id string
---@param partKey string
---@param src number
---@return boolean ok, boolean duplicate
function ChopSession.MarkPart(id, partKey, src)
    local s = Sessions[id]
    if not s or TERMINAL[s.state] then return false, false end
    if type(partKey) ~= 'string' then return false, false end
    if s.parts[partKey] then return true, true end
    s.parts[partKey] = { state = 'REMOVED', by = src, at = os.time() }
    s.lastActivity = os.time()
    if s.state == 'CREATED' or s.state == 'RAISED' then
        ChopSession.SetState(id, 'DISMANTLING')
    end
    return true, false
end

--- Mutex leve por peça (para operações com janela de UX). Token de uso único.
--- TTL: um lock não liberado (client crashou antes do UnlockPart) expira sozinho
--- após `PartLockTtlMs` — evita travar a peça até a sessão inteira morrer.
---@param id string
---@param partKey string
---@return boolean ok, string|nil token
function ChopSession.LockPart(id, partKey)
    local s = Sessions[id]
    if not s or TERMINAL[s.state] then return false end
    local existing = s._partLocks[partKey]
    if existing and GetGameTimer() < existing.expiresAt then return false end
    local ttl = cfgNum('PartLockTtlMs', 60000)
    local tok = ('%s:%s:%d'):format(id, partKey, math.random(1, 2147483647))
    s._partLocks[partKey] = { token = tok, expiresAt = GetGameTimer() + ttl }
    return true, tok
end

---@param id string
---@param partKey string
---@param token string
---@return boolean
function ChopSession.UnlockPart(id, partKey, token)
    local s = Sessions[id]
    if not s then return false end
    local l = s._partLocks[partKey]
    if not l or l.token ~= token then return false end
    s._partLocks[partKey] = nil
    return true
end

-- ─── Ciclo de vida ─────────────────────────────────────────────────────────────

---@param id string
function ChopSession.Touch(id)
    local s = Sessions[id]
    if s then s.lastActivity = os.time() end
end

--- Terminal + idempotente.
---@param id string
---@return boolean
function ChopSession.Complete(id)
    local s = Sessions[id]
    if not s then return false end
    if TERMINAL[s.state] then return true end
    s.state = 'COMPLETED'
    s.completed = true
    s.lastActivity = os.time()
    dbg('Complete', id)
    return true
end

--- Terminal + idempotente. Não deleta na hora — o sweeper recolhe (mais barato e
--- tolera reconnect curto). entityRemoved deleta de imediato.
---@param id string
---@param reason string|nil
---@return boolean
function ChopSession.Cancel(id, reason)
    local s = Sessions[id]
    if not s then return false end
    if TERMINAL[s.state] then return true end
    s.state = 'CANCELLED'
    s.cancelReason = reason or 'cancelled'
    s.lastActivity = os.time()
    dbg('Cancel', id, '(' .. tostring(reason) .. ')')
    return true
end

---@param netId integer
function ChopSession.CleanupVehicle(netId)
    netId = tonumber(netId)
    if not netId then return end
    local id = ByVehicleNetId[netId]
    ByVehicleNetId[netId] = nil
    if id then
        dbg('CleanupVehicle', 'netId', netId, '→', id)
        Sessions[id] = nil
    end
end

--- Player saiu: remove dos participantes. Se sobrar alguém, a sessão vive
--- (startedBy é reatribuído). Se ficar vazia, cancela.
---@param src number
function ChopSession.CleanupPlayer(src)
    for id, s in pairs(Sessions) do
        if s.participants[src] then
            s.participants[src] = nil
            local remaining = next(s.participants)
            if not remaining then
                ChopSession.Cancel(id, 'abandoned')
            elseif s.startedBy == src then
                s.startedBy = remaining
                dbg('CleanupPlayer', 'startedBy de', id, 'reatribuído a', remaining)
            end
        end
    end
end

---@return table
function ChopSession.Debug()
    local out = { count = 0, sessions = {} }
    for id, s in pairs(Sessions) do
        out.count = out.count + 1
        out.sessions[id] = {
            state = s.state, netId = s.vehicle.netId, vsid = s.vehicle.identity,
            raised = s.raised, participants = (function()
                local t = {} for p in pairs(s.participants) do t[#t+1] = p end return t
            end)(),
            parts = (function()
                local t = {} for k in pairs(s.parts) do t[#t+1] = k end return t
            end)(),
            idleSec = os.time() - s.lastActivity,
        }
    end
    return out
end

-- ─── Seam de teste ────────────────────────────────────────────────────────────
-- Só é EXPOSTO quando a convar vp_chopshop_selftest=1. Em produção `_test` é nil —
-- um lua executor server-side não pode chamar reset()/setEntityAPI() p/ apagar
-- sessões ou injetar veículos falsos.
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    ChopSession._test = {
        setEntityAPI = function(tbl) for k, v in pairs(tbl) do EntityAPI[k] = v end end,
        reset = function()
            Sessions, ByVehicleNetId = {}, {}
            _vsidSeq, _sidSeq = 0, 0
        end,
        _sessions = function() return Sessions end,
    }
end

-- ─── Hooks de limpeza ──────────────────────────────────────────────────────────

AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId and netId ~= 0 and ByVehicleNetId[netId] then
        ChopSession.CleanupVehicle(netId)
    end
end)

AddEventHandler('playerDropped', function()
    ChopSession.CleanupPlayer(source)
end)

-- Sweeper de timeout + coleta de sessões terminais. Sem polling de entidades:
-- só percorre a tabela de sessões (pequena) num intervalo largo.
CreateThread(function()
    local interval = cfgNum('SweepIntervalMs', 30000)
    local timeout  = cfgNum('SessionTimeoutMs', 15 * 60 * 1000) / 1000  -- s
    while true do
        Wait(interval)
        local now = os.time()
        for id, s in pairs(Sessions) do
            if TERMINAL[s.state] and (now - s.lastActivity) > 60 then
                Sessions[id] = nil
                if ByVehicleNetId[s.vehicle.netId] == id then
                    ByVehicleNetId[s.vehicle.netId] = nil
                end
            elseif not TERMINAL[s.state] and (now - s.lastActivity) > timeout then
                dbg('sweep: timeout', id)
                ChopSession.Cancel(id, 'timeout')
            elseif not TERMINAL[s.state] and not vehicleStillValid(s) then
                dbg('sweep: veículo inválido', id)
                ChopSession.CleanupVehicle(s.vehicle.netId)
            end
        end
    end
end)

dbg('módulo carregado')
