-- Framework bridge: suporta QBox (qbx_core), QBCore (qb-core) e ESX Legacy.
-- Detecção automática na inicialização; fallback seguro se nenhum estiver disponível.

local _framework = nil  -- 'qbox' | 'qbcore' | 'esx' | nil

-- ─── QBox (qbx_core) ─────────────────────────────────────────────────────────
local _QBX = nil

-- ─── [F1 qbcore] QBCore (qb-core) ────────────────────────────────────────────
-- PORTABILIDADE não-testada neste servidor (qb-core NÃO está instalado aqui —
-- servidor LIVE é QBox). Assinaturas baseadas no qb-core padrão:
--   _QB.Functions.GetPlayer(src) → Player (nil se não carregado)
--   Player.PlayerData.job.name, Player.PlayerData.money.cash, Player.PlayerData.citizenid
--   Player.Functions.AddMoney('cash', n) / RemoveMoney('cash', n)
--   _QB.Functions.GetQBPlayers() → table de Players online
local _QB = nil

-- ─── ESX ─────────────────────────────────────────────────────────────────────
local _ESX = nil

CreateThread(function()
    -- Detecção por ordem de prioridade (QBox primeiro: é o framework LIVE deste servidor).
    if GetResourceState('qbx_core') == 'started' then
        -- qbx_core expõe exports diretos; não usa SharedObject.
        _framework = 'qbox'
        _QBX = exports.qbx_core
    elseif GetResourceState('qb-core') == 'started' then
        -- [F1 qbcore] qb-core usa GetCoreObject (SharedObject clássico).
        _framework = 'qbcore'
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        if ok then _QB = core else _framework = nil end  -- fallback seguro se export falhar
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
    elseif _framework == 'qbcore' and _QB then
        -- [F1 qbcore] qb-core: GetPlayer retorna nil se não carregado (PORTABILIDADE não-testada)
        local ok, player = pcall(function() return _QB.Functions.GetPlayer(src) end)
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
    elseif _framework == 'qbcore' and _QB then
        -- [F1 qbcore] citizenid em PlayerData.citizenid (PORTABILIDADE não-testada)
        local ok, player = pcall(function() return _QB.Functions.GetPlayer(src) end)
        if ok and player then
            local cid = player.PlayerData and player.PlayerData.citizenid
            if cid then return 'qbx:' .. tostring(cid) end  -- prefixo 'qbx:' p/ compat de keys já gravadas
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
    elseif _framework == 'qbcore' and _QB then
        -- [F1 qbcore] cash em PlayerData.money.cash (mesma estrutura do qbx) — PORTABILIDADE
        local ok, player = pcall(function() return _QB.Functions.GetPlayer(src) end)
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
    elseif _framework == 'qbcore' and _QB then
        -- [F1 qbcore] Player.Functions.RemoveMoney('cash', n[, reason]) → boolean (PORTABILIDADE)
        local ok, result = pcall(function()
            local player = _QB.Functions.GetPlayer(src)
            if not player then return false end
            return player.Functions.RemoveMoney('cash', amount, reason or 'vp_chopshop')
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

--- [FASE2 placas] Nome do job atual do jogador (para gate policial na remoção).
--- Retorna '' se indisponível. Espelha a leitura de job já usada em BridgeCountCops.
---@param src number
---@return string jobName
function BridgeGetJob(src)
    if _framework == 'qbox' and _QBX then
        local ok, player = pcall(function() return _QBX:GetPlayer(src) end)
        if ok and player then
            local job = player.PlayerData and player.PlayerData.job and player.PlayerData.job.name
            return job or ''
        end
        return ''
    elseif _framework == 'qbcore' and _QB then
        -- [F1 qbcore] job em PlayerData.job.name (PORTABILIDADE não-testada)
        local ok, player = pcall(function() return _QB.Functions.GetPlayer(src) end)
        if ok and player then
            local job = player.PlayerData and player.PlayerData.job and player.PlayerData.job.name
            return job or ''
        end
        return ''
    elseif _framework == 'esx' and _ESX then
        local x = _ESX.GetPlayerFromId(src)
        local job = x and x.job and x.job.name
        return job or ''
    end
    return ''
end

--- [FASE2 placas] true se o job do jogador está na lista de jobs policiais informada.
---@param src number
---@param jobs string[]
---@return boolean
function BridgeIsPolice(src, jobs)
    local job = BridgeGetJob(src)
    if job == '' then return false end
    for i = 1, #jobs do
        if jobs[i] == job then return true end
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
    elseif _framework == 'qbcore' and _QB then
        -- [F1 qbcore] GetQBPlayers() → table de Players online (PORTABILIDADE não-testada)
        local ok, players = pcall(function() return _QB.Functions.GetQBPlayers() end)
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
    elseif _framework == 'qbcore' and _QB then
        -- [F1 qbcore] Player.Functions.AddMoney('cash', n[, reason]) (PORTABILIDADE não-testada)
        local ok, result = pcall(function()
            local player = _QB.Functions.GetPlayer(src)
            if not player then return false end
            return player.Functions.AddMoney('cash', amount, reason or 'vp_chopshop')
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
