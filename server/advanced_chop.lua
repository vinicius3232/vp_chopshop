-- ============================================================
-- server/advanced_chop.lua
-- Sistema de desmanche avançado por fases (requer jackstand levantado).
-- Fase 2 — Portas / Capô / Porta-malas  → requer serra    → 1× car_parts por peça
-- Fase 3 — Motor                         → requer chave    → 5× car_parts (capô removido primeiro)
-- Fase 4 — Carcaça                       → requer solda    → recicláveis
-- ============================================================

-- ─── Estado por netId ────────────────────────────────────────────────────────
-- [netId] = { door_dside_f=true, bonnet=true, adv_engine=true, adv_carcass=true, ... }
local AdvState   = {}
local AdvMutex   = {} -- [netId:key] = true  (mutex por operação)
local AdvCooldown = {} -- [src] = GetGameTimer() — rate-limit por jogador

local ADV_COOLDOWN_MS = 3000  -- mínimo entre ações de desmanche avançado

local function advOnCooldown(src)
    local t = AdvCooldown[src]
    return t and (GetGameTimer() - t) < ADV_COOLDOWN_MS
end

local function advMarkCooldown(src)
    AdvCooldown[src] = GetGameTimer()
end

AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1]
    AdvCooldown[src] = nil
end)

local function getState(netId)
    if not AdvState[netId] then AdvState[netId] = {} end
    return AdvState[netId]
end

local function isChopped(netId, key)
    local st = AdvState[netId]
    return st and st[key] == true
end

local function markChopped(netId, key)
    getState(netId)[key] = true
end

-- Mutex leve: evita race condition em acções simultâneas
local function tryLock(netId, key)
    local k = tostring(netId) .. ':' .. key
    if AdvMutex[k] then return false end
    AdvMutex[k] = true
    return true, k
end

local function unlock(lockKey)
    AdvMutex[lockKey] = nil
end

