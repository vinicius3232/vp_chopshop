-- bridge/dispatch.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.3 / P4.3.1] DispatchBridge — Multi-Framework Police Dispatch Bridge
--  Conector modular e desacoplado para despacho de alertas policiais client-side.
--  Suporta: ps-dispatch, cd_dispatch, qs-dispatch, op-dispatch, core_dispatch, custom, none.
-- ═══════════════════════════════════════════════════════════════════════════════

DispatchBridge = DispatchBridge or {}

local _customProviders = {}
local _mockHandler = nil
local _mockProvider = nil
local _lastAlert = nil

--- Retorna a configuração de dispatch sanitizada
---@return table
local function getDispatchConfig()
    local cfg = Config and Config.Dispatch
    if type(cfg) ~= 'table' then
        return {
            Enable = true,
            Provider = 'auto',
            AutoOrder = { 'ps-dispatch', 'cd_dispatch', 'qs-dispatch', 'op-dispatch', 'core_dispatch' },
            Jobs = { 'police', 'sheriff', 'bcso' },
            DefaultCode = '10-90',
            DefaultTitle = '10-90 - Desmanche Ilegal',
            DefaultMessage = 'Notícia de atividade de desmanche de veículo em andamento.',
            Blip = { sprite = 530, scale = 1.0, color = 1, flashes = false, text = '911 - Desmanche', time = 5, radius = 0 },
        }
    end
    return cfg
end

--- [P4.3.1] Sanitiza e resolve a duração do blip em minutos canônicos (0.1 a 60.0 min)
---@param rawTime any
---@return number minutes
function DispatchBridge.ResolveBlipDuration(rawTime)
    local t = tonumber(rawTime)
    if not t or t ~= t or t == math.huge or t == -math.huge or t <= 0 then
        return 5.0
    end
    return math.max(0.1, math.min(60.0, t))
end

--- [P4.3.1] Resolve de forma determinística o codeName de identidade do alerta (para ps-dispatch)
---@param alertType string|nil
---@return string codeName
function DispatchBridge.ResolveCodeName(alertType)
    if not alertType or type(alertType) ~= 'string' or alertType == '' or alertType == 'chopshop' then
        return 'vp_chopshop'
    end
    return 'vp_chopshop_' .. tostring(alertType):lower()
end

--- [P4.3.1] Resolve a autoridade de coordenadas: 1. Veículo válido, 2. Coords manuais válidas, 3. Ped, 4. Fallback zero
---@param alert table|nil
---@return table|vector3 coords
function DispatchBridge.ResolveCoords(alert)
    if type(alert) ~= 'table' then
        return { x = 0.0, y = 0.0, z = 0.0 }
    end

    local veh = alert.veh
    -- 1. Veículo válido possui autoridade máxima (preserva cena do crime mesmo se player fugir)
    if veh and DoesEntityExist and DoesEntityExist(veh) and GetEntityCoords then
        local okCoords, vCoords = pcall(GetEntityCoords, veh)
        if okCoords and vCoords and type(vCoords.x) == 'number' and vCoords.x == vCoords.x and vCoords.x ~= math.huge and vCoords.x ~= -math.huge then
            return vCoords
        end
    end

    -- 2. Coordenadas explícitas passadas no payload
    local pos = alert.coords
    if pos and type(pos) == 'table' and type(pos.x) == 'number' and type(pos.y) == 'number' and type(pos.z) == 'number' then
        if pos.x == pos.x and pos.y == pos.y and pos.z == pos.z and
           pos.x ~= math.huge and pos.x ~= -math.huge and
           pos.y ~= math.huge and pos.y ~= -math.huge and
           pos.z ~= math.huge and pos.z ~= -math.huge then
            return pos
        end
    end

    -- 3. Posição atual do jogador
    if GetPlayerPed and GetEntityCoords then
        local ped = (PlayerPedId and PlayerPedId()) or GetPlayerPed(-1)
        if ped and ped ~= 0 and DoesEntityExist and DoesEntityExist(ped) then
            local okPed, pCoords = pcall(GetEntityCoords, ped)
            if okPed and pCoords and type(pCoords.x) == 'number' and pCoords.x == pCoords.x then
                return pCoords
            end
        end
    end

    -- 4. Fallback seguro
    return { x = 0.0, y = 0.0, z = 0.0 }
end

