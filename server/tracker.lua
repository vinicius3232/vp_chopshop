-- server/tracker.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.2.1] GPS Tracker & LoJack Domain Authority
--  Server-authoritative vehicle state machine, netId recycling protection,
--  removal token transaction, and server-filtered police beacon broadcast.
-- ═══════════════════════════════════════════════════════════════════════════════

TrackerManager = TrackerManager or {}

local _trackers = {}          -- trackerId -> { trackerId, netId, model, markerSet, canonicalPlate, state, lastPing, created }
local _netToTracker = {}      -- netId -> trackerId
local _activeRemovals = {}    -- src -> { token, trackerId, netId, model, markerSet, startedAt, expiresAt }
local _bootNonce = tostring(os.time()) .. ':' .. tostring(math.random(1000, 9999))
local _seq = 0
local _mockNow = nil

local function nowMs()
    return _mockNow or GetGameTimer()
end

--- Retorna a configuração sanitizada de Tracker
---@return table
local function getTrackerConfig()
    return Config.Tracker or {
        Enable = true,
        DefaultChance = 0.40,
        ClassChances = {
            [0] = 0.15, [1] = 0.20, [2] = 0.30, [3] = 0.35, [4] = 0.40,
            [5] = 0.45, [6] = 0.65, [7] = 0.85, [8] = 0.25, [9] = 0.30,
            [10] = 0.20, [11] = 0.20, [12] = 0.20,
        },
        RequiredTool = 'pliers',
        ToolFallback = 'screwdriver',
        MinDurationMs = 7000,
        MaxDistance = 3.5,
        PingIntervalSeconds = 15,
        BlipDurationSeconds = 10,
        PoliceJobs = { 'police', 'sheriff', 'bcso', 'state' },
        RemovalEvidence = true,
    }
end

--- Gera um identificador único e opaco para o rastreador
---@return string
local function mintTrackerId()
    _seq = _seq + 1
    return ('trk:%s:%d:%d'):format(_bootNonce, _seq, math.random(1000, 9999))
end

--- Gera um token opaco para a sessão de remoção
---@param src number
---@return string
local function mintRemovalToken(src)
    return ('rem:%s:%d:%d:%d'):format(_bootNonce, src, _seq, math.random(10000, 99999))
end

--- Resolve e atribui o estado de rastreador para um veículo de forma server-authoritative
---@param netId number
---@param reason string|nil
---@param forcedChance number|nil (apenas para testes)
---@return table trackerRecord
function TrackerManager.ObserveVehicle(netId, reason, forcedChance)
    local cfg = getTrackerConfig()
    if not cfg.Enable then
        return { trackerId = 'none', state = 'NONE', hasTracker = false }
    end

    if not netId or netId <= 0 then
        return { trackerId = 'none', state = 'NONE', hasTracker = false, err = 'invalid_net' }
    end

    local ent = nil
    if NetworkGetEntityFromNetworkId then
        ent = NetworkGetEntityFromNetworkId(netId)
    end

    -- Se já possui tracker associado a este netId, verifica integridade do modelo/statebag
    local existingId = _netToTracker[netId]
    if existingId and _trackers[existingId] then
        local trk = _trackers[existingId]
        if ent and DoesEntityExist and DoesEntityExist(ent) then
            local curModel = (GetEntityModel and GetEntityModel(ent)) or trk.model
            if curModel == trk.model then
                if trk.markerSet and Entity then
                    local s = Entity(ent).state
                    if s and s.vpChopTrackerId == trk.trackerId then
                        return trk
                    end
                else
                    return trk
                end
            end
        else
            return trk
        end
    end

    -- Novo lifecycle veicular: deriva dados server-side
    local model = 0
    if ent and DoesEntityExist and DoesEntityExist(ent) and GetEntityModel then
        model = GetEntityModel(ent)
    end

    local trackerId = mintTrackerId()
    local markerSet = false

    -- Statebag write + readback confirmation
    if ent and DoesEntityExist and DoesEntityExist(ent) and Entity then
        pcall(function()
            Entity(ent).state.vpChopTrackerId = trackerId
            markerSet = (Entity(ent).state.vpChopTrackerId == trackerId)
        end)
    end

    local chance = forcedChance
    if not chance then
        chance = cfg.DefaultChance or 0.40
    end

    local roll = math.random()
    local hasTracker = (roll <= chance)
    local state = hasTracker and 'ACTIVE' or 'NONE'

    local canonicalPlate = ''
    if type(VPChopMDT) == 'table' and type(VPChopMDT.GetRealPlate) == 'function' then
        pcall(function()
            canonicalPlate = VPChopMDT.GetRealPlate(netId) or ''
        end)
    end

    local record = {
        trackerId = trackerId,
        netId = netId,
        model = model,
        markerSet = markerSet,
        canonicalPlate = canonicalPlate,
        state = state,
        hasTracker = hasTracker,
        lastPing = 0,
        created = os.time(),
        reason = reason or 'observe',
    }

    _trackers[trackerId] = record
    _netToTracker[netId] = trackerId
    return record
