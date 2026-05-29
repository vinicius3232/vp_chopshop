-- Framework bridge: suporta QBox (qbx_core) e ESX Legacy.
-- Detecção automática na inicialização; fallback seguro se nenhum estiver disponível.

local _framework = nil  -- 'qbox' | 'esx' | nil

-- ─── QBox (qbx_core) ─────────────────────────────────────────────────────────
local _QBX = nil

-- ─── ESX ─────────────────────────────────────────────────────────────────────
local _ESX = nil

CreateThread(function()
    if GetResourceState('qbx_core') == 'started' then
        -- qbx_core expõe exports diretos; não usa SharedObject.
        _framework = 'qbox'
        _QBX = exports.qbx_core
    elseif GetResourceState('es_extended') == 'started' then
        _framework = 'esx'
        _ESX = exports['es_extended']:getSharedObject()
    end
end)

-- ─── IsValidSource: guard de segurança para todos os RegisterNetEvent ─────────
---@param src number
---@return boolean
function IsValidSource(src)
    return src ~= nil
        and type(src) == 'number'
        and src > 0
        and src ~= 65535
        and GetPlayerName(src) ~= nil
end

--- Log de atividade suspeita no console (e Discord se configurado).
---@param src number
---@param action string
---@param details string
function LogSuspicious(src, action, details)
    local name = GetPlayerName(src) or 'Unknown'
    local identifiers = {}
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        identifiers[#identifiers + 1] = GetPlayerIdentifier(src, i) or ''
    end
    print(('[vp_chopshop] [SECURITY] SUSPEITO | %s (src:%s) | %s | %s | ids: %s'):format(
        name, tostring(src), action, details, table.concat(identifiers, ', ')
    ))
    -- Webhook opcional: reutiliza VPChopDiscordLog se disponível (carregado depois)
    -- O pcall evita crash se discord.lua ainda não estiver carregado.
    pcall(function()
        if VPChopDiscordLog then
            VPChopDiscordLog('[SECURITY] ' .. action,
                ('**Player:** %s (src %d)\n**Detalhes:** %s\n**IDs:** %s'):format(
                    name, src, details, table.concat(identifiers, '\n')
                )
            )
        end
    end)
end

---@param src number
---@return boolean
function ServerPlayerIsReady(src)
    if not IsValidSource(src) then return false end
    if _framework == 'qbox' and _QBX then
        -- qbx_core: GetPlayer retorna nil se jogador não estiver carregado
        local ok, player = pcall(function() return _QBX:GetPlayer(src) end)
        return ok and player ~= nil
    elseif _framework == 'esx' and _ESX then
        return _ESX.GetPlayerFromId(src) ~= nil
    end
    -- Fallback: fonte válida e nome existem (mínimo seguro sem framework)
    return true
end

--- Identificador estável por jogador (usado para cooldowns e DB keys).
--- Não é segredo — não usar para crypto.
---@param src number
---@return string
function ServerChopPlayerKey(src)
    if _framework == 'qbox' and _QBX then
        local ok, player = pcall(function() return _QBX:GetPlayer(src) end)
        if ok and player then
            -- qbx_core: player.citizenid é o identificador principal
            local cid = player.citizenid or player.PlayerData and player.PlayerData.citizenid
            if cid then return 'qbx:' .. tostring(cid) end
        end
    elseif _framework == 'esx' and _ESX then
        local x = _ESX.GetPlayerFromId(src)
        if x and x.identifier then
            return 'esx:' .. tostring(x.identifier)
        end
    end
    -- Fallback estável (source ID — muda ao reconectar, mas preferível a crash)
    return 'src:' .. tostring(src)
end

--- Dinheiro em cash do jogador (para loja do NPC). Retorna 0 se não suportado.
---@param src number
---@return integer
function BridgeGetCash(src)
    if _framework == 'qbox' and _QBX then
        local ok, player = pcall(function() return _QBX:GetPlayer(src) end)
        if ok and player then
            local money = player.PlayerData and player.PlayerData.money and player.PlayerData.money.cash
            return math.floor(tonumber(money) or 0)
        end
        return 0
    elseif _framework == 'esx' and _ESX then
        local x = _ESX.GetPlayerFromId(src)
        if not x then return 0 end
        local acc = x.getAccount('money')
        return acc and math.floor(tonumber(acc.money) or 0) or 0
    end
    return 0
end

---@param src number
---@param amount integer
---@param reason? string
---@return boolean
function BridgeRemoveCash(src, amount, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 then return true end
    if _framework == 'qbox' and _QBX then
        local ok, result = pcall(function()
            return _QBX:RemoveMoney(src, 'cash', amount, reason or 'vp_chopshop')
        end)
        return ok and result == true
    elseif _framework == 'esx' and _ESX then
        local x = _ESX.GetPlayerFromId(src)
        if not x then return false end
        local acc = x.getAccount('money')
        if acc and (tonumber(acc.money) or 0) >= amount then
            x.removeAccountMoney('money', amount)
            return true
        end
        return false
    end
    return false
end

--- Conta jogadores online com jobs de polícia (para bónus de discard).
---@return integer
function BridgeCountCops()
    local policeJobs = (Config.Discard and Config.Discard.CopsBonus and Config.Discard.CopsBonus.PoliceJobs)
        or { 'police', 'sheriff', 'bcso' }
    local jobSet = {}
    for _, j in ipairs(policeJobs) do jobSet[j] = true end
    local count = 0
    if _framework == 'qbox' and _QBX then
        local ok, players = pcall(function() return _QBX:GetQBPlayers() end)
        if ok and players then
            for _, player in pairs(players) do
                local job = player.PlayerData and player.PlayerData.job and player.PlayerData.job.name
                if job and jobSet[job] then count = count + 1 end
            end
        end
    elseif _framework == 'esx' and _ESX then
        for _, pid in ipairs(_ESX.GetPlayers()) do
            local xPlayer = _ESX.GetPlayerFromId(pid)
            local job = xPlayer and xPlayer.job and xPlayer.job.name
            if job and jobSet[job] then count = count + 1 end
        end
    end
    return count
end

---@param src number
---@param amount integer
---@param reason? string
---@return boolean
function BridgeAddCash(src, amount, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 then return true end
    if _framework == 'qbox' and _QBX then
        local ok, result = pcall(function()
            return _QBX:AddMoney(src, 'cash', amount, reason or 'vp_chopshop')
        end)
        return ok and result ~= false
    elseif _framework == 'esx' and _ESX then
        local x = _ESX.GetPlayerFromId(src)
        if not x then return false end
        x.addAccountMoney('money', amount)
        return true
    end
    return false
end