--- Registra um provedor de dispatch customizado (apenas client-side)
---@param name string           identificador do provider (ex: 'custom' ou nome do resource)
---@param resourceName string   nome do resource chamador
---@param handler function      função que processa o alerta (alertData)
---@return boolean success, string|nil err
function DispatchBridge.RegisterProvider(name, resourceName, handler)
    -- [P4.3.1] Context boundary: alertas são despachados no client. Servidor rejeita wrong_context.
    if IsDuplicityVersion and IsDuplicityVersion() then
        return false, 'wrong_context'
    end

    if type(name) ~= 'string' or name == '' then
        return false, 'invalid_name'
    end
    if type(handler) ~= 'function' then
        return false, 'invalid_handler'
    end

    local invoking = (GetInvokingResource and GetInvokingResource()) or resourceName or 'vp_chopshop'
    if resourceName and invoking ~= resourceName and invoking ~= 'vp_chopshop' then
        return false, 'resource_mismatch'
    end

    if _customProviders[name] and _customProviders[name].resource ~= invoking then
        return false, 'already_registered'
    end

    _customProviders[name] = {
        resource = invoking,
        handler = handler,
    }
    return true
end

--- Export para registro de provider custom
if exports then
    exports('RegisterDispatchProvider', function(name, resourceName, handler)
        return DispatchBridge.RegisterProvider(name, resourceName, handler)
    end)
end

--- Resolve o provedor de dispatch ativo de forma segura
---@return string provider ('ps-dispatch' | 'cd_dispatch' | 'qs-dispatch' | 'op-dispatch' | 'core_dispatch' | 'custom' | 'none')
function DispatchBridge.GetProvider()
    if _mockProvider then return _mockProvider end

    local cfg = getDispatchConfig()
    if not cfg.Enable then return 'none' end

    -- Suporte retrocompatível a Config.Dispatch.System ou Config.Dispatch.Provider
    local explicit = cfg.Provider or cfg.System
    if explicit and explicit ~= 'auto' then
        if explicit == 'none' then return 'none' end
        if explicit == 'custom' then
            return (_customProviders['custom'] and 'custom') or 'none'
        end
        if explicit == 'ps-dispatch' or explicit == 'cd_dispatch' or explicit == 'qs-dispatch' or explicit == 'op-dispatch' or explicit == 'core_dispatch' then
            if GetResourceState and GetResourceState(explicit) == 'started' then
                return explicit
            end
            return 'none'
        end
        -- Provider desconhecido -> fallback fail-soft
        return 'none'
    end

    -- Modo 'auto': probing ordenado conforme Config.Dispatch.AutoOrder
    local order = cfg.AutoOrder or { 'ps-dispatch', 'cd_dispatch', 'qs-dispatch', 'op-dispatch', 'core_dispatch' }
    for _, provName in ipairs(order) do
        if provName == 'custom' and _customProviders['custom'] then
            return 'custom'
        elseif GetResourceState and GetResourceState(provName) == 'started' then
            return provName
        end
    end

    return 'none'
end

--- Informa se há um provedor de dispatch ativo e disponível
---@return boolean
function DispatchBridge.IsAvailable()
    return DispatchBridge.GetProvider() ~= 'none'
end

