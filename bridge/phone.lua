-- bridge/phone.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.20 P6.3] PhoneBridge — Multi-Smartphone Integration Bridge
--  Conector modular e desacoplado para notificações e mensagens em smartphones.
--  Suporta: lb-phone, qs-smartphone, yphone, gksphone, npwd, custom, none.
-- ═══════════════════════════════════════════════════════════════════════════════

PhoneBridge = PhoneBridge or {}

local _mock = nil
local _customHandler = nil

local PHONE_RESOURCES = {
    'lb-phone',
    'qs-smartphone',
    'yphone',
    'gksphone',
    'npwd',
}

--- Retorna a configuração de telefone sanitizada
---@return table
local function getPhoneConfig()
    local cfg = Config and Config.Phone
    if type(cfg) ~= 'table' then
        return {
            Enable = true,
            Provider = 'auto',
            Sender = 'Informante Anônimo',
            DefaultSubject = 'Alerta de Atividade Clandestina',
        }
    end
    return cfg
end

--- Detecta o provedor de smartphone ativo no servidor
---@return string providerName
function PhoneBridge.GetProvider()
    if _mock and _mock.provider then
        return _mock.provider
    end

    local cfg = getPhoneConfig()
    if cfg.Enable == false then
        return 'none'
    end

    local configured = cfg.Provider or 'auto'
    if configured ~= 'auto' then
        if configured == 'custom' or configured == 'none' then
            return configured
        end
        if GetResourceState and GetResourceState(configured) == 'started' then
            return configured
        end
        return 'none'
    end

    if not GetResourceState then
        return 'none'
    end

    for _, res in ipairs(PHONE_RESOURCES) do
        if GetResourceState(res) == 'started' then
            return res
        end
    end

    return 'none'
end

--- Verifica se há algum sistema de smartphone disponível
---@return boolean
function PhoneBridge.IsAvailable()
    local prov = PhoneBridge.GetProvider()
    return prov ~= 'none'
end

--- Envia uma notificação/alerta para o smartphone de um jogador
---@param src number
---@param title string
---@param message string
---@param opts? table { icon?: string, app?: string, duration?: number }
---@return boolean ok, string? err
function PhoneBridge.SendNotification(src, title, message, opts)
    if not src or type(src) ~= 'number' or src <= 0 then
        return false, 'invalid_source'
    end

    if _mock and _mock.SendNotification then
        return _mock.SendNotification(src, title, message, opts)
    end

    local prov = PhoneBridge.GetProvider()
    if prov == 'none' then
        return false, 'phone_unavailable'
    end

    opts = opts or {}
    local senderTitle = title or getPhoneConfig().Sender or 'Notificação'

    local ok, err = pcall(function()
        if prov == 'lb-phone' then
            if exports and exports['lb-phone'] and type(exports['lb-phone'].SendNotification) == 'function' then
                exports['lb-phone']:SendNotification(src, {
                    title = senderTitle,
                    content = message,
                    icon = opts.icon or 'bell',
                    duration = opts.duration or 5000,
                })
            else
                TriggerClientEvent('lb-phone:notification', src, {
                    title = senderTitle,
                    content = message,
                })
            end
        elseif prov == 'qs-smartphone' then
            if exports and exports['qs-smartphone'] and type(exports['qs-smartphone'].SendNotification) == 'function' then
                exports['qs-smartphone']:SendNotification(src, {
                    title = senderTitle,
                    text = message,
                    icon = opts.icon or 'fas fa-exclamation-triangle',
                    timeout = opts.duration or 5000,
                })
            else
                TriggerClientEvent('qs-smartphone:client:notify', src, {
                    title = senderTitle,
                    text = message,
                })
            end
        elseif prov == 'yphone' then
            if exports and exports['yphone'] and type(exports['yphone'].sendNotification) == 'function' then
                exports['yphone']:sendNotification(src, {
                    title = senderTitle,
                    message = message,
                })
            else
                TriggerClientEvent('yphone:notify', src, senderTitle, message)
            end
        elseif prov == 'gksphone' then
            if exports and exports['gksphone'] and type(exports['gksphone'].SendNotification) == 'function' then
                exports['gksphone']:SendNotification(src, {
                    title = senderTitle,
                    message = message,
                })
            else
                TriggerClientEvent('gksphone:notif', src, {
                    title = senderTitle,
                    message = message,
                })
            end
        elseif prov == 'npwd' then
            if exports and exports['npwd'] and type(exports['npwd'].sendNotification) == 'function' then
                exports['npwd']:sendNotification(src, {
                    title = senderTitle,
                    message = message,
                })
            end
        elseif prov == 'custom' then
            if _customHandler then
                _customHandler(src, senderTitle, message, opts)
            else
                local customExp = Config and Config.Phone and Config.Phone.CustomExport
                if customExp and exports and exports[customExp.resource] and exports[customExp.resource][customExp.method] then
                    exports[customExp.resource][customExp.method](exports[customExp.resource], src, senderTitle, message, opts)
                end
            end
        end
    end)

    return ok, (not ok and tostring(err) or nil)
end

--- Envia uma notificação para uma lista de fontes de jogadores
---@param srcList number[]
---@param title string
---@param message string
---@param opts? table
---@return number sentCount
function PhoneBridge.SendNotificationToPlayers(srcList, title, message, opts)
    if type(srcList) ~= 'table' or #srcList == 0 then return 0 end
    local count = 0
    for _, src in ipairs(srcList) do
        local ok = PhoneBridge.SendNotification(src, title, message, opts)
        if ok then count = count + 1 end
    end
    return count
end

--- Registra um conector customizado em runtime para scripts proprietários
---@param handler function(src:number, title:string, message:string, opts:table)
function PhoneBridge.RegisterCustomHandler(handler)
    if type(handler) == 'function' then
        _customHandler = handler
    end
end

--- Test seam para testes unitários isolados
---@param mock table|nil
function PhoneBridge.__setMock(mock)
    _mock = mock
end

return PhoneBridge