-- Limpar ao destruir entidade
AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId and netId ~= 0 then
        AdvState[netId] = nil
        local prefix = tostring(netId) .. ':'
        for k in pairs(AdvMutex) do
            if k:sub(1, #prefix) == prefix then AdvMutex[k] = nil end
        end
    end
end)

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getVehCoords(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    return GetEntityCoords(veh)
end

--- Durabilidade da ferramenta
local function consumeSaw(src)
    return VPChopConsumeTool(src, false)
end

--- [AUDIT-FIX C2] As fases 2/3/4 não deixavam vestígio forense nem armavam a marca de pneu
--- (o desmanche avançado por jackstand passava 100% limpo). Este helper espelha o MESMO padrão
--- da Fase 1 (server/main.lua ~378) e dos hooks de placa (server/plates.lua): planta evidência
--- com a placa REAL resolvida e arma a janela de marca de pneu (client + server-side via
--- VPChopArmTyreWindow do server/tyremarks.lua, C2+H1).
--- Assinatura confirmada em bridge/evidence.lua: VPChopLeaveEvidence(src, coords, actionKey, plate?).
---@param src number
---@param netId number
---@param vehCoords vector3
local function leaveAdvancedTrace(src, netId, vehCoords)
    -- Resolver a placa REAL pelo veículo já validado (trust-no-client; mesmo padrão de heat.lua).
    local veh = NetworkGetEntityFromNetworkId(netId)
    local realPlate = nil
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        local visible = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', '')
        if visible ~= '' then
            realPlate = VPChopMDT.GetRealPlate(visible)
        end
    end

    -- Vestígio forense no local do veículo (digital + DNA vinculados ao criminoso).
    VPChopLeaveEvidence(src, vehCoords, 'chop_part', realPlate)

    -- Armar a janela de marca de pneu (client + gate server-side anti-cheat).
    if Config.TyreMarks and Config.TyreMarks.Enable then
        local armMs = (Config.TyreMarks.ArmWindowSeconds or 45) * 1000
        VPChopArmTyreWindow(src, armMs)  -- [AUDIT-FIX H1]
        TriggerClientEvent('vp_chopshop:armTyreMark', src, armMs)
    end
end

-- ─── Fase 2: Portas / Capô / Porta-malas ─────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopPart', function(source, netId, partKey)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then
        return { ok = false, err = 'disabled' }
    end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advOnCooldown(src) then return { ok = false, err = 'processing' } end

    -- Validar tipos de entrada (rejeita payloads malformados de lua executor)
    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end
    if type(partKey) ~= 'string' or #partKey > 32 or #partKey < 3 then
        return { ok = false, err = 'part' }
    end

    -- Gate: parte já desmontada?
    if isChopped(netId, partKey) then return { ok = false, err = 'done' } end

    -- Parte válida?
    local partDef = ChopParts[partKey]
    if not partDef or partDef.kind ~= 'door' then return { ok = false, err = 'part' } end

    -- Veículo e distância
    local vehCoords = getVehCoords(netId)
    if not vehCoords then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearPoint(src, vehCoords, 6.0) then return { ok = false, err = 'distance' } end

    -- Mutex
    local locked, lockKey = tryLock(netId, partKey)
    if not locked then return { ok = false, err = 'processing' } end

    -- Verificar e consumir serra
    if not consumeSaw(src) then
        unlock(lockKey)
        return { ok = false, err = 'no_saw' }
    end

    -- [FIX H-3] Verificar retorno de InvAdd — inventário cheio: peça marcada mas notificar jogador
    local reward = Config.AdvancedChop.DoorReward or { item = 'car_parts', amount = 1 }
    if reward.item and (reward.amount or 0) > 0 then
        -- [SERIAL] car_parts nasce ROUBADA com série + modelo de origem (mesma série por carro).
        local ok = (reward.item == 'car_parts')
            and VPChopAddStolenCarParts(src, netId, reward.amount)
            or  InvAdd(src, reward.item, reward.amount)
        if not ok then
            TriggerClientEvent('ox_lib:notify', src, { type='warning', description='Inventário cheio — item de recompensa perdido.' })
        end
    end

    markChopped(netId, partKey)
    advMarkCooldown(src)
    unlock(lockKey)

    -- [AUDIT-FIX C2] Deixar vestígio + armar marca de pneu (Fase 2). `vehCoords` validado acima.
    leaveAdvancedTrace(src, netId, vehCoords)

    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, partKey, 2)

    -- [H4 FIX] Filtrar breakDoor por proximidade (era broadcast -1 para todos os clientes).
    -- Mesmo padrão corrigido no breakPart (L3 fix). Só clientes perto da entidade recebem.
    local ent = NetworkGetEntityFromNetworkId(netId)
    local bpos = (ent and ent ~= 0 and DoesEntityExist(ent)) and GetEntityCoords(ent) or nil
    for _, pid in ipairs(GetPlayers()) do
        local pidN = tonumber(pid)
        if pidN then
            local send = true
            if bpos then
                local pped = GetPlayerPed(pidN)
                send = pped and pped ~= 0 and #(GetEntityCoords(pped) - bpos) < 150.0
            end
            if send then TriggerClientEvent('vp_chopshop:adv:breakDoor', pidN, netId, partKey, partDef.index) end
        end
    end

    return { ok = true }
end)

