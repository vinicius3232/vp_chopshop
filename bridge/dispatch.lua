-- bridge/dispatch.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.3] DispatchBridge — Multi-Framework Police Dispatch Bridge
--  Conector modular para despacho de alertas policiais.
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

--- Registra um provedor de dispatch customizado
---@param name string           identificador do provider (ex: 'custom' ou nome do resource)
---@param resourceName string   nome do resource chamador
---@param handler function      função que processa o alerta (alertData)
---@return boolean success, string|nil err
function DispatchBridge.RegisterProvider(name, resourceName, handler)
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

    -- Resolução de coordenadas: prefere coordenadas do veículo se válido, depois coords passadas, depois ped coords
    local pos = alert.coords
    if (not pos or type(pos.x) ~= 'number') and veh and DoesEntityExist and DoesEntityExist(veh) and GetEntityCoords then
        pos = GetEntityCoords(veh)
    end
    if (not pos or type(pos.x) ~= 'number') and GetPlayerPed and GetEntityCoords then
        local ped = GetPlayerPed(-1)
        if ped and ped ~= 0 then
            pos = GetEntityCoords(ped)
        end
    end
    pos = pos or { x = 0.0, y = 0.0, z = 0.0 }

    local title   = alert.title or cfg.DefaultTitle or '10-90 - Desmanche Ilegal'
    local message = alert.message or cfg.DefaultMessage or 'Notícia de atividade de desmanche de veículo em andamento.'
    local code    = alert.code or cfg.DefaultCode or '10-90'
    local jobs    = cfg.Jobs or { 'police', 'sheriff', 'bcso' }
    local blip    = cfg.Blip or { sprite = 530, scale = 1.0, color = 1, flashes = false, text = '911 - Desmanche', time = 5, radius = 0 }

    local plate = alert.plate
    if (not plate or plate == '') and veh and GetVehicleNumberPlateText and DoesEntityExist and DoesEntityExist(veh) then
        plate = GetVehicleNumberPlateText(veh)
    end

    local alertPayload = {
        veh = veh,
        coords = pos,
        title = title,
        message = message,
        code = code,
        type = alert.type or 'chopshop',
        plate = plate,
        model = alert.model,
        jobs = jobs,
        blip = blip,
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
            if exports and exports['ps-dispatch'] then
                if exports['ps-dispatch'].CustomAlert then
                    exports['ps-dispatch']:CustomAlert({
                        coords = pos,
                        message = message,
                        dispatchCode = code,
                        description = title,
                        radius = blip.radius or 0,
                        sprite = blip.sprite or 530,
                        color = blip.color or 1,
                        scale = blip.scale or 1.0,
                        length = blip.time or 5,
                        recipientList = jobs,
                    })
                    success = true
                elseif exports['ps-dispatch'].SuspiciousActivity then
                    exports['ps-dispatch']:SuspiciousActivity()
                    success = true
                end
            end
        elseif provider == 'cd_dispatch' then
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
                        color = blip.color or 1,
                        flashes = blip.flashes or false,
                        text = blip.text or title,
                        time = blip.time or 5,
                        radius = blip.radius or 0,
                    },
                }
                TriggerServerEvent('cd_dispatch:AddNotification', dataCd)
                success = true
            end
        elseif provider == 'qs-dispatch' then
            if TriggerServerEvent then
                local dataQs = {
                    job = jobs,
                    callLocation = pos,
                    callCode = { code = code, snippet = title },
                    message = message,
                    flasher = true,
                    blip = {
                        sprite = blip.sprite or 530,
                        scale = blip.scale or 1.0,
                        colour = blip.color or 1,
                        flashes = blip.flashes or false,
                        text = blip.text or title,
                        time = (blip.time or 5) * 60 * 1000,
                    },
                }
                TriggerServerEvent('qs-dispatch:server:CreateDispatchCall', dataQs)
                success = true
            end
        elseif provider == 'op-dispatch' then
            if exports and exports['op-dispatch'] and exports['op-dispatch'].SendAlert then
                exports['op-dispatch']:SendAlert({
                    coords = pos,
                    title = title,
                    message = message,
                    code = code,
                    jobs = jobs,
                    blip = blip,
                })
                success = true
            end
        elseif provider == 'core_dispatch' then
            if exports and exports['core_dispatch'] and exports['core_dispatch'].addCall then
                exports['core_dispatch']:addCall(code, title, {{ icon = 'fa-car', info = message }}, pos, jobs, (blip.time or 5) * 1000, blip.sprite or 530, blip.color or 1)
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
