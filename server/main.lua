-- [REMOVED] ServerLifts, ServerLiftsById, LiftMovement, VPChopLiftById:
-- elevador removido do sistema — apenas macaco (jackstand) é necessário para desmanche.

-- Local fallback: garante que VPChopEvt está disponível mesmo se o global não propagou.
local VPChopEvt = VPChopEvt or {
    PART_CHOPPED   = 'vp_chopshop:evt:partChopped',
    CAR_DISCARDED  = 'vp_chopshop:evt:carDiscard',
    FENCE_DELIVERY = 'vp_chopshop:evt:fenceDelivery',
    HEAT_CHANGED   = 'vp_chopshop:evt:heatChanged',
}

ServerBenches = {}
ServerWelders = {}
local ServerWeldersById = {}
ServerWorldLoaded = false

--- Alarmes veiculares ativos: [netId] = { src = number }
--- Populated quando o alarme dispara; limpo ao desarmar ou ao expirar.
local AlarmActive = {}

local ServerBenchesById = {}
local BenchCraftBusy = {} ---@type table<number, boolean>  src → true when crafting

local function benchById(id)
    return ServerBenchesById[id]
end

local function serializeWorld()
    local benches = {}
    for _, bench in ipairs(ServerBenches) do
        benches[#benches + 1] = {
            id = bench.id,
            x = bench.coords.x,
            y = bench.coords.y,
            z = bench.coords.z,
            heading = bench.heading,
        }
    end
    local welders = {}
    for _, w in ipairs(ServerWelders) do
        welders[#welders + 1] = {
            id = w.id,
            x = w.coords.x, y = w.coords.y, z = w.coords.z,
            heading = w.heading,
        }
    end
    return { benches = benches, welders = welders }
end

local function broadcastWorld()
    TriggerClientEvent('vp_chopshop:syncWorld', -1, serializeWorld())
end

local function removeBenchFromMemory(id)
    ServerBenchesById[id] = nil
    for i = #ServerBenches, 1, -1 do
        if ServerBenches[i].id == id then
            table.remove(ServerBenches, i)
            break
        end
    end
end

local function removeWelderFromMemory(id)
    ServerWeldersById[id] = nil
    for i = #ServerWelders, 1, -1 do
        if ServerWelders[i].id == id then
            table.remove(ServerWelders, i)
            break
        end
    end
end

local function broadcastAddWelder(w)
    TriggerClientEvent('vp_chopshop:addWelder', -1, {
        id = w.id, x = w.coords.x, y = w.coords.y, z = w.coords.z, heading = w.heading,
    })
end

local function broadcastRemoveWelder(id)
    TriggerClientEvent('vp_chopshop:removeWelder', -1, id)
end

local function isWelderTooClose(coords)
    local minD = tonumber(Config.MinWelderSpacing) or 0
    if minD < 1 then return false end
    for _, w in ipairs(ServerWelders) do
        if #(w.coords - coords) < minD then return true end
    end
    return false
end

local function isWelderNearBench(bench)
    local radius = tonumber(Config.WelderBenchRadius) or 8.0
    for _, w in ipairs(ServerWelders) do
        if #(w.coords - bench.coords) <= radius then return true end
    end
    return false
end

local function broadcastAddBench(bench)
    TriggerClientEvent('vp_chopshop:addBench', -1, {
        id = bench.id,
        x = bench.coords.x, y = bench.coords.y, z = bench.coords.z,
        heading = bench.heading,
    })
end

local function broadcastRemoveBench(id)
    TriggerClientEvent('vp_chopshop:removeBench', -1, id)
end

local function isBenchTooClose(coords)
    local minD = tonumber(Config.MinBenchSpacing) or 0
    if minD < 1 then return false end
    for _, bench in ipairs(ServerBenches) do
        if #(bench.coords - coords) < minD then return true end
    end
    return false
end

local _npcBuyCooldown = {} ---@type table<string, number>

local function npcBuyCooldownCheck(src)
    local sec = (Config.NPC and Config.NPC.Shop and tonumber(Config.NPC.Shop.CooldownSeconds)) or 0
    if sec < 1 then return false end
    local key = ServerChopPlayerKey(src)
    local t = _npcBuyCooldown[key]
    return t and os.time() < t
end