end

--- Retorna registro por trackerId
---@param trackerId string
---@return table|nil
function TrackerManager.GetByTrackerId(trackerId)
    return _trackers[trackerId]
end

--- Retorna registro pelo netId (se ainda ativo)
---@param netId number
---@return table|nil
function TrackerManager.GetByNetId(netId)
    local tid = _netToTracker[netId]
    return tid and _trackers[tid]
end

--- Verifica se o veículo possui um rastreador ativo no momento
---@param netId number
---@return boolean
function TrackerManager.IsActive(netId)
    local trk = TrackerManager.GetByNetId(netId)
    return trk ~= nil and trk.state == 'ACTIVE'
end

--- Inicia o processo de remoção do rastreador com validações estritas de segurança
---@param src number
---@param netId number
---@return table { ok: boolean, err?: string, removalToken?: string, minDurationMs?: number }
function TrackerManager.StartRemoval(src, netId)
    local cfg = getTrackerConfig()
    if not cfg.Enable then
        return { ok = false, err = 'disabled' }
    end

    if type(IsValidSource) == 'function' and not IsValidSource(src) then
        return { ok = false, err = 'invalid_source' }
    end

    if not netId or netId <= 0 then
        return { ok = false, err = 'invalid_net' }
    end

    local ent = nil
    if NetworkGetEntityFromNetworkId then
        ent = NetworkGetEntityFromNetworkId(netId)
    end

    if not ent or (DoesEntityExist and not DoesEntityExist(ent)) then
        return { ok = false, err = 'invalid_entity' }
    end

    local trk = TrackerManager.ObserveVehicle(netId, 'removal_start')
    if trk.state == 'REMOVED' then
        return { ok = false, err = 'already_removed' }
    end
    if trk.state ~= 'ACTIVE' then
        return { ok = false, err = 'not_found' }
    end

    -- Validação de ferramenta necessária
    if cfg.RequiredTool and type(InvCount) == 'function' then
        local hasPrimary = InvCount(src, cfg.RequiredTool) > 0
        local hasFallback = cfg.ToolFallback and (InvCount(src, cfg.ToolFallback) > 0)
        if not hasPrimary and not hasFallback then
            return { ok = false, err = 'no_tool' }
        end
    end

    -- Validação de distância física
    if GetPlayerPed and GetEntityCoords then
        local ped = GetPlayerPed(src)
        local pCoords = GetEntityCoords(ped)
        local vCoords = GetEntityCoords(ent)
        local maxDist = cfg.MaxDistance or 3.5
        if #(pCoords - vCoords) > (maxDist + 1.0) then
            return { ok = false, err = 'distance' }
        end
    end

    local token = mintRemovalToken(src)
    local minDur = cfg.MinDurationMs or 7000

    _activeRemovals[src] = {
        token = token,
        trackerId = trk.trackerId,
        netId = netId,
        model = trk.model,
        markerSet = trk.markerSet,
        startedAt = nowMs(),
        expiresAt = nowMs() + minDur + 20000, -- TTL de 20s além da duração mínima
    }

    return {
        ok = true,
        removalToken = token,
        minDurationMs = minDur,
    }
