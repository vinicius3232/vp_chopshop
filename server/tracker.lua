-- server/tracker.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.2] GPS Tracker & LoJack Domain Authority
--  Server-authoritative state machine, vehicle resolution, anti-recycling
--  and periodic police beacon broadcast loop.
-- ═══════════════════════════════════════════════════════════════════════════════

TrackerManager = TrackerManager or {}

local _trackers = {}          -- vsid -> { vsid, netId, plate, modelClass, state, lastPing, created }
local _activeRemovals = {}    -- src  -> { vsid, netId, startTime }
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

--- Resolve um identificador consistente para o veículo (VSID)
---@param netId number
---@param plate string|nil
---@return string vsid
local function resolveVsid(netId, plate)
    local p = (plate and plate ~= '' and plate) or 'UNKNOWN'
    return ('trk:%d:%s'):format(netId or 0, p)
end

--- Resolve o estado do rastreador GPS para um veículo no servidor
---@param netId number
---@param plate string|nil
---@param modelClass number|nil
---@param forcedChance number|nil
---@return table trackerData
function TrackerManager.Resolve(netId, plate, modelClass, forcedChance)
    local cfg = getTrackerConfig()
    if not cfg.Enable then
        return { hasTracker = false, state = 'NONE', vsid = 'none' }
    end

    local vsid = resolveVsid(netId, plate)
    if _trackers[vsid] then
        return _trackers[vsid]
    end

    local chance = forcedChance
    if not chance then
        local cTable = cfg.ClassChances or {}
        chance = (modelClass and cTable[modelClass]) or cfg.DefaultChance or 0.40
    end

    local roll = math.random()
    local hasTracker = (roll <= chance)
    local state = hasTracker and 'ACTIVE' or 'NONE'

    local data = {
        vsid = vsid,
        netId = netId,
        plate = plate or '',
        modelClass = modelClass or 0,
        state = state,
        hasTracker = hasTracker,
        lastPing = 0,
        created = os.time(),
    }

    _trackers[vsid] = data
    return data
end

--- Retorna o registro de tracker por VSID
---@param vsid string
---@return table|nil
function TrackerManager.GetByVsid(vsid)
    return _trackers[vsid]
end

--- Retorna o registro de tracker por NetId
---@param netId number
---@param plate string|nil
---@return table|nil
function TrackerManager.GetByNetId(netId, plate)
    local vsid = resolveVsid(netId, plate)
    return _trackers[vsid]
end

--- Verifica se o veículo possui um rastreador ativo no momento
---@param netId number
---@param plate string|nil
---@return boolean
function TrackerManager.IsActive(netId, plate)
    local trk = TrackerManager.GetByNetId(netId, plate)
    return trk ~= nil and trk.state == 'ACTIVE'
end

--- Inicia o processo de remoção do rastreador com validações de segurança
---@param src number
---@param netId number
---@param plate string|nil
---@param modelClass number|nil
---@return table { ok: boolean, err?: string, minDurationMs?: number }
function TrackerManager.StartRemoval(src, netId, plate, modelClass)
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

    local trk = TrackerManager.Resolve(netId, plate, modelClass)
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

    -- Validação de distância física (se entidade existir no mundo)
    if NetworkGetEntityFromNetworkId and DoesEntityExist and GetPlayerPed and GetEntityCoords then
        local ent = NetworkGetEntityFromNetworkId(netId)
        if ent and DoesEntityExist(ent) then
            local ped = GetPlayerPed(src)
            local pCoords = GetEntityCoords(ped)
            local vCoords = GetEntityCoords(ent)
            local maxDist = cfg.MaxDistance or 3.5
            if #(pCoords - vCoords) > (maxDist + 1.0) then
                return { ok = false, err = 'distance' }
            end
        end
    end

    _activeRemovals[src] = {
        vsid = trk.vsid,
        netId = netId,
        plate = plate,
        startTime = nowMs(),
    }

    return {
        ok = true,
        minDurationMs = cfg.MinDurationMs or 7000,
    }