local function npcBuyCooldownMark(src)
    local sec = (Config.NPC and Config.NPC.Shop and tonumber(Config.NPC.Shop.CooldownSeconds)) or 0
    if sec < 1 then return end
    local key = ServerChopPlayerKey(src)
    _npcBuyCooldown[key] = os.time() + sec
end

AddEventHandler('playerDropped', function()
    local src = source
    local key = ServerChopPlayerKey(src)
    _npcBuyCooldown[key] = nil
    BenchCraftBusy[src] = nil
    VPChopClaimPendingReward(src) -- limpar recompensa pendente (peça perdida ao desconectar)
    -- Limpar alarme do jogador que saiu (timeout silencioso; sem dispatch)
    for netId, data in pairs(AlarmActive) do
        if data.src == src then
            AlarmActive[netId] = nil
        end
    end
end)

--- Cancela o alarme de um veículo quando o jogador o desarma manualmente.
--- Valida server-side que o jogador possui o item exigido (trust-no-client).
RegisterNetEvent('vp_chopshop:server:alarmDisarmed', function(netId)
    local src = source
    if not GetPlayerName(src) then return end
    netId = tonumber(netId)
    if not netId then return end
    local alarm = AlarmActive[netId]
    if not alarm or alarm.src ~= src then return end

    -- Validar item (servidor não confia no cliente para esta verificação)
    local disarmItem = (Config.Alarm and Config.Alarm.DisarmItem) or 'screwdriver'
    if InvCount(src, disarmItem) < 1 then return end

    AlarmActive[netId] = nil
end)

local function runDbLoad()
    ServerBenches = VPChopDbLoadBenches()
    for _, bench in ipairs(ServerBenches) do ServerBenchesById[bench.id] = bench end
    ServerWelders = VPChopDbLoadWelders()
    for _, w in ipairs(ServerWelders) do ServerWeldersById[w.id] = w end
    ServerWorldLoaded = true
    broadcastWorld()
end

CreateThread(function()
    if VPChopDBReady then
        runDbLoad()
    end
end)

AddEventHandler('vp_chopshop:server:dbReady', function()
    runDbLoad()
end)

lib.callback.register('vp_chopshop:getWorld', function(source)
    if not GetPlayerName(source) then return nil end
    local tries = 0
    while not ServerWorldLoaded and tries < 200 do
        Wait(50)
        tries = tries + 1
    end
    return serializeWorld()
end)

lib.callback.register('vp_chopshop:placeBench', function(source, payload)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z)
    local heading = tonumber(payload.heading) or 0.0
    if not x or not y or not z then return { ok = false, err = 'coords' } end
    local coords = vector3(x, y, z)
    if not ValidatePlayerPlacementRange(source, coords) then return { ok = false, err = 'distance' } end
    if isBenchTooClose(coords) then return { ok = false, err = 'too_close' } end

    local item = Config.Items.placeBench
    if InvCount(source, item) < 1 then return { ok = false, err = 'item' } end
    if not InvRemove(source, item, 1) then return { ok = false, err = 'remove' } end

    local placedBy = ServerChopPlayerKey(source)
    local id = VPChopDbInsertBench(coords, heading, placedBy)
    if not id then
        InvAdd(source, item, 1)
        return { ok = false, err = 'db' }
    end

    local bench = { id = id, coords = coords, heading = heading, placed_by = placedBy }
    ServerBenches[#ServerBenches + 1] = bench
    ServerBenchesById[id] = bench
    broadcastAddBench(bench)
    VPChopDiscordLogPlace(source, 'bench', id)
    return { ok = true, id = id }
end)

function VPChopConsumeTool(src, wantDrill)
    if not Config.Tools then return true end
    -- [H1 FIX] GetInventoryItems não existe em ox_inventory v2+; substituído por
    -- GetItem por ferramenta — export documentado que retorna dados + metadata do slot.
    for toolName, toolCfg in pairs(Config.Tools) do
        local isDrill = (toolName == 'mechanic_drill')
        if isDrill == (wantDrill == true) then
            if InvCount(src, toolName) > 0 then
                local maxUses = tonumber(toolCfg.MaxUses) or 6
                local itemData = exports.ox_inventory:GetItem(src, toolName, nil, false)
                local prevMeta = itemData and itemData.metadata or nil
                local uses = tonumber(prevMeta and prevMeta.uses_remaining) or maxUses
                -- Remover a instância com metadata original (match de slot correto)
                if not exports.ox_inventory:RemoveItem(src, toolName, 1, prevMeta) then
                    return false
                end
                uses = uses - 1
                if uses > 0 then
                    exports.ox_inventory:AddItem(src, toolName, 1, { uses_remaining = uses })
                else
                    TriggerClientEvent('vp_chopshop:client:sawBroke', src)
                end
                return true
            end
        end
    end
    return false
