-- server/chop.lua
-- [v1.15 PR-B] O estado de peça do BASE CHOP migrou de `ChoppedByNetId` para
-- `ChopSession.parts` (via server/session/base_state.lua). As funções públicas
-- (WasChopped/MarkChopped/VPChopServerTryPart/VPChopGetPartCount/VPChopClearVehicle)
-- mantêm a semântica de antes e delegam à fachada. Peças base = origin='base'.

--- Mutex leve: bloqueia coroutines concorrentes para o mesmo netId:partKey.
--- PRESERVADO no base chop — a PR-B foi migração de STATE, não de mutex.
--- (o advanced chop já usa ChopSession.LockPart desde a PR-C.)
local ChopInProgress = {} ---@type table<string, true>

-- [GAMEPLAY unificação] Sistema de "recompensa pendente entregue na bancada" REMOVIDO.
-- A Fase 1 dá os itens imediatamente no callback 'vp_chopshop:chopPart' (server/main.lua),
-- igual às fases avançadas. VPChopServerTryPart segue retornando `rewards`.

---@param netId integer
---@param partKey string
---@return boolean
local function WasChopped(netId, partKey)
    return VPChopBaseState.wasChopped(netId, partKey)
end

---@param src number
---@param netId integer
---@param partKey string
---@return boolean ok, boolean duplicate, string|nil err
local function MarkChopped(src, netId, partKey)
    return VPChopBaseState.markPart(src, netId, partKey)
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

    -- [v1.15 PR-B] Só AQUI (veículo legítimo + jogador no contexto válido) é que a
    -- ChopSession é resolvida/criada — nunca ao receber o payload cru.
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

    -- NOTA: `rewards` acima é só computado — só é ENTREGUE pelo chamador quando
    -- este retorno é (true, nil, rewards). O commit em MarkChopped abaixo é a
    -- última defesa: se ele recusar (done/completed/session), `rewards` é
    -- descartado. Não mover a geração de `rewards` para depois de MarkChopped.

    -- [GAMEPLAY unificação] Os itens NÃO são dados aqui; o callback chopPart (server/main.lua)
    -- entrega via InvAdd imediatamente após receber estes `rewards`.
    -- [v1.15 PR-B] Marcação no MESMO ponto lógico de antes: após todas as validações,
    -- antes do retorno de sucesso. Política de inventário-cheio inalterada (o
    -- chamador entrega os itens depois; peça fica marcada mesmo se o inv encher).
    local mOk, mDup, mErr = MarkChopped(src, netId, partKey)
    if not mOk then
        -- [PR-B follow-up] O store autoritativo é a ÚLTIMA defesa: se ele recusou,
        -- nunca devolver rewards/sucesso.
        if mErr == 'completed' then return false, 'completed', nil end
        return false, 'session', nil
    end
    if mDup then
        -- Corrida entre o WasChopped acima e o commit (sem yield hoje, mas o
        -- invariant tem de valer p/ as próximas migrações): tratar como 'done'.
        return false, 'done', nil
    end
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

--- Retorna o número de peças da FASE 1 (origin='base') já removidas de um veículo.
--- Peças advanced (origin='advanced') NÃO contam — `discardVehicle` continua
--- equivalente ao atual até a PR D (unified discard).
---@param netId integer
---@return integer
function VPChopGetPartCount(netId)
    return VPChopBaseState.partCount(netId)
end

--- Limpa o estado de peças base após o discard (fachada preservada).
---@param netId integer
function VPChopClearVehicle(netId)
    VPChopBaseState.clear(netId)
end

AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId == 0 then return end
    -- [v1.15 PR-B] ChoppedByNetId removido — o lifecycle da sessão é da própria
    -- ChopSession (chop_session.lua tem seu entityRemoved → CleanupVehicle).
    -- Aqui só o mutex legacy que ainda vive neste arquivo.
    local prefix = tostring(netId) .. ':'
    for k in pairs(ChopInProgress) do
        if k:sub(1, #prefix) == prefix then
            ChopInProgress[k] = nil
        end
    end
end)
