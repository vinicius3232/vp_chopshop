-- server/plates.lua
-- [FASE1 placas] Roubo de placa física.
-- Callback: 'vp_chopshop:stealPlate' — recebe netId, resolve placa REAL server-side,
-- entrega item `stolen_plate` com metadata { plate, model, takenAt } e manda os clientes
-- próximos deixarem a placa visível em branco. Rende dispatch e XP de progressão tier 1.
--
-- Padrões espelhados de server/advanced_chop.lua e server/heat.lua:
--   IsValidSource / ServerPlayerIsReady, cooldown por src + cleanup no playerDropped,
--   netId tonumber + validação de tipos, ValidatePlayerNearVehicle (proximity server-side),
--   flag anti-duplo-roubo por netId limpa no entityRemoved,
--   broadcast FILTRADO por proximidade (~150u) em vez de -1,
--   VPChopMDT.ReportActivity + TriggerEvent(VPChopEvt.PART_CHOPPED, ...).

-- ─── Estado por jogador / por netId ──────────────────────────────────────────
local PlateStealCooldown = {} ---@type table<number, number>  src → expiry (GetGameTimer)
local PlateStolen        = {} ---@type table<number, boolean>  netId → já roubada (anti-duplo)

--- Cooldown configurável (segundos → ms). Fallback 30s.
local function plateCooldownMs()
    return (tonumber(Config.Plates and Config.Plates.StealCooldownSeconds) or 30) * 1000
end

-- Limpeza de cooldown ao desconectar (mesmo padrão do VinScratchCooldown em heat.lua).
AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1] capturar antes de qualquer yield
    PlateStealCooldown[src] = nil
end)

-- Limpar flag anti-duplo-roubo quando a entidade some (padrão do AdvState em advanced_chop.lua).
AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId and netId ~= 0 then
        PlateStolen[netId] = nil
    end
end)

-- ─── Broadcast filtrado: clientes próximos apagam a placa visível ─────────────
--- Em vez de TriggerClientEvent(-1), só notificamos clientes a ~150u da entidade
--- (mesmo padrão H4 do advanced_chop.lua para breakDoor).
---@param netId integer
---@param vehCoords vector3|nil
local function broadcastPlateCleared(netId, vehCoords)
    for _, pid in ipairs(GetPlayers()) do
        local pidN = tonumber(pid)
        if pidN then
            local send = true
            if vehCoords then
                local pped = GetPlayerPed(pidN)
                send = pped and pped ~= 0 and #(GetEntityCoords(pped) - vehCoords) < 150.0
            end
            if send then
                TriggerClientEvent('vp_chopshop:client:plateCleared', pidN, netId)
            end
        end
    end
end

-- ─── Callback: roubar placa ───────────────────────────────────────────────────
lib.callback.register('vp_chopshop:stealPlate', function(src, netId)
    -- Feature desligada
    if not Config.Plates or not Config.Plates.Enable then
        return { ok = false, err = 'disabled' }
    end

    -- Guard de fonte + jogador carregado
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    -- Cooldown anti-farm por jogador
    local now = GetGameTimer()
    if PlateStealCooldown[src] and now < PlateStealCooldown[src] then
        return { ok = false, err = 'cooldown' }
    end

    -- Validar netId (rejeita payloads malformados de lua executor)
    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end

    -- Anti-duplo-roubo: placa desta entidade já foi arrancada nesta sessão
    if PlateStolen[netId] then return { ok = false, err = 'done' } end

    -- Resolver veículo a partir do netId
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return { ok = false, err = 'vehicle' }
    end

    -- Proximity check server-side (verdade — nunca confiar no client)
    local maxDist = tonumber(Config.Plates.MaxDistance) or 3.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist + 1.0) then
        return { ok = false, err = 'range' }
    end

    -- Placa REAL resolvida no servidor (nunca confiamos no cliente)
    local realPlate = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', '')
    if realPlate == '' then return { ok = false, err = 'no_plate' } end

    -- Ferramenta exigida (verdade server-side; client só faz a UX)
    local tool = Config.Plates.ToolItem or 'screwdriver'
    if InvCount(src, tool) < 1 then
        return { ok = false, err = 'no_tool' }
    end

    -- Modelo do veículo (metadata informativa do item)
    local model = GetEntityModel(veh)

    -- Marcar como roubada ANTES de operações com yield (evita race entre callbacks simultâneos)
    PlateStolen[netId] = true
    PlateStealCooldown[src] = now + plateCooldownMs()

    -- Entregar item com metadata. InvAdd → exports.ox_inventory:AddItem(src, item, count, metadata).
    local added = exports.ox_inventory:AddItem(src, 'stolen_plate', 1, {
        plate   = realPlate,
        model   = model,
        takenAt = os.time(),
    })
    if not added then
        -- Inventário cheio / falha: reverter flag e cooldown para o jogador poder tentar de novo
        PlateStolen[netId] = nil
        PlateStealCooldown[src] = nil
        return { ok = false, err = 'inventory' }
    end

    -- Apagar a placa visível nos clientes próximos (broadcast filtrado por proximidade)
    local vehCoords = GetEntityCoords(veh)
    broadcastPlateCleared(netId, vehCoords)

    -- Dispatch (mesmo mecanismo do alarme: servidor manda o client chamar VPChopTriggerDispatch)
    if Config.Plates.DispatchOnSteal then
        TriggerClientEvent('vp_chopshop:client:plateDispatch', src, netId)
    end

    -- Reportar ao MDT e emitir XP via barramento de eventos (phase 1 = tier 1)
    VPChopMDT.ReportActivity(realPlate, src, 'plate_stolen')
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'plate_theft', 1)

    return { ok = true }
end)