end

function VPChopHasTool(src, wantDrill)
    if not Config.Tools then return true end
    for toolName, _ in pairs(Config.Tools) do
        local isDrill = (toolName == 'mechanic_drill')
        local wd = (wantDrill == true)
        if isDrill == wd then
            if InvCount(src, toolName) > 0 then return true end
        end
    end
    return false
end

lib.callback.register('vp_chopshop:chopPart', function(source, netId, partKey)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end

    netId = tonumber(netId)
    if not netId then return { ok = false, err = 'net' } end

    local cd = VPChopChopCooldownRemaining(source)
    if cd > 0 then return { ok = false, err = 'cooldown', wait = cd } end

    -- Validar ferramenta de desmanche
    if not VPChopHasTool(source, false) then
        return { ok = false, err = 'no_saw' }
    end

    -- Marcar cooldown ANTES do yield em VPChopServerTryPart para evitar race condition
    VPChopChopCooldownMark(source)

    local ok, err, rewards = VPChopServerTryPart(source, netId, partKey)
    if not ok then return { ok = false, err = err } end

    -- Consumir durabilidade da ferramenta
    VPChopConsumeTool(source, false)

    -- Guardar recompensas pendentes; itens só são dados na entrega à bancada.
    VPChopStorePendingReward(source, partKey, rewards)

    -- Resolver placa server-side (trust-no-client)
    local vehForPlate = NetworkGetEntityFromNetworkId(netId)
    local plate = (vehForPlate and vehForPlate ~= 0 and DoesEntityExist(vehForPlate))
        and GetVehicleNumberPlateText(vehForPlate):gsub('%s+', '')
        or ''

    -- Emitir evento para progression e fence escutarem
    TriggerEvent(VPChopEvt.PART_CHOPPED, source, netId, partKey, 1)

    VPChopDiscordLogChop(source, partKey, rewards)

    -- [L3 FIX] Filtrar por proximidade (~150u) em vez de broadcast global (-1).
    -- Veículos só fazem stream nesse raio; clientes fora descartariam o evento de qualquer forma.
    local vehEnt = NetworkGetEntityFromNetworkId(netId)
    local vehPos = (vehEnt and vehEnt ~= 0 and DoesEntityExist(vehEnt)) and GetEntityCoords(vehEnt) or nil
    for _, pid in ipairs(GetPlayers()) do
        local pidN = tonumber(pid)
        if pidN then
            local ped = GetPlayerPed(pidN)
            local send = true
            if vehPos and ped and ped ~= 0 then
                send = #(GetEntityCoords(ped) - vehPos) < 150.0
            end
            if send then
                TriggerClientEvent('vp_chopshop:client:breakPart', pidN, netId, partKey)
            end
        end
    end

    -- Sistema de alarme: rolar chance na primeira peça removida deste veículo.
    local alarmCfg = Config.Alarm
    if alarmCfg and alarmCfg.Enable and not AlarmActive[netId] then
        local vehForAlarm = NetworkGetEntityFromNetworkId(netId)
        if vehForAlarm and vehForAlarm ~= 0 and DoesEntityExist(vehForAlarm) then
            local class  = GetVehicleClass(vehForAlarm)
            local chance = (alarmCfg.ChanceByClass and alarmCfg.ChanceByClass[class])
                           or (alarmCfg.DefaultChance or 0.25)
            if math.random() <= chance then
                local capturedNetId = netId
                local capturedSrc   = source
                AlarmActive[capturedNetId] = { src = capturedSrc }
                TriggerClientEvent('vp_chopshop:client:alarmTriggered', capturedSrc, capturedNetId)
                local windowMs = math.floor((alarmCfg.DisarmWindowSeconds or 30) * 1000)
                SetTimeout(windowMs, function()
                    if AlarmActive[capturedNetId] then
                        AlarmActive[capturedNetId] = nil
                        if GetPlayerName(capturedSrc) then
                            TriggerClientEvent('vp_chopshop:client:alarmExpired', capturedSrc, capturedNetId)
                        end
                    end
                end)
            end
        end
    end

    return { ok = true }
end)

