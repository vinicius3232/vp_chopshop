Framework = 'none'

if GetResourceState('qbx_core') == 'started' then
    Framework = 'qbx'
elseif GetResourceState('qb-core') == 'started' then
    Framework = 'qb'
elseif GetResourceState('es_extended') == 'started' then
    Framework = 'esx'
end

---@param src number
---@return boolean
function ServerPlayerIsReady(src)
    if Framework == 'qbx' then
        return exports.qbx_core:GetPlayer(src) ~= nil
    end
    if Framework == 'qb' then
        local QBCore = exports['qb-core']:GetCoreObject()
        return QBCore.Functions.GetPlayer(src) ~= nil
    end
    if Framework == 'esx' then
        local ESX = exports['es_extended']:getSharedObject()
        return ESX.GetPlayerFromId(src) ~= nil
    end
    return true
end

--- Stable id for per-player limits (e.g. chop cooldown). Not secret — do not use for crypto.
---@param src number
---@return string
function ServerChopPlayerKey(src)
    if Framework == 'qbx' then
        local p = exports.qbx_core:GetPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid then
            return 'cid:' .. tostring(p.PlayerData.citizenid)
        end
    elseif Framework == 'qb' then
        local QBCore = exports['qb-core']:GetCoreObject()
        local p = QBCore.Functions.GetPlayer(src)
        if p and p.PlayerData and p.PlayerData.citizenid then
            return 'cid:' .. tostring(p.PlayerData.citizenid)
        end
    elseif Framework == 'esx' then
        local ESX = exports['es_extended']:getSharedObject()
        local x = ESX.Player(src)  -- [H3 FIX] GetPlayerFromId deprecado → ESX.Player()
        if x and x.identifier then
            return 'esx:' .. tostring(x.identifier)
        end
    end
    return 'src:' .. tostring(src)
end

--- Cash on hand (for NPC shop). Returns 0 if unsupported.
---@param src number
---@return integer
function BridgeGetCash(src)
    if Framework == 'qbx' then
        -- [H2 FIX] Player.Functions.GetMoney shim deprecado → exports.qbx_core:GetMoney
        local n = exports.qbx_core:GetMoney(src, 'cash')
        return math.floor(tonumber(n) or 0)
    elseif Framework == 'qb' then
        local QBCore = exports['qb-core']:GetCoreObject()
        local p = QBCore.Functions.GetPlayer(src)
        if p then return math.floor(p.Functions.GetMoney('cash') or 0) end
    elseif Framework == 'esx' then
        local ESX = exports['es_extended']:getSharedObject()
        local x = ESX.Player(src)  -- [H3 FIX] GetPlayerFromId deprecado → ESX.Player()
        if x then return math.floor(x.getAccount('money').money or 0) end
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
    local label = reason or 'vp_chopshop'
    if Framework == 'qbx' then
        -- [H2 FIX] Player.Functions.RemoveMoney shim deprecado → exports.qbx_core:RemoveMoney
        return exports.qbx_core:RemoveMoney(src, 'cash', amount, label) == true
    elseif Framework == 'qb' then
        local QBCore = exports['qb-core']:GetCoreObject()
        local p = QBCore.Functions.GetPlayer(src)
        if p and p.Functions.RemoveMoney('cash', amount, label) then return true end
    elseif Framework == 'esx' then
        local ESX = exports['es_extended']:getSharedObject()
        local x = ESX.Player(src)  -- [H3 FIX] GetPlayerFromId deprecado → ESX.Player()
        if x and x.getAccount('money').money >= amount then
            x.removeAccountMoney('money', amount, label)
            return true
        end
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
    if Framework == 'qbx' then
        for _, p in pairs(exports.qbx_core:GetQBPlayers()) do
            local job = p.PlayerData and p.PlayerData.job and p.PlayerData.job.name
            if job and jobSet[job] then count = count + 1 end
        end
    elseif Framework == 'qb' then
        local QBCore = exports['qb-core']:GetCoreObject()
        for _, p in pairs(QBCore.Functions.GetQBPlayers()) do
            local job = p.PlayerData and p.PlayerData.job and p.PlayerData.job.name
            if job and jobSet[job] then count = count + 1 end
        end
    elseif Framework == 'esx' then
        local ESX = exports['es_extended']:getSharedObject()
        for _, xPlayer in pairs(ESX.ExtendedPlayers()) do
            local job = xPlayer.getJob and xPlayer.getJob().name
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
    local label = reason or 'vp_chopshop'
    if Framework == 'qbx' then
        -- [H2 FIX] Player.Functions.AddMoney shim deprecado → exports.qbx_core:AddMoney
        return exports.qbx_core:AddMoney(src, 'cash', amount, label) == true
    elseif Framework == 'qb' then
        local QBCore = exports['qb-core']:GetCoreObject()
        local p = QBCore.Functions.GetPlayer(src)
        if p and p.Functions.AddMoney('cash', amount, label) then return true end
    elseif Framework == 'esx' then
        local ESX = exports['es_extended']:getSharedObject()
        local x = ESX.Player(src)  -- [H3 FIX] GetPlayerFromId deprecado → ESX.Player()
        if x then
            x.addAccountMoney('money', amount, label)
            return true
        end
    end
    return false
end