end

--- Cancela uma tentativa ativa de remoção sem alterar o estado do rastreador
---@param src number
---@param removalToken string
---@return table { ok: boolean }
function TrackerManager.CancelRemoval(src, removalToken)
    local session = _activeRemovals[src]
    if session and (not removalToken or session.token == removalToken) then
        _activeRemovals[src] = nil
    end
    return { ok = true }
end

--- Finaliza a remoção do rastreador com revalidação integral de segurança
---@param src number
---@param netId number
---@param removalToken string
---@return table { ok: boolean, err?: string }
function TrackerManager.CompleteRemoval(src, netId, removalToken)
    local cfg = getTrackerConfig()
    if not cfg.Enable then
        return { ok = false, err = 'disabled' }
    end

    if type(IsValidSource) == 'function' and not IsValidSource(src) then
        return { ok = false, err = 'invalid_source' }
    end

    local session = _activeRemovals[src]
    if not session then
        return { ok = false, err = 'no_session' }
    end

    if session.token ~= removalToken then
        return { ok = false, err = 'invalid_token' }
    end

    if session.netId ~= netId then
        return { ok = false, err = 'vehicle_mismatch' }
    end

    local curTime = nowMs()
    if curTime > session.expiresAt then
        _activeRemovals[src] = nil
        return { ok = false, err = 'expired' }
    end

    -- Revalidação estrita de tempo mínimo sem margem negativa de rede
    local minDur = cfg.MinDurationMs or 7000
    local elapsed = curTime - session.startedAt
    if elapsed < minDur then
        return { ok = false, err = 'too_fast' }
    end

    local ent = nil
    if NetworkGetEntityFromNetworkId then
        ent = NetworkGetEntityFromNetworkId(netId)
    end

    if not ent or (DoesEntityExist and not DoesEntityExist(ent)) then
        _activeRemovals[src] = nil
        return { ok = false, err = 'vehicle_stale' }
    end

    -- Revalidação de modelo e statebag (anti-recycling)
    if GetEntityModel and GetEntityModel(ent) ~= session.model then
        _activeRemovals[src] = nil
        return { ok = false, err = 'identity_mismatch' }
    end

    if session.markerSet and Entity then
        local s = Entity(ent).state
        if not s or s.vpChopTrackerId ~= session.trackerId then
            _activeRemovals[src] = nil
            return { ok = false, err = 'identity_mismatch' }
        end
    end

    -- Revalidação de distância
    if GetPlayerPed and GetEntityCoords then
        local ped = GetPlayerPed(src)
        local pCoords = GetEntityCoords(ped)
        local vCoords = GetEntityCoords(ent)
        local maxDist = cfg.MaxDistance or 3.5
        if #(pCoords - vCoords) > (maxDist + 1.0) then
            _activeRemovals[src] = nil
            return { ok = false, err = 'distance' }
        end
    end

    -- Revalidação de ferramenta
    if cfg.RequiredTool and type(InvCount) == 'function' then
        local hasPrimary = InvCount(src, cfg.RequiredTool) > 0
        local hasFallback = cfg.ToolFallback and (InvCount(src, cfg.ToolFallback) > 0)
        if not hasPrimary and not hasFallback then
            _activeRemovals[src] = nil
            return { ok = false, err = 'no_tool' }
        end
    end

    local trk = _trackers[session.trackerId]
    if not trk or trk.state ~= 'ACTIVE' then
        _activeRemovals[src] = nil
        return { ok = false, err = 'not_active' }
    end

    -- Transição de estado autoritativa
    trk.state = 'REMOVED'
    trk.hasTracker = false
    _activeRemovals[src] = nil

    -- Plant defensivo de evidência forense usando actionKey dedicada 'tracker_removal'
    if cfg.RemovalEvidence and type(VPChopLeaveEvidence) == 'function' then
        local coords = vector3(0, 0, 0)
        if GetEntityCoords then
            coords = GetEntityCoords(ent)
        end
        pcall(function()
            VPChopLeaveEvidence(src, coords, 'tracker_removal', trk.canonicalPlate)
        end)
    end

    return { ok = true }