lib.callback.register('vp_chopshop:benchCraft', function(source, benchId, recipeIndex)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    if BenchCraftBusy[source] then return { ok = false, err = 'busy' } end
    BenchCraftBusy[source] = true
    local bench = benchById(benchId)
    if not bench then BenchCraftBusy[source] = nil return { ok = false, err = 'bench' } end
    if not isWelderNearBench(bench) then BenchCraftBusy[source] = nil return { ok = false, err = 'no_welder' } end
    recipeIndex = tonumber(recipeIndex)
    if not recipeIndex then BenchCraftBusy[source] = nil return { ok = false, err = 'recipe' } end

    local ok, err = VPChopServerTryBenchRecipe(bench, source, recipeIndex)
    if not ok then BenchCraftBusy[source] = nil return { ok = false, err = err } end
    VPChopDiscordLogBench(source, benchId, recipeIndex)
    BenchCraftBusy[source] = nil
    return { ok = true }
end)

lib.callback.register('vp_chopshop:deliverPart', function(source, benchId)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    benchId = tonumber(benchId)
    if not benchId then return { ok = false, err = 'args' } end
    local bench = benchById(benchId)
    if not bench then return { ok = false, err = 'bench' } end
    if not isWelderNearBench(bench) then return { ok = false, err = 'no_welder' } end
    if not ValidatePlayerNearCoords(source, bench.coords) then return { ok = false, err = 'distance' } end

    local pending = VPChopClaimPendingReward(source)
    if not pending then return { ok = false, err = 'no_part' } end

    -- Dar itens com rollback atómico
    local added = {}
    for itemName, amount in pairs(pending.rewards) do
        if amount > 0 then
            if not InvAdd(source, itemName, amount) then
                for rName, rAmt in pairs(added) do InvRemove(source, rName, rAmt) end
                VPChopStorePendingReward(source, pending.partKey, pending.rewards)
                return { ok = false, err = 'inventory' }
            end
            added[itemName] = amount
        end
    end

    return { ok = true, rewards = pending.rewards }
end)

lib.callback.register('vp_chopshop:discardVehicle', function(source, netId)
    if not (Config.Discard and Config.Discard.Enable) then return { ok = false, err = 'disabled' } end
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    netId = tonumber(netId)
    if not netId then return { ok = false, err = 'args' } end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) then return { ok = false, err = 'vehicle' } end

    local maxDist = (Config.VehicleNearLiftRadius or 5.0) + 2.0
    if not ValidatePlayerNearVehicle(source, veh, maxDist) then return { ok = false, err = 'distance' } end

    local partCount = VPChopGetPartCount(netId)
    local minParts  = math.floor(tonumber((Config.Discard or {}).MinPartsToDiscard) or 4)
    if partCount < minParts then
        return { ok = false, err = 'parts_min', count = partCount, min = minParts }
    end

    -- Calcular payout
    local model  = GetEntityModel(veh)
    local payout = math.floor(tonumber((Config.Discard or {}).DefaultPayout) or 1500)
    local byModel = Config.Discard and Config.Discard.PayoutByModel
    if byModel and byModel[model] then
        payout = math.floor(tonumber(byModel[model]) or payout)
    end

    -- Bónus polícia
    local appliedBonus = false
    local bonusCfg = Config.Discard and Config.Discard.CopsBonus
    if bonusCfg and bonusCfg.Enable then
        local cops    = BridgeCountCops()
        local minCops = tonumber(bonusCfg.MinCops) or 4
        if cops >= minCops then
            payout       = math.floor(payout * (tonumber(bonusCfg.Multiplier) or 1.5))
            appliedBonus = true
        end
    end

    local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')

    BridgeAddCash(source, payout, 'discard_payout')  -- [L3 FIX] reason adicionado para transaction logging
    VPChopClearVehicle(netId)
    AlarmActive[netId] = nil  -- veículo descartado: alarme encerrado
    TriggerEvent(VPChopEvt.CAR_DISCARDED, source, netId, plate, payout)
    DeleteEntity(veh)

    return { ok = true, payout = payout, bonus = appliedBonus }
