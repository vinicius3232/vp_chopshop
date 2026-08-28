-- server/session/chop_session.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  ChopSession — fonte server-authoritative ÚNICA do estado de um desmanche.
--  v1.15 arch/chop-session · FASE: FUNDAÇÃO (core + lifecycle + jackstand).
--
--  Consumidores: jackstand (raise/lower), o BASE CHOP (server/session/base_state.lua,
--  substituiu ChoppedByNetId — PR-B) e o ADVANCED CHOP (server/session/advanced_state.lua,
--  substituiu AdvState/AdvMutex — PR-C). `session.parts[k].origin` = 'base'|'advanced'.
--  Base + advanced têm UMA fonte server-authoritative: ChopSession.parts.
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
    -- [v1.15 #7] Marcador server-local na própria entidade. `false` = não replicado.
    -- REFORÇO de lifecycle/identidade — NÃO é segredo, token de auth, nem prova
    -- anti-cheat isolada. É mais UM fator; model/ownedId/entityRemoved/timeout
    -- continuam valendo. `tag` só reporta sucesso com WRITE + READBACK confirmado.
    tag = function(ent, vsid)
        local ok = pcall(function() Entity(ent).state:set('vpChopVsid', vsid, false) end)
        if not ok then return false end
        local readOk, value = pcall(function() return Entity(ent).state.vpChopVsid end)
        return readOk and value == vsid
    end,
    marker = function(ent)
        local ok, v = pcall(function() return Entity(ent).state.vpChopVsid end)
        return ok and v or nil
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
--   • VSID = id opaco cunhado 1× por sessão + fingerprint {netId, model, plate, ownedId}.
--   • Invalidação (fatores SOMADOS, nunca substituem uns aos outros):
--       entityRemoved (imediata) + recheck de modelo em todo Get/GetByVehicle +
--       ownedId (quando existe) + marcador server-local vpChopVsid (fix #7, só
--       participa se WRITE+READBACK confirmou no mint) + timeout por inatividade.
--   • Placa é forense, nunca identidade. `vpChopVsid` é REFORÇO de lifecycle —
--     não é segredo/token/prova anti-cheat isolada. Ausência dele NUNCA invalida
--     sessões (cai no fallback model/ownedId/entityRemoved/timeout).

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
    -- [v1.15 #7] Marcador server-local: pega netId reciclado no MESMO modelo (não-owned).
    -- Só decide se conseguimos cravar o marcador no mint (fp.markerSet). Caso o
    -- runtime não suporte state bag server-local, cai no fallback (model/ownedId).
    if fp.markerSet and EntityAPI.marker(ent) ~= session.vehicle.identity then
        return false
    end
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

--- [v1.15 PR-B follow-up] `session.parts` é a fonte AUTORITATIVA do estado físico
--- do veículo. Sessão COM peça removida = "ledger" que não pode morrer por
--- disconnect/timeout enquanto o veículo existir.
---@param s table
---@return boolean
local function hasParts(s)
    return next(s.parts) ~= nil
end

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

--- [v1.15 #1] ACTIVE SESSION LOOKUP — retorna SÓ sessão ativa (não-terminal) e
--- revalidada. Terminal (COMPLETED/CANCELLED) → nil. Gameplay usa só isto.
---@param sessionId string
---@return table|nil
function ChopSession.Get(sessionId)
    local s = Sessions[sessionId]
    if not s then return nil end
    if TERMINAL[s.state] then return nil end
    if not vehicleStillValid(s) then
        dbg('Get: sessão', sessionId, 'stale (veículo inválido) → cleanup')
        ChopSession.CleanupVehicle(s.vehicle.netId)
        return nil
    end
    return s
end

-- [v1.15 #1] Não há `Peek` público: leitura terminal/debug é via `Debug()`
-- (snapshot read-only). Gameplay usa só Get/GetByVehicle (ACTIVE lookup).

--- ACTIVE SESSION LOOKUP por veículo (terminal → nil).
---@param netId integer
---@return table|nil
function ChopSession.GetByVehicle(netId)
    netId = tonumber(netId)
    if not netId then return nil end
    local id = ByVehicleNetId[netId]
    if not id then return nil end
    return ChopSession.Get(id)
end

--- Idempotente p/ sessão ATIVA. Terminal:
---   • CANCELLED → não é reutilizável: descarta e cunha nova (cs/vsid novos).
---   • COMPLETED → não pode reabrir enquanto o veículo original existir → nil,'completed'.
---@param netId integer
---@param src number
---@return table|nil session, string|nil err
function ChopSession.Create(netId, src)
    if not enabled() then return nil, 'disabled' end
    netId = tonumber(netId)
    if not netId then return nil, 'net' end
    if not (src and GetPlayerName(src)) then return nil, 'src' end

    -- Consulta o índice reverso CRU (inclui sessões terminais ainda não coletadas).
    local rawId = ByVehicleNetId[netId]
    local raw   = rawId and Sessions[rawId] or nil
    if raw then
        if not TERMINAL[raw.state] then
            local active = ChopSession.Get(rawId)   -- revalida
            if active then
                ChopSession.AddParticipant(active.id, src)
                -- [v1.15 #7b] re-crava o marcador (idempotente): cobre o caso raro de
                -- a entidade server-side ter perdido o state bag desde o mint.
                if not active.vehicle._fp.markerSet then
                    local e = EntityAPI.get(netId)
                    if EntityAPI.exists(e) then
                        active.vehicle._fp.markerSet = EntityAPI.tag(e, active.vehicle.identity) == true
                    end
                end
                return active
            end
            -- Get devolveu nil → stale, já limpo → segue p/ cunhar nova.
        elseif raw.state == 'COMPLETED' then
            if vehicleStillValid(raw) then return nil, 'completed' end
            ChopSession.CleanupVehicle(netId)       -- veículo foi-se: libera o slot
        else -- CANCELLED
            Sessions[rawId] = nil
            ByVehicleNetId[netId] = nil
        end
    end

    local ent = EntityAPI.get(netId)
    if not EntityAPI.exists(ent) then return nil, 'vehicle' end

    _sidSeq = _sidSeq + 1
    local vsid, fp = mintVehicleIdentity(netId)
    fp.markerSet = EntityAPI.tag(ent, vsid) == true   -- [v1.15 #7] crava o marcador
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
    if not s or TERMINAL[s.state] then return false end   -- [v1.15 #4] mesmo invariante de MarkRaised
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

--- [v1.15 PR-E] `origin` da peça ('base'|'advanced') — consumido pelo tyre
--- entitlement (só emite de peça `origin='base'`). Não expõe o resto da metadata.
---@param id string
---@param partKey string
---@return string|nil
function ChopSession.GetPartOrigin(id, partKey)
    local s = Sessions[id]
    local p = s and s.parts[partKey]
    return p and p.origin or nil
end

--- Idempotente: marcar peça já removida devolve (true, true) sem duplicar nem
--- sobrescrever metadata existente.
--- ⚠ DEVE permanecer SEM YIELD: o FREEZE de READY_FOR_DISCARD (PR-D) só é atômico
--- porque o check de estado e a gravação da peça acontecem no mesmo tick. Não
--- adicionar log assíncrono / DB write aqui.
---@param id string
---@param partKey string
---@param src number
---@param opts? { origin?: 'base'|'advanced' }   metadata escolhida SÓ por código server-side
---@return boolean ok, boolean duplicate, string|nil err
function ChopSession.MarkPart(id, partKey, src, opts)
    local s = Sessions[id]
    if not s or TERMINAL[s.state] then return false, false end
    -- [v1.15 PR-D] FREEZE: entrada em READY_FOR_DISCARD = operação terminal em curso
    -- (payout). Nenhuma peça nova pode entrar no meio da transação — senão a
    -- contagem que autorizou o payout muda enquanto o adapter de cash yielda.
    if s.state == 'READY_FOR_DISCARD' then return false, false, 'discarding' end
    if type(partKey) ~= 'string' then return false, false end
    if s.parts[partKey] then return true, true end   -- duplicate: metadata preservada
    local origin = (opts and opts.origin == 'advanced') and 'advanced' or 'base'
    s.parts[partKey] = { state = 'REMOVED', by = src, at = os.time(), origin = origin }
    s.lastActivity = os.time()
    if s.state == 'CREATED' or s.state == 'RAISED' then
        ChopSession.SetState(id, 'DISMANTLING')
    end
    return true, false
end

--- Conta peças na sessão, opcionalmente filtrando por `origin`.
---@param id string
---@param origin? 'base'|'advanced'   nil = todas
---@return integer
function ChopSession.CountParts(id, origin)
    local s = Sessions[id]
    if not s then return 0 end
    local c = 0
    for _, p in pairs(s.parts) do
        if origin == nil or p.origin == origin then c = c + 1 end
    end
    return c
end

--- Mutex leve por peça (para operações com janela de UX). Token de uso único.
--- TTL: um lock não liberado (client crashou antes do UnlockPart) expira sozinho
--- após `PartLockTtlMs` — evita travar a peça até a sessão inteira morrer.
--- Um lock PINNED (ver PinPartLock) NÃO expira por TTL — usado enquanto o domínio
--- server-controlled está em COMMITTING (fail-closed: melhor travar a peça do que
--- permitir dois commits).
---@param id string
---@param partKey string
---@return boolean ok, string|nil token
function ChopSession.LockPart(id, partKey)
    local s = Sessions[id]
    if not s or TERMINAL[s.state] then return false end
    -- [v1.15 PR-D] FREEZE: não iniciar nova ação física durante o payout terminal.
    if s.state == 'READY_FOR_DISCARD' then return false, 'discarding' end
    local existing = s._partLocks[partKey]
    if existing and (existing.pinned or GetGameTimer() < existing.expiresAt) then return false end
    local ttl = cfgNum('PartLockTtlMs', 60000)
    local tok = ('%s:%s:%d'):format(id, partKey, math.random(1, 2147483647))
    s._partLocks[partKey] = { token = tok, expiresAt = GetGameTimer() + ttl }
    return true, tok
end

--- [v1.15 PR-G hardening] "Prende" um lock existente (token deve bater) para que ele
--- deixe de expirar por TTL. O ActionSession chama isto ao entrar em COMMITTING —
--- a partir daí só `UnlockPart` (token certo) libera a peça.
---@param id string
---@param partKey string
---@param token string
---@return boolean
function ChopSession.PinPartLock(id, partKey, token)
    local s = Sessions[id]
    if not s then return false end
    local l = s._partLocks[partKey]
    if not l or l.token ~= token then return false end
    l.pinned = true
    return true
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

--- [v1.15 #3] Respeita a FSM: só completa a partir de um estado com transição
--- válida p/ COMPLETED (hoje: READY_FOR_DISCARD). COMPLETED→Complete = idempotente.
---@param id string
---@return boolean ok, string|nil err
function ChopSession.Complete(id)
    local s = Sessions[id]
    if not s then return false, 'no_session' end
    if s.state == 'COMPLETED' then return true end        -- idempotente
    if s.state == 'CANCELLED' then return false, 'terminal' end
    if not ChopSession.CanTransition(s.state, 'COMPLETED') then
        dbg('Complete BLOQUEADO', id, 'de', s.state)
        return false, 'bad_state'
    end
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
    -- [PR-B micro] COMMITTED VEHICLE STATE só morre com a entidade. Uma sessão que
    -- já tem peça removida NÃO pode ser cancelada por workflow — nada é tocado.
    if hasParts(s) then return false, 'committed' end
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

--- Player saiu: remove dos participantes.
--- WORKFLOW MEMBERSHIP ≠ VEHICLE STATE LIFETIME:
---  • sobra participante → sessão vive, startedBy reatribuído.
---  • fica vazia SEM peça removida → Cancel('abandoned') (comportamento anterior).
---  • fica vazia COM peça removida → sessão NÃO é destruída. Fica sem participantes
---    e resolvível por GetByVehicle enquanto o veículo existir; um novo fluxo
---    legítimo pode reentrar. `raised` é zerado por segurança; `parts`/VSID ficam.
---@param src number
function ChopSession.CleanupPlayer(src)
    for id, s in pairs(Sessions) do
        if s.participants[src] then
            s.participants[src] = nil
            if TERMINAL[s.state] then
                -- Terminal permanece terminal: só remove a membership, sem tocar
                -- lastActivity nem invariants do tombstone.
            else
                local remaining = next(s.participants)
                if not remaining then
                    if hasParts(s) then
                        -- Estado físico registrado → sessão NÃO é destruída por
                        -- disconnect. Fica órfã (resolvível), raised zerado por
                        -- segurança. NÃO renova lastActivity (não é atividade).
                        s.raised, s.raisedBy = false, nil
                        dbg('CleanupPlayer', id, 'sem participantes mas COM parts → mantida')
                    else
                        ChopSession.Cancel(id, 'abandoned')
                    end
                elseif s.startedBy == src then
                    s.startedBy = remaining
                    dbg('CleanupPlayer', 'startedBy de', id, 'reatribuído a', remaining)
                end
            end
        end
    end
end

--- [v1.15 PR-D hardening] SÓ p/ CLEANUP DESTRUTIVO (retry de DeleteEntity após
--- discard, via SetTimeout). Identidade ESTRITA — mais forte que `vehicleStillValid`
--- (que aceita fallback por netId+model quando não há marker nem ownedId; num
--- veículo non-owned com netId reciclado no MESMO modelo isso deixaria passar
--- OUTRO veículo). Aqui o marcador VSID server-local é OBRIGATÓRIO:
---   1. sessão COMPLETED (único cenário de cleanup pós-discard);
---   2. `fp.markerSet == true` — sem marcador confirmado no mint → NÃO auto-delete;
---   3. entidade existe;
---   4. modelo bate;
---   5. `EntityAPI.marker(ent) == session.vehicle.identity` (o VSID exato).
--- Qualquer falha → nil + reason. Melhor deixar um veículo aguardando cleanup
--- (tombstone + cleanupPending + log) do que deletar a entidade errada.
--- O delete INICIAL logo após o discard usa o handle original já resolvido no
--- callback e não passa por aqui. Gameplay normal continua SEM Peek.
---@param sessionId string
---@return integer|nil entity, string|nil reason
function ChopSession.ResolveBoundVehicleForCleanup(sessionId)
    local s = Sessions[sessionId]
    if not s then return nil, 'no_session' end
    if s.state ~= 'COMPLETED' then return nil, 'not_tombstone' end
    local fp = s.vehicle._fp
    if fp.markerSet ~= true then return nil, 'identity_unproven' end
    local ent = EntityAPI.get(fp.netId)
    if not EntityAPI.exists(ent) then return nil, 'gone' end
    if EntityAPI.model(ent) ~= fp.model then return nil, 'identity_mismatch' end
    if EntityAPI.marker(ent) ~= s.vehicle.identity then return nil, 'identity_mismatch' end
    return ent
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
local TERMINAL_RETENTION_S = 60
local function sweepOnce()
    -- INVARIANT: enquanto vehicleStillValid(s) == true, TEMPO SOZINHO nunca apaga
    -- committed vehicle state (session com parts, ou tombstone COMPLETED). Workflow
    -- (sessão SEM parts) expira; estado físico não. O ÚNICO caminho que mata estado
    -- físico é a entidade sumir/reciclar → `not vehicleStillValid` → CleanupVehicle.
    local timeout   = cfgNum('SessionTimeoutMs', 15 * 60 * 1000) / 1000   -- s
    local warnAfter = cfgNum('OrphanWarnAfterMs', 60 * 60 * 1000) / 1000  -- s (SÓ log/telemetria)
    local now = os.time()
    for id, s in pairs(Sessions) do
        local idle    = now - s.lastActivity
        local vehGone = not vehicleStillValid(s)
        if TERMINAL[s.state] then
            -- COMPLETED + veículo vivo = TOMBSTONE permanente (bloqueia re-chop após
            -- payment/discard mesmo se DeleteEntity falhar). SEM TTL. Só sai quando
            -- a entidade some/recicla. CANCELLED: retenção curta.
            local keepTombstone = (s.state == 'COMPLETED') and not vehGone
            if not keepTombstone and (vehGone or idle > TERMINAL_RETENTION_S) then
                Sessions[id] = nil
                if ByVehicleNetId[s.vehicle.netId] == id then
                    ByVehicleNetId[s.vehicle.netId] = nil
                end
            end
        elseif vehGone then
            dbg('sweep: veículo inválido', id)
            ChopSession.CleanupVehicle(s.vehicle.netId)
        elseif not hasParts(s) then
            -- Sessão SEM estado físico (só workflow): timeout normal.
            if idle > timeout then
                dbg('sweep: timeout (sem parts)', id)
                ChopSession.Cancel(id, 'timeout')
            end
        else
            -- Sessão COM parts + veículo vivo: NUNCA cancela por tempo. Só telemetria.
            if warnAfter > 0 and idle > warnAfter and not s._orphanWarned then
                s._orphanWarned = true
                dbg('sweep: órfã com parts há ' .. idle .. 's (netId ' .. s.vehicle.netId .. ') — MANTIDA')
            end
        end
    end
end

CreateThread(function()
    local interval = cfgNum('SweepIntervalMs', 30000)
    while true do
        Wait(interval)
        sweepOnce()
    end
end)

-- ─── Seam de teste ────────────────────────────────────────────────────────────
-- Só EXPOSTO sob a convar vp_chopshop_selftest=1. Em produção `_test` é nil — um
-- lua executor server-side não pode apagar sessões nem injetar veículos falsos.
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    ChopSession._test = {
        setEntityAPI = function(tbl) for k, v in pairs(tbl) do EntityAPI[k] = v end end,
        reset = function()
            Sessions, ByVehicleNetId = {}, {}
            _vsidSeq, _sidSeq = 0, 0
        end,
        _sessions = function() return Sessions end,
        setIdle   = function(id, seconds)   -- back-date lastActivity p/ testar o sweeper
            if Sessions[id] then Sessions[id].lastActivity = os.time() - seconds end
        end,
        sweep     = sweepOnce,
    }
end

dbg('módulo carregado')