end

--- Finaliza a remoção do rastreador validando tempo e estado do servidor
---@param src number
---@param netId number
---@param plate string|nil
---@return table { ok: boolean, err?: string }
function TrackerManager.CompleteRemoval(src, netId, plate)
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
    _activeRemovals[src] = nil

    if session.netId ~= netId then
        return { ok = false, err = 'vehicle_mismatch' }
    end

    local elapsed = nowMs() - session.startTime
    local minDur = (cfg.MinDurationMs or 7000) - 500 -- margem de latência de 500ms
    if elapsed < minDur then
        return { ok = false, err = 'too_fast' }
    end

    local trk = _trackers[session.vsid]
    if not trk or trk.state ~= 'ACTIVE' then
        return { ok = false, err = 'not_active' }
    end

    -- Revalidação de ferramenta
    if cfg.RequiredTool and type(InvCount) == 'function' then
        local hasPrimary = InvCount(src, cfg.RequiredTool) > 0
        local hasFallback = cfg.ToolFallback and (InvCount(src, cfg.ToolFallback) > 0)
        if not hasPrimary and not hasFallback then
            return { ok = false, err = 'no_tool' }
        end
    end

    -- Transição de estado autoritativa
    trk.state = 'REMOVED'
    trk.hasTracker = false

    -- Plant defensivo de evidência forense (digital/DNA)
    if cfg.RemovalEvidence and type(VPChopLeaveEvidence) == 'function' then
        local coords = vector3(0, 0, 0)
        if NetworkGetEntityFromNetworkId and DoesEntityExist and GetEntityCoords then
            local ent = NetworkGetEntityFromNetworkId(netId)
            if ent and DoesEntityExist(ent) then
                coords = GetEntityCoords(ent)
            end
        end
        VPChopLeaveEvidence(src, coords, 'vin_scratch', trk.plate)
    end

    return { ok = true }
end

--- Executa uma rodada do broadcast policial de pings para veículos ativos
---@return number pingsSent
function TrackerManager.BroadcastPings()
    local cfg = getTrackerConfig()
    if not cfg.Enable then return 0 end

    local now = nowMs()
    local intervalMs = (cfg.PingIntervalSeconds or 15) * 1000
    local pingsSent = 0

    for vsid, trk in pairs(_trackers) do
        if trk.state == 'ACTIVE' and (now - trk.lastPing >= intervalMs) then
            local ent = NetworkGetEntityFromNetworkId and NetworkGetEntityFromNetworkId(trk.netId)
            if ent and DoesEntityExist and DoesEntityExist(ent) and GetEntityCoords then
                trk.lastPing = now
                local coords = GetEntityCoords(ent)
                pingsSent = pingsSent + 1

                -- Broadcast para jogadores policiais conectados
                if TriggerClientEvent then
                    TriggerClientEvent('vp_chopshop:client:trackerPing', -1, coords, trk.plate, trk.modelClass)
                end
            end
        end
    end

    return pingsSent
end

-- ─── Callbacks de Integração ──────────────────────────────────────────────────
if lib and lib.callback and lib.callback.register then
    lib.callback.register('vp_chopshop:tracker:check', function(src, netId, plate, modelClass)
        local trk = TrackerManager.Resolve(netId, plate, modelClass)
        return {
            hasTracker = (trk.state == 'ACTIVE'),
            state = trk.state,
        }
    end)

    lib.callback.register('vp_chopshop:tracker:startRemoval', function(src, netId, plate, modelClass)
        return TrackerManager.StartRemoval(src, netId, plate, modelClass)
    end)

    lib.callback.register('vp_chopshop:tracker:completeRemoval', function(src, netId, plate)
        return TrackerManager.CompleteRemoval(src, netId, plate)
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
        _activeRemovals = {}
        _mockNow = nil
    end,
}