--- Envia alerta policial via provider ativo de forma segura (fail-soft)
---@param data table|nil Dados do alerta { veh, coords, title, message, code, type, plate, model }
---@return boolean success, string provider
function DispatchBridge.SendAlert(data)
    local cfg = getDispatchConfig()
    if not cfg.Enable then return false, 'disabled' end

    local provider = DispatchBridge.GetProvider()
    if provider == 'none' then return false, 'none' end

    local alert = data or {}
    local veh = alert.veh

    -- Resolução de coordenadas com autoridade hierárquica
    local pos = DispatchBridge.ResolveCoords(alert)

    local title   = alert.title or cfg.DefaultTitle or '10-90 - Desmanche Ilegal'
    local message = alert.message or cfg.DefaultMessage or 'Notícia de atividade de desmanche de veículo em andamento.'
    local code    = alert.code or cfg.DefaultCode or '10-90'
    local jobs    = cfg.Jobs or { 'police', 'sheriff', 'bcso' }
    local blip    = cfg.Blip or { sprite = 530, scale = 1.0, color = 1, flashes = false, text = '911 - Desmanche', time = 5, radius = 0 }

    local plate = alert.plate
    if (not plate or plate == '') and veh and GetVehicleNumberPlateText and DoesEntityExist and DoesEntityExist(veh) then
        plate = GetVehicleNumberPlateText(veh)
    end

    local minutes = DispatchBridge.ResolveBlipDuration(blip.time)
    local codeName = DispatchBridge.ResolveCodeName(alert.type)

    local alertPayload = {
        veh = veh,
        coords = pos,
        title = title,
        message = message,
        code = code,
        codeName = codeName,
        type = alert.type or 'chopshop',
        plate = plate,
        model = alert.model,
        jobs = jobs,
        blip = blip,
        minutes = minutes,
    }

    _lastAlert = {
        provider = provider,
        data = alertPayload,
    }

    if _mockHandler then
        local okMock, resMock = pcall(_mockHandler, alertPayload)
        return (okMock and resMock ~= false), provider
    end

    local success = false
    pcall(function()
        if provider == 'ps-dispatch' then
            -- [UPSTREAM CONTRACT] Project-Sloth/ps-dispatch client/alerts.lua (CustomAlert)
            if exports and exports['ps-dispatch'] and exports['ps-dispatch'].CustomAlert then
                exports['ps-dispatch']:CustomAlert({
                    coords = pos,
                    dispatchCode = codeName,
                    code = code,
                    message = title,
                    information = message,
                    jobs = jobs,
                    recipientList = jobs,
                    plate = plate,
                    model = alert.model,
                    radius = blip.radius or 0,
                    sprite = blip.sprite or 530,
                    color = blip.color or blip.colour or 1,
                    scale = blip.scale or 1.0,
                    length = minutes,
                })
                success = true
            elseif exports and exports['ps-dispatch'] and exports['ps-dispatch'].SuspiciousActivity then
                exports['ps-dispatch']:SuspiciousActivity()
                success = true
            end
        elseif provider == 'cd_dispatch' then
            -- [UPSTREAM CONTRACT] cd_dispatch client notification
            if TriggerServerEvent then
                local dataCd = {
                    job_table = jobs,
                    coords = pos,
                    title = title,
                    message = message,
                    flash = 0,
                    sound = 1,
                    blip = {
                        sprite = blip.sprite or 530,
                        scale = blip.scale or 1.0,
                        colour = blip.color or blip.colour or 1,
                        color = blip.color or blip.colour or 1,
                        flashes = blip.flashes or false,
                        text = blip.text or title,
                        time = minutes,
                        radius = blip.radius or 0,
                    },
                }
                TriggerServerEvent('cd_dispatch:AddNotification', dataCd)
                success = true
            end
        elseif provider == 'qs-dispatch' then
            -- [UPSTREAM CONTRACT] qs-dispatch CreateDispatchCall
            if TriggerServerEvent then
                local dataQs = {
                    job = jobs,
                    callLocation = pos,
                    callCode = { code = code, snippet = title },
                    message = message,
                    flashes = (blip.flashes ~= false),
                    blip = {
                        sprite = blip.sprite or 530,
                        scale = blip.scale or 1.0,
                        colour = blip.color or blip.colour or 1,
                        color = blip.color or blip.colour or 1,
                        flashes = blip.flashes or false,
                        text = blip.text or title,
                        time = minutes * 60 * 1000,
                    },
                }
                TriggerServerEvent('qs-dispatch:server:CreateDispatchCall', dataQs)
                success = true
            end
        elseif provider == 'op-dispatch' then
            -- [UPSTREAM CONTRACT] ErrorMauw/op-dispatch: TriggerServerEvent 'Opto_dispatch:Server:SendAlert'
            if TriggerServerEvent and jobs and #jobs > 0 then
                local playerId = (GetPlayerServerId and PlayerId and GetPlayerServerId(PlayerId()))
                    or (GetPlayerServerId and GetPlayerServerId(-1))
                    or 1
                local anySent = false
                for _, job in ipairs(jobs) do
                    if type(job) == 'string' and job ~= '' then
                        TriggerServerEvent('Opto_dispatch:Server:SendAlert', job, title, message, pos, false, playerId)
                        anySent = true
                    end
                end
                success = anySent
            end
        elseif provider == 'core_dispatch' then
            -- [UPSTREAM CONTRACT] C8RE/core_dispatch client export: sendAlert
            if exports and exports['core_dispatch'] and exports['core_dispatch'].sendAlert then
                exports['core_dispatch']:sendAlert(
                    code,
                    title,
                    pos,
                    false,
                    jobs,
                    { { icon = 'fa-car', info = message } },
                    minutes * 60 * 1000,
                    blip.sprite or 530,
                    blip.color or blip.colour or 1
                )
                success = true
            end
        elseif provider == 'custom' then
            local prov = _customProviders['custom']
            if prov and prov.handler then
                local okCustom, resCustom = pcall(prov.handler, alertPayload)
                if okCustom and resCustom ~= false then
                    success = true
                end
            end
        end
    end)

    return success, provider
end

-- ─── Test Seam ───────────────────────────────────────────────────────────────
DispatchBridge._test = {
    setProvider = function(name, handler)
        _mockProvider = name
        _mockHandler = handler
    end,
    getLastAlert = function()
        return _lastAlert
    end,
    getCustomProviders = function()
        return _customProviders
    end,
    reset = function()
        _mockProvider = nil
        _mockHandler = nil
        _lastAlert = nil
        _customProviders = {}
    end,
}