-- ─── Fase 3: Motor ────────────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopEngine', function(source, netId)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then
        return { ok = false, err = 'disabled' }
    end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advOnCooldown(src) then return { ok = false, err = 'processing' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end

    -- Capô deve estar removido
    if not isChopped(netId, 'bonnet') then return { ok = false, err = 'hood_first' } end

    -- Já desmontado?
    if isChopped(netId, 'adv_engine') then return { ok = false, err = 'done' } end

    -- Veículo e distância
    local vehCoords = getVehCoords(netId)
    if not vehCoords then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearPoint(src, vehCoords, 6.0) then return { ok = false, err = 'distance' } end

    -- Verificar chave de fenda
    if not VPChopHasTool(src, true) then
        return { ok = false, err = 'no_screwdriver' }
    end

    -- Mutex
    local locked, lockKey = tryLock(netId, 'adv_engine')
    if not locked then return { ok = false, err = 'processing' } end

    -- Consumir chave de fenda (verificado acima; consumido agora no lock)
    if not VPChopConsumeTool(src, true) then
        unlock(lockKey)
        return { ok = false, err = 'no_screwdriver' }
    end

    -- [FIX H-3] Verificar retorno de InvAdd — inventário cheio: motor marcado mas notificar jogador
    local reward = Config.AdvancedChop.EngineReward or { item = 'car_parts', amount = 5 }
    if reward.item and (reward.amount or 0) > 0 then
        -- [SERIAL] As 5 car_parts do motor herdam a MESMA série/modelo do carro (mesmo netId).
        local ok = (reward.item == 'car_parts')
            and VPChopAddStolenCarParts(src, netId, reward.amount)
            or  InvAdd(src, reward.item, reward.amount)
        if not ok then
            TriggerClientEvent('ox_lib:notify', src, { type='warning', description='Inventário cheio — item de recompensa perdido.' })
        end
    end

    markChopped(netId, 'adv_engine')
    advMarkCooldown(src)
    unlock(lockKey)
    -- [AUDIT-FIX C2] Deixar vestígio + armar marca de pneu (Fase 3). `vehCoords` validado acima.
    leaveAdvancedTrace(src, netId, vehCoords)
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'adv_engine', 3)
    return { ok = true }
end)

-- ─── Fase 4: Carcaça ──────────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopCarcass', function(source, netId)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then
        return { ok = false, err = 'disabled' }
    end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advOnCooldown(src) then return { ok = false, err = 'processing' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end

    -- Motor deve estar desmontado
    if not isChopped(netId, 'adv_engine') then return { ok = false, err = 'engine_first' } end

    -- Já cortado?
    if isChopped(netId, 'adv_carcass') then return { ok = false, err = 'done' } end

    -- Veículo e distância
    local vehCoords = getVehCoords(netId)
    if not vehCoords then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearPoint(src, vehCoords, 8.0) then return { ok = false, err = 'distance' } end

    -- Verificar soldadora perto (server-side — trust no client)
    local welderRadius = tonumber(Config.AdvancedChop.WelderRadius) or 8.0
    local hasWelder = false
    for _, w in ipairs(ServerWelders or {}) do
        if #(w.coords - vehCoords) <= welderRadius then hasWelder = true; break end
    end
    if not hasWelder then return { ok = false, err = 'no_welder_adv' } end

    -- Mutex
    local locked, lockKey = tryLock(netId, 'adv_carcass')
    if not locked then return { ok = false, err = 'processing' } end

    -- [FIX H-3] Dar recompensas recicláveis com verificação de retorno
    local anyFull = false
    for _, reward in ipairs(Config.AdvancedChop.CarcassRewards or {}) do
        if reward.item and (reward.amount or 0) > 0 then
            local chance = reward.chance or 1.0
            if math.random() <= chance then
                -- [SERIAL] Se a carcaça também der car_parts, herda a série/modelo do carro.
                local ok = (reward.item == 'car_parts')
                    and VPChopAddStolenCarParts(src, netId, reward.amount)
                    or  InvAdd(src, reward.item, reward.amount)
                if not ok then
                    anyFull = true
                end
            end
        end
    end
    if anyFull then
        TriggerClientEvent('ox_lib:notify', src, { type='warning', description='Inventário cheio — alguns itens de carcaça perdidos.' })
    end

    markChopped(netId, 'adv_carcass')
    advMarkCooldown(src)
    unlock(lockKey)
    -- [AUDIT-FIX C2] Deixar vestígio + armar marca de pneu (Fase 4). `vehCoords` validado acima.
    leaveAdvancedTrace(src, netId, vehCoords)
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'adv_carcass', 4)
    return { ok = true }
end)
