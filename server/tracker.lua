-- server/tracker.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.2.3] GPS Tracker & LoJack Domain Authority
--  Strict netId type normalization, pre-auth observation gates,
--  lifecycle validation, and server-filtered police beacon broadcast.
-- ═══════════════════════════════════════════════════════════════════════════════

TrackerManager = TrackerManager or {}

local _trackers = {}          -- trackerId -> { trackerId, netId, model, modelClass, markerSet, canonicalPlate, state, lastPing, created }
local _netToTracker = {}      -- canonicalNetId -> trackerId
local _activeRemovals = {}    -- src -> { token, trackerId, netId, model, markerSet, startedAt, expiresAt }
local _bootNonce = tostring(os.time()) .. ':' .. tostring(math.random(1000, 9999))
local _seq = 0
local _mockNow = nil
local _mockRoll = nil

local function nowMs()
    return _mockNow or GetGameTimer()
end

local function getRandomRoll()
    if _mockRoll ~= nil then
        return _mockRoll
    end
    return math.random()
end

--- Normaliza estritamente o netId para número inteiro positivo finito
---@param netId any
---@return number|nil
local function normalizeNetId(netId)
    if type(netId) ~= 'number' then
        return nil
    end
    if netId ~= netId or netId == math.huge or netId == -math.huge or netId <= 0 or math.floor(netId) ~= netId then
        return nil
    end
    return netId
end

--- Normaliza string de placa removendo espaços em branco nas extremidades
---@param p any
---@return string
local function normalizePlate(p)
    if type(p) ~= 'string' then return '' end
    return (p:gsub('^%s*(.-)%s*$', '%1'))
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

--- Prova que a entidade resolvida pelo netId é um veículo válido no servidor
---@param netId any
---@return number|table|nil ent, string|nil err, number|nil canonNetId
local function resolveTrackerVehicle(netId)
    local canonNetId = normalizeNetId(netId)
    if not canonNetId then
        return nil, 'invalid_net', nil
    end
    if not NetworkGetEntityFromNetworkId or not GetEntityType then
        return nil, 'api_unavailable', canonNetId
    end
    local ent = NetworkGetEntityFromNetworkId(canonNetId)
    if not ent or ent == 0 or not DoesEntityExist or not DoesEntityExist(ent) then
        return nil, 'entity_not_found', canonNetId
    end
    if GetEntityType(ent) ~= 2 then
        return nil, 'not_vehicle', canonNetId
    end
    return ent, nil, canonNetId
end

--- Resolve a classe GTA do veículo server-side (compatível com runtime FiveM / QBox)
---@param ent any
---@param model number
---@return number|nil
local function resolveVehicleClass(ent, model)
    local class = nil
    if ent and DoesEntityExist and DoesEntityExist(ent) and GetVehicleClass then
        local ok, c = pcall(GetVehicleClass, ent)
        if ok and type(c) == 'number' and c >= 0 and c <= 22 then
            class = math.floor(c)
        end
    end
    if class == nil and model and GetVehicleClassFromName then
        local ok, c = pcall(GetVehicleClassFromName, model)
        if ok and type(c) == 'number' and c >= 0 and c <= 22 then
            class = math.floor(c)
        end
    end
    return class
end

--- Resolve a placa canônica a partir da visível lida na entidade física
---@param ent any
---@return string
local function resolveCanonicalPlate(ent)
    local visiblePlate = ''
    if ent and DoesEntityExist and DoesEntityExist(ent) and GetVehicleNumberPlateText then
        local raw = GetVehicleNumberPlateText(ent)
        visiblePlate = normalizePlate(raw)
    end

    local canonicalPlate = visiblePlate
    if visiblePlate ~= '' and type(VPChopMDT) == 'table' and type(VPChopMDT.GetRealPlate) == 'function' then
        local ok, real = pcall(VPChopMDT.GetRealPlate, visiblePlate)
        if ok and type(real) == 'string' and real ~= '' then
            canonicalPlate = normalizePlate(real)
        end
    end
    return canonicalPlate
end

--- Invalida um registro de tracker stale e limpa referências sem tocar em novos lifecycles
---@param trackerId string
---@param reason string|nil
local function invalidateTracker(trackerId, reason)
    local trk = _trackers[trackerId]
    if not trk then return end

    if _netToTracker[trk.netId] == trackerId then
        _netToTracker[trk.netId] = nil
    end

    for src, sess in pairs(_activeRemovals) do
        if sess.trackerId == trackerId then
            _activeRemovals[src] = nil
        end
    end

    _trackers[trackerId] = nil
end