end

--- Broadcast policial server-filtered: apenas policiais recebem as coordenadas do beacon
---@return number pingsSent
function TrackerManager.BroadcastPings()
    local cfg = getTrackerConfig()
    if not cfg.Enable then return 0 end

    local now = nowMs()
    local intervalMs = (cfg.PingIntervalSeconds or 15) * 1000
    local pingsSent = 0

    local policeJobs = cfg.PoliceJobs or { 'police', 'sheriff', 'bcso', 'state' }

    for trackerId, trk in pairs(_trackers) do
        if trk.state == 'ACTIVE' and (now - trk.lastPing >= intervalMs) then
            local ent = NetworkGetEntityFromNetworkId and NetworkGetEntityFromNetworkId(trk.netId)
            if ent and DoesEntityExist and DoesEntityExist(ent) and GetEntityCoords then
                trk.lastPing = now
                local coords = GetEntityCoords(ent)
                pingsSent = pingsSent + 1

                -- Filtra e despacha exclusivamente para policiais autorizados server-side
                if GetPlayers and TriggerClientEvent then
                    for _, pidStr in ipairs(GetPlayers()) do
                        local recipient = tonumber(pidStr)
                        if recipient and IsValidSource(recipient) then
                            local isCop = false
                            if type(BridgeIsPolice) == 'function' then
                                isCop = BridgeIsPolice(recipient, policeJobs)
                            end
                            if isCop then
                                TriggerClientEvent('vp_chopshop:client:trackerPing', recipient, coords, trk.canonicalPlate)
                            end
                        end
                    end
                end
            end
        end
    end

    return pingsSent
end

-- ─── Limpeza em desconexão ───────────────────────────────────────────────────
if AddEventHandler then
    AddEventHandler('playerDropped', function()
        local src = source
        if src then
            _activeRemovals[src] = nil
        end
    end)
end

-- ─── Callbacks de Integração ──────────────────────────────────────────────────
if lib and lib.callback and lib.callback.register then
    lib.callback.register('vp_chopshop:tracker:check', function(src, netId)
        local trk = TrackerManager.ObserveVehicle(netId, 'check')
        return {
            hasTracker = (trk.state == 'ACTIVE'),
            state = trk.state,
        }
    end)

    lib.callback.register('vp_chopshop:tracker:startRemoval', function(src, netId)
        return TrackerManager.StartRemoval(src, netId)
    end)

    lib.callback.register('vp_chopshop:tracker:cancelRemoval', function(src, removalToken)
        return TrackerManager.CancelRemoval(src, removalToken)
    end)

    lib.callback.register('vp_chopshop:tracker:completeRemoval', function(src, netId, removalToken)
        return TrackerManager.CompleteRemoval(src, netId, removalToken)
    end)
end

-- ─── Sweeper & Beacon Loop ────────────────────────────────────────────────────
if CreateThread then
    CreateThread(function()
        while true do
            Wait((getTrackerConfig().PingIntervalSeconds or 15) * 1000)
            TrackerManager.BroadcastPings()
        end
    end)
end

-- ─── Test Seam ────────────────────────────────────────────────────────────────
TrackerManager._test = {
    setTime = function(t) _mockNow = t end,
    getTrackers = function() return _trackers end,
    getActiveRemovals = function() return _activeRemovals end,
    reset = function()
        _trackers = {}
        _netToTracker = {}
        _activeRemovals = {}
        _mockNow = nil
        _seq = 0
    end,
}
