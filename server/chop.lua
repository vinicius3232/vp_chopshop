---@type table<integer, table<string, boolean>>
local ChoppedByNetId = {}

--- Mutex leve: bloqueia coroutines concorrentes para o mesmo netId:partKey
local ChopInProgress = {} ---@type table<string, true>

-- [GAMEPLAY unificação] Sistema de "recompensa pendente entregue na bancada" REMOVIDO.
-- Removidos: PendingPartRewards, VPChopStorePendingReward, VPChopClaimPendingReward.
-- A Fase 1 agora dá os itens imediatamente no callback 'vp_chopshop:chopPart' (server/main.lua),
-- igual às fases avançadas (advanced_chop.lua). VPChopServerTryPart segue retornando `rewards`,
-- mas quem entrega os itens agora é o chamador (chopPart), não a bancada.

---@param netId integer
---@param partKey string
---@return boolean
local function WasChopped(netId, partKey)
    local t = ChoppedByNetId[netId]
    return t and t[partKey] == true
end

---@param netId integer
---@param partKey string
local function MarkChopped(netId, partKey)
    if not ChoppedByNetId[netId] then ChoppedByNetId[netId] = {} end
    ChoppedByNetId[netId][partKey] = true
end

--- Validação e geração de recompensas. Elevador removido: valida jogador próximo do veículo.
---@param src number
---@param netId integer
---@param partKey string
---@return boolean ok
---@return string|nil err
---@return table|nil rewards
local function tryPartInner(src, netId, partKey)
    if not ChopParts[partKey] then return false, 'part', nil end
    if not Config.CarPartRewards[partKey] then return false, 'config', nil end

    -- Quando advanced chop está ativo, portas/capô/porta-malas pertencem à Fase 2.
    -- Fase 1 só processa pneus; rejeitar door-kind evita dupla recompensa e conflito de estado.
    local partDef = ChopParts[partKey]
    if Config.AdvancedChop and Config.AdvancedChop.Enable
        and partDef and partDef.kind == 'door' then
        return false, 'adv_only', nil
    end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) then return false, 'vehicle', nil end

    local maxDist = (Config.VehicleNearLiftRadius or 5.0) + 2.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then return false, 'range', nil end

    if WasChopped(netId, partKey) then return false, 'done', nil end

    local rewards = {}
    for itemName, rule in pairs(Config.CarPartRewards[partKey]) do
        local chance = tonumber(rule.chance) or 0.0
        local amount = tonumber(rule.amount) or 0
        if amount > 0 and math.random() <= chance then
            rewards[itemName] = (rewards[itemName] or 0) + amount
        end
    end

    local totalQty = 0
    for _, amount in pairs(rewards) do totalQty = totalQty + amount end
    if totalQty < 1 then
        rewards.metalscrap = 1
    end

    -- [GAMEPLAY unificação] Os itens NÃO são dados aqui; o callback chopPart (server/main.lua)
    -- entrega via InvAdd imediatamente após receber estes `rewards`.

    MarkChopped(netId, partKey)
    return true, nil, rewards
end

--- Wrapper público com mutex por netId:partKey — impede race condition entre coroutines concorrentes.
---@param src number
---@param netId integer
---@param partKey string
---@return boolean ok
---@return string|nil err
---@return table|nil rewards
function VPChopServerTryPart(src, netId, partKey)
    local pKey = netId .. ':' .. partKey
    if ChopInProgress[pKey] then return false, 'processing', nil end
    ChopInProgress[pKey] = true
    local ok, err, rewards = tryPartInner(src, netId, partKey)
    ChopInProgress[pKey] = nil
    return ok, err, rewards
end

--- Retorna o número de peças já removidas de um veículo.
---@param netId integer
---@return integer
function VPChopGetPartCount(netId)
    local t = ChoppedByNetId[netId]
    if not t then return 0 end
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

--- Limpa o registo de peças removidas de um veículo (chamado após discard).
---@param netId integer
function VPChopClearVehicle(netId)
    ChoppedByNetId[netId] = nil
end

AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId == 0 then return end
    ChoppedByNetId[netId] = nil
    -- Limpar in-progress para este netId (caso entidade despawne durante processamento)
    local prefix = tostring(netId) .. ':'
    for k in pairs(ChopInProgress) do
        if k:sub(1, #prefix) == prefix then
            ChopInProgress[k] = nil
        end
    end
end)