--- Valida o lifecycle de um registro de tracker provando entidade, modelo e statebag
---@param trk table
---@return boolean ok, any ent, string|nil err
local function validateTrackerLifecycle(trk)
    if not trk or type(trk) ~= 'table' then
        return false, nil, 'invalid_record'
    end
    if _netToTracker[trk.netId] ~= trk.trackerId then
        return false, nil, 'stale_net_mapping'
    end
    local ent, err = resolveTrackerVehicle(trk.netId)
    if not ent then
        return false, nil, err or 'vehicle_stale'
    end
    local curModel = (GetEntityModel and GetEntityModel(ent)) or trk.model
    if curModel ~= trk.model then
        return false, nil, 'model_mismatch'
    end
    if trk.markerSet and Entity then
        local okSb, s = pcall(function() return Entity(ent).state end)
        if not okSb or not s or s.vpChopTrackerId ~= trk.trackerId then
            return false, nil, 'marker_mismatch'
        end
    end
    return true, ent, nil
end

--- Resolve e atribui o estado de rastreador para um veículo de forma server-authoritative
---@param netId any
---@param reason string|nil
---@param forcedChance number|nil (apenas para testes)
---@return table trackerRecord
function TrackerManager.ObserveVehicle(netId, reason, forcedChance)
    local cfg = getTrackerConfig()
    if not cfg.Enable then
        return { trackerId = 'none', state = 'NONE', hasTracker = false }
    end

    local ent, err, canonNetId = resolveTrackerVehicle(netId)
    if not ent then
        return { trackerId = 'none', state = 'NONE', hasTracker = false, err = err or 'not_vehicle' }
    end

    local model = (GetEntityModel and GetEntityModel(ent)) or 0

    -- Se já possui tracker associado a este netId, verifica integridade do lifecycle
    local existingId = _netToTracker[canonNetId]
    if existingId and _trackers[existingId] then
        local trk = _trackers[existingId]
        local okLife = validateTrackerLifecycle(trk)
        if okLife then
            return trk
        else
            -- Lifecycle anterior ficou stale (netId reutilizado): invalida o antigo
            invalidateTracker(existingId, 'recycled_net')
        end
    end

    local trackerId = mintTrackerId()
    local markerSet = false

    -- Statebag server-local write + readback confirmation
    if Entity then
        pcall(function()
            local stateObj = Entity(ent).state
            if stateObj and stateObj.set then
                stateObj:set('vpChopTrackerId', trackerId, false)
            elseif stateObj then
                stateObj.vpChopTrackerId = trackerId
            end
            local readBack = Entity(ent).state.vpChopTrackerId
            markerSet = (readBack == trackerId)
        end)
    end

    local modelClass = resolveVehicleClass(ent, model)
    local chance = forcedChance
    if not chance then
        local classChance = (modelClass ~= nil and cfg.ClassChances and cfg.ClassChances[modelClass]) or nil
        chance = classChance or cfg.DefaultChance or 0.40
    end
    chance = math.max(0.0, math.min(1.0, chance))

    local roll = getRandomRoll()
    local hasTracker = (roll <= chance)
    local state = hasTracker and 'ACTIVE' or 'NONE'

    local canonicalPlate = resolveCanonicalPlate(ent)

    local record = {
        trackerId = trackerId,
        netId = canonNetId,
        model = model,
        modelClass = modelClass,
        markerSet = markerSet,
        canonicalPlate = canonicalPlate,
        state = state,
        hasTracker = hasTracker,
        lastPing = 0,
        created = os.time(),
        reason = reason or 'observe',
    }

    _trackers[trackerId] = record
    _netToTracker[canonNetId] = trackerId
    return record
end

--- Retorna registro por trackerId
---@param trackerId string
---@return table|nil
function TrackerManager.GetByTrackerId(trackerId)
    return _trackers[trackerId]
end

--- Retorna registro pelo netId (se ainda ativo)
---@param netId any
---@return table|nil
function TrackerManager.GetByNetId(netId)
    local canonNetId = normalizeNetId(netId)
    if not canonNetId then return nil end
    local tid = _netToTracker[canonNetId]
    return tid and _trackers[tid]
end

--- Verifica se o veículo possui um rastreador ativo no momento
---@param netId any
---@return boolean
function TrackerManager.IsActive(netId)
    local trk = TrackerManager.GetByNetId(netId)
    return trk ~= nil and trk.state == 'ACTIVE'
end