end)

lib.callback.register('vp_chopshop:maybeAmbush', function(source, netId)
    if not GetPlayerName(source) then return false end
    -- Resolver placa para heat multiplier
    local vehForPlate = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    local plate = (vehForPlate and vehForPlate ~= 0 and DoesEntityExist(vehForPlate))
        and GetVehicleNumberPlateText(vehForPlate):gsub('%s+', '')
        or ''
    VPChopAmbushMaybe(source, netId, plate)
    return true
end)

lib.callback.register('vp_chopshop:npcAcceptMission', function(source)
    if not GetPlayerName(source) then return { ok=false } end
    return VPChopNpcMissionAccept(source)
end)

lib.callback.register('vp_chopshop:npcBuy', function(source, kind)
    if not Config.NPC or not Config.NPC.Enable then return { ok = false, err = 'disabled' } end
    local shop = Config.NPC.Shop
    if not shop or not shop.Enable then return { ok = false, err = 'disabled' } end

    local c = Config.NPC.Coords
    -- [DC-05] Removido + 0.0: Config.NPC.Coords é vector4 literal — campos já são numbers
    local npos = vector3(c.x, c.y, c.z)
    if not ValidatePlayerNearPoint(source, npos, 3.0) then return { ok = false, err = 'distance' } end
    if npcBuyCooldownCheck(source) then return { ok = false, err = 'cooldown' } end

    -- [REMOVED] kind == 'lift': elevador não está mais disponível na loja do NPC.
    if kind ~= 'bench' then return { ok = false, err = 'args' } end

    local price = math.floor(tonumber(shop.BenchPrice) or 0)
    local itemName = Config.Items.placeBench
    if price < 1 then return { ok = false, err = 'disabled' } end

    local cash = BridgeGetCash(source)
    if cash < price then return { ok = false, err = 'money' } end
    if not BridgeRemoveCash(source, price) then return { ok = false, err = 'money' } end

    if not InvAdd(source, itemName, 1) then
        BridgeAddCash(source, price)
        return { ok = false, err = 'inventory' }
    end
    npcBuyCooldownMark(source)
    return { ok = true }
end)

lib.callback.register('vp_chopshop:pickupBench', function(source, benchId)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    benchId = tonumber(benchId)
    if not benchId then return { ok = false, err = 'args' } end
    local bench = benchById(benchId)
    if not bench then return { ok = false, err = 'bench' } end
    if not ValidatePlayerNearCoords(source, bench.coords) then return { ok = false, err = 'distance' } end

    local key = ServerChopPlayerKey(source)
    if bench.placed_by and bench.placed_by ~= key then
        return { ok = false, err = 'unauthorized' }
    end

    local item = Config.Items.placeBench
    if not InvAdd(source, item, 1) then return { ok = false, err = 'inventory' } end

    VPChopDbDeleteBench(benchId)
    removeBenchFromMemory(benchId)
    broadcastRemoveBench(benchId)
    return { ok = true }
end)

lib.callback.register('vp_chopshop:placeWelder', function(source, payload)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z)
    local heading = tonumber(payload.heading) or 0.0
    if not x or not y or not z then return { ok = false, err = 'coords' } end
    local coords = vector3(x, y, z)
    if not ValidatePlayerPlacementRange(source, coords) then return { ok = false, err = 'distance' } end

    local item = Config.Items.placeWelder
    if InvCount(source, item) < 1 then return { ok = false, err = 'item' } end
    if not InvRemove(source, item, 1) then return { ok = false, err = 'remove' } end

    local placedBy = ServerChopPlayerKey(source)
    local id = VPChopDbInsertWelder(coords, heading, placedBy)
    if not id then
        InvAdd(source, item, 1)
        return { ok = false, err = 'db' }
    end

    local w = { id = id, coords = coords, heading = heading, placed_by = placedBy }
    ServerWelders[#ServerWelders + 1] = w
    ServerWeldersById[id] = w
    broadcastAddWelder(w)
    return { ok = true, id = id }
end)