--- Inicia o processo de remoção do rastreador com validações estritas de segurança
---@param src number
---@param netId any
---@return table { ok: boolean, err?: string, removalToken?: string, minDurationMs?: number }
function TrackerManager.StartRemoval(src, netId)
    local cfg = getTrackerConfig()
    if not cfg.Enable then
        return { ok = false, err = 'disabled' }
    end

    if type(IsValidSource) == 'function' and not IsValidSource(src) then
        return { ok = false, err = 'invalid_source' }
    end

    if type(ServerPlayerIsReady) == 'function' and not ServerPlayerIsReady(src) then
        return { ok = false, err = 'player_not_ready' }
    end

    local ent, err, canonNetId = resolveTrackerVehicle(netId)
    if not ent then
        return { ok = false, err = err or 'invalid_entity' }
    end

    -- 1. Validação estrita de distância física ANTES de criar/observar estado
    if GetPlayerPed and GetEntityCoords then
        local ped = GetPlayerPed(src)
        local pCoords = GetEntityCoords(ped)
        local vCoords = GetEntityCoords(ent)
        local maxDist = cfg.MaxDistance or 3.5
        if #(pCoords - vCoords) > maxDist then
            return { ok = false, err = 'distance' }
        end
    end

    -- 2. Validação de ferramenta necessária ANTES de criar/observar estado
    if cfg.RequiredTool and type(InvCount) == 'function' then
        local hasPrimary = InvCount(src, cfg.RequiredTool) > 0
        local hasFallback = cfg.ToolFallback and (InvCount(src, cfg.ToolFallback) > 0)
        if not hasPrimary and not hasFallback then
            return { ok = false, err = 'no_tool' }
        end
    end

    -- 3. SOMENTE AGORA observa o veículo legitimamente (gates de distância e ferramenta validados)
    local trk = TrackerManager.ObserveVehicle(canonNetId, 'removal_start')
    if trk.state == 'REMOVED' then
        return { ok = false, err = 'already_removed' }
    end
    if trk.state ~= 'ACTIVE' then
        return { ok = false, err = 'not_found' }
    end

    local token = mintRemovalToken(src)
    local minDur = cfg.MinDurationMs or 7000

    _activeRemovals[src] = {
        token = token,
        trackerId = trk.trackerId,
        netId = canonNetId,
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

--- Cancela uma tentativa ativa de remoção exigindo o token de autorização da sessão
---@param src number
---@param removalToken string
---@return table { ok: boolean, err?: string }
function TrackerManager.CancelRemoval(src, removalToken)
    if not removalToken or type(removalToken) ~= 'string' then
        return { ok = false, err = 'invalid_token' }
    end

    local session = _activeRemovals[src]
    if not session then
        return { ok = false, err = 'no_session' }
    end

    if session.token ~= removalToken then
        return { ok = false, err = 'invalid_token' }
    end

    _activeRemovals[src] = nil
    return { ok = true }
end

--- Finaliza a remoção do rastreador com revalidação integral de segurança
---@param src number
---@param netId any
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

    local canonNetId = normalizeNetId(netId)
    if not canonNetId then
        -- Não consome a sessão ativa se o payload de netId for malformado
        return { ok = false, err = 'invalid_net' }
    end

    local session = _activeRemovals[src]
    if not session then
        return { ok = false, err = 'no_session' }
    end

    if session.token ~= removalToken then
        return { ok = false, err = 'invalid_token' }
    end

    if session.netId ~= canonNetId then
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

    local trk = _trackers[session.trackerId]
    if not trk or trk.state ~= 'ACTIVE' then
        _activeRemovals[src] = nil
        return { ok = false, err = 'not_active' }
    end

    local okLife, ent, lifeErr = validateTrackerLifecycle(trk)
    if not okLife then
        _activeRemovals[src] = nil
        invalidateTracker(session.trackerId, lifeErr)
        if lifeErr == 'model_mismatch' or lifeErr == 'marker_mismatch' or lifeErr == 'stale_net_mapping' then
            return { ok = false, err = 'identity_mismatch' }
        end
        return { ok = false, err = lifeErr or 'vehicle_stale' }
    end

    -- Revalidação estrita de distância
    if GetPlayerPed and GetEntityCoords then
        local ped = GetPlayerPed(src)
        local pCoords = GetEntityCoords(ped)
        local vCoords = GetEntityCoords(ent)
        local maxDist = cfg.MaxDistance or 3.5
        if #(pCoords - vCoords) > maxDist then
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

    local staleIds = {}

    for trackerId, trk in pairs(_trackers) do
        if trk.state == 'ACTIVE' then
            local okLife, ent, lifeErr = validateTrackerLifecycle(trk)
            if not okLife then
                table.insert(staleIds, trackerId)
            elseif (now - trk.lastPing >= intervalMs) then
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

    for _, sid in ipairs(staleIds) do
        invalidateTracker(sid, 'stale_broadcast')
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
    setRoll = function(r) _mockRoll = r end,
    getTrackers = function() return _trackers end,
    getActiveRemovals = function() return _activeRemovals end,
    reset = function()
        _trackers = {}
        _netToTracker = {}
        _activeRemovals = {}
        _mockNow = nil
        _mockRoll = nil
        _seq = 0
    end,
}