lib.callback.register('vp_chopshop:pickupWelder', function(source, welderId)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    welderId = tonumber(welderId)
    if not welderId then return { ok = false, err = 'args' } end
    local w = ServerWeldersById[welderId]
    if not w then return { ok = false, err = 'bench' } end
    if not ValidatePlayerNearCoords(source, w.coords) then return { ok = false, err = 'distance' } end

    local key = ServerChopPlayerKey(source)
    if w.placed_by and w.placed_by ~= key then
        return { ok = false, err = 'unauthorized' }
    end

    local item = Config.Items.placeWelder
    if not InvAdd(source, item, 1) then return { ok = false, err = 'inventory' } end

    VPChopDbDeleteWelder(welderId)
    removeWelderFromMemory(welderId)
    broadcastRemoveWelder(welderId)
    return { ok = true }
end)

RegisterCommand('chopbenches', function(src, _)  -- [M2 FIX] Renomeado de 'choplifts' (lifts removidos)
    if src ~= 0 and not IsPlayerAceAllowed(src, 'command.chopshop_admin') then return end
    local lines = { '[vp_chopshop] Benches (' .. #ServerBenches .. '):' }
    for _, bench in ipairs(ServerBenches) do
        lines[#lines + 1] = ('  id=%-4d  pos=%.1f,%.1f,%.1f  by=%s'):format(
            bench.id, bench.coords.x, bench.coords.y, bench.coords.z,
            tostring(bench.placed_by or '?'))
    end
    print(table.concat(lines, '\n'))
end, true)

RegisterCommand('choptest', function(src, args)
    if src == 0 then print('[vp_chopshop] /choptest requer jogador in-game.') return end
    if not IsPlayerAceAllowed(src, 'command.chopshop_admin') then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = 'Sem permissão.' })
        return
    end

    local target = tonumber(args[1]) or src
    if not GetPlayerName(target) then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = 'Jogador ID ' .. tostring(args[1]) .. ' não encontrado.',
        })
        return
    end

    local inv = exports.ox_inventory
    local kit = {
        { item = Config.Items.placeBench,  qty = 1 },
        -- [M4 FIX] Config.Items.fuel foi removido (combustível exclusivo do elevador) — linha removida.
        { item = Config.Items.placeWelder, qty = 1 },
    }
    if Config.ChopTool and Config.ChopTool.Item then
        kit[#kit + 1] = { item = Config.ChopTool.Item, qty = 1 }
    end
    if Config.Jackstand and Config.Jackstand.Enable and Config.Jackstand.Item then
        kit[#kit + 1] = { item = Config.Jackstand.Item, qty = 1 }
    end

    local given, failed = {}, {}
    for _, entry in ipairs(kit) do
        local result = inv:AddItem(target, entry.item, entry.qty)
        if Config.Debug then
            print(('[vp_chopshop] choptest AddItem(%s, %s, %d) → %s'):format(
                target, entry.item, entry.qty, tostring(result)))
        end
        if result and result ~= false then
            given[#given + 1] = entry.item .. ' x' .. entry.qty
        else
            failed[#failed + 1] = entry.item
        end
    end

    local targetName = GetPlayerName(target)
    if #given > 0 then
        local msg = 'Entregue a ' .. targetName .. ': ' .. table.concat(given, ', ')
        if #failed > 0 then msg = msg .. ' | sem espaço: ' .. table.concat(failed, ', ') end
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'vp_chopshop test', description = msg,
            type = #failed == 0 and 'success' or 'warning', duration = 8000,
        })
        if Config.Debug then print('[vp_chopshop] ' .. msg) end
    else
        local msg = 'Falhou tudo para ' .. targetName .. '. Itens registados no ox_inventory? Verifica o console.'
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = msg, duration = 8000 })
        if Config.Debug then print('[vp_chopshop] ' .. msg) end
    end
end, false)

RegisterCommand('chopremove', function(src, args)
    if src ~= 0 and not IsPlayerAceAllowed(src, 'command.chopshop_admin') then return end
    local kind = args[1]
    local id   = tonumber(args[2])
    if not kind or not id then
        print('[vp_chopshop] Usage: /chopremove bench <id>')
        return
    end
    if kind == 'bench' then
        if not benchById(id) then print('[vp_chopshop] Bench not found: ' .. id) return end
        VPChopDbDeleteBench(id)
        removeBenchFromMemory(id)
        broadcastRemoveBench(id)
        print('[vp_chopshop] Bench ' .. id .. ' removed.')
    else
        print('[vp_chopshop] Usage: /chopremove bench <id>')
    end
end, true)
