-- [REMOVED] ServerLifts, ServerLiftsById, LiftMovement, VPChopLiftById:
-- elevador removido do sistema — apenas macaco (jackstand) é necessário para desmanche.

ServerBenches = {}
ServerWelders = {}
local ServerWeldersById = {}
ServerWorldLoaded = false

--- Alarmes veiculares ativos: [netId] = { src = number }
--- Populated quando o alarme dispara; limpo ao desarmar ou ao expirar.
local AlarmActive = {}

local ServerBenchesById = {}
local BenchCraftBusy = {} ---@type table<number, boolean>  src → true when crafting

-- [SEGURANÇA] Rate-limits forward-declared aqui (ANTES do playerDropped) para que a
-- limpeza no disconnect realmente os enxergue. Antes eram declarados local lá embaixo
-- (após o handler), então o playerDropped limpava um global nil — leak + erro no console.
local _chopPartRateLimit    = {}  ---@type table<number, number>  src → expiry GetGameTimer
local _benchCraftRateLimit  = {}  ---@type table<number, number>
-- [GAMEPLAY unificação] _deliverPartRateLimit / DELIVER_PART_MIN_INTERVAL_MS removidos:
-- o callback 'vp_chopshop:deliverPart' deixou de existir (recompensa agora é imediata).
local _alarmDisarmRateLimit = {}  ---@type table<number, number>
local ALARM_DISARM_MIN_INTERVAL_MS = 2000
-- [v1.15 P0-4 / PR-D] Mutex de discard por IDENTIDADE DE SESSÃO (não netId cru).
-- Dois jogadores tentando vender o MESMO veículo → mesma ChopSession → mesmo lock
-- → no máximo um fluxo terminal. value = netId (p/ limpeza órfã no entityRemoved).
local DiscardBusy = {} ---@type table<string, integer>  sessionId → netId durante o discard
-- [v1.15 PR-D hardening] QUARENTENA fail-closed: pagamento COMMITADO + Complete FALHOU
-- + compensação FALHOU. A sessão fica READY_FOR_DISCARD + FROZEN; nenhum novo discard
-- pode pagar de novo. Limpa só por entityRemoved (ou admin futuro — não nesta PR).
local DiscardQuarantine = {} ---@type table<string, integer>  sessionId → netId

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


AddEventHandler('playerDropped', function()
    local src = source
    BenchCraftBusy[src] = nil
    _chopPartRateLimit[src] = nil
    _benchCraftRateLimit[src] = nil
    -- [GAMEPLAY unificação] _deliverPartRateLimit[src] e VPChopClaimPendingReward(src) removidos:
    -- não há mais recompensa pendente nem callback de entrega (recompensa é imediata no chop).
    _alarmDisarmRateLimit[src] = nil
    -- Limpar alarme do jogador que saiu (timeout silencioso; sem dispatch)
    for netId, data in pairs(AlarmActive) do
        if data.src == src then
            AlarmActive[netId] = nil
        end
    end
end)

-- [v1.15 P0-1] Handler 'vp_chopshop:server:addTyreToTruck' REMOVIDO.
-- Era uma 2ª implementação concorrente da carga de pneu no truck (a outra em
-- server/fence.lua) e incrementava ServerTyreCounts sem lastro em item/crédito.
-- Unificado em 'vp_chopshop:tyre:loadToTruck' (server/fence.lua), que consome um
-- crédito PlayerTyreStock ganho ao remover uma roda legítima via chopPart.

--- Cancela o alarme de um veículo quando o jogador o desarma manualmente.
--- Valida server-side que o jogador possui o item exigido (trust-no-client).
RegisterNetEvent('vp_chopshop:server:alarmDisarmed', function(netId)
    local src = source
    if not IsValidSource(src) then return end

    -- [SEGURANÇA] Rate limit anti-flood (cada chamada faz lookup + export ox_inventory)
    local nowAD = GetGameTimer()
    if _alarmDisarmRateLimit[src] and nowAD < _alarmDisarmRateLimit[src] then return end
    _alarmDisarmRateLimit[src] = nowAD + ALARM_DISARM_MIN_INTERVAL_MS

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
    if not IsValidSource(source) then return nil end
    local tries = 0
    while not ServerWorldLoaded and tries < 200 do
        Wait(50)
        tries = tries + 1
    end
    return serializeWorld()
end)

lib.callback.register('vp_chopshop:placeBench', function(source, payload)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    if type(payload) ~= 'table' then return { ok = false, err = 'coords' } end
    local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z)
    local heading = tonumber(payload.heading) or 0.0
    if not x or not y or not z then return { ok = false, err = 'coords' } end
    local coords = vector3(x, y, z)
    if not ValidateMapCoords(coords) then return { ok = false, err = 'coords' } end
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

-- Rate-limit de segurança: bloqueia spam de vp_chopshop:chopPart (independente do ChopCooldownSeconds)
-- (_chopPartRateLimit declarado no topo do arquivo — forward declaration para o playerDropped)
local CHOP_PART_MIN_INTERVAL_MS = 2000  -- mínimo 2s entre chamadas por jogador

--- [v1.15 PR-F] Corpo de DOMÍNIO do chop de peça — extraído do callback legacy p/
--- ser reutilizado pelo executor da ActionSession (server/action/base_tyre.lua).
--- Assume: `source` pronto, `netId`/`partKey` já validados (tipo/tamanho), ferramenta
--- já verificada, cooldown já checado pelo chamador. Faz: cooldown mark → commit
--- (VPChopServerTryPart) → tool durability → TyreEntitlement.Issue (tyre) → rewards
--- → ambush → PART_CHOPPED → discord → breakPart broadcast → evidence/tyre window
--- → alarm. Sem rate-limit / sem gate de action (isso é do chamador).
--- @return { ok:boolean, err:string|nil, tyreEntitlementId:string|nil }
function VPChopChopPartCommit(source, netId, partKey)
    -- Marcar cooldown ANTES do yield em VPChopServerTryPart para evitar race condition
    VPChopChopCooldownMark(source)

    local ok, err, rewards = VPChopServerTryPart(source, netId, partKey)
    if not ok then return { ok = false, err = err } end

    -- Consumir durabilidade da ferramenta
    VPChopConsumeTool(source, false)

    -- [v1.15 PR-E] Roda: emitir o TYRE ENTITLEMENT logo após o commit (idempotente
    -- por sessão+peça). O id volta ao client SÓ p/ tyres; o resto continua compat.
    -- Falha da emissão NÃO derruba o chop — a peça já está committed.
    local tyreEntitlementId
    do
        if VPChopPartGtaClass(partKey) == 'tyre' then
            local s = ChopSession.GetByVehicle(netId)
            if s then
                local teId = TyreEntitlement.Issue(s.id, source, partKey)
                if teId then tyreEntitlementId = teId end
            end
        end
    end

    -- [GAMEPLAY unificação] Recompensa IMEDIATA (igual às fases 2-4 em advanced_chop.lua):
    -- itens caem no inventário na hora. Se o inventário estiver cheio, notificar e seguir —
    -- a peça já foi marcada como chopped (MarkChopped em VPChopServerTryPart), NÃO fazer rollback.
    -- Sistema de "recompensa pendente entregue na bancada" removido.
    local invFull = false
    for itemName, amount in pairs(rewards) do
        if amount and amount > 0 then
            if not InvAdd(source, itemName, amount) then
                invFull = true
            end
        end
    end
    if invFull then
        TriggerClientEvent('ox_lib:notify', source, {
            type = 'warning',
            description = L('reward_inv_full'),
        })
    end

    -- Resolver placa server-side (trust-no-client)
    local vehForPlate = NetworkGetEntityFromNetworkId(netId)
    local plate = (vehForPlate and vehForPlate ~= 0 and DoesEntityExist(vehForPlate))
        and GetVehicleNumberPlateText(vehForPlate):gsub('%s+', '')
        or ''

    -- [AUDIT M2] Emboscada decidida SERVER-SIDE após a recompensa. Antes dependia do client
    -- chamar 'vp_chopshop:maybeAmbush' — um cheater que nunca chamava nunca sofria emboscada.
    if Config.Ambush and Config.Ambush.Enable then
        pcall(VPChopAmbushMaybe, source, netId, plate)  -- nunca deixar a emboscada quebrar o retorno do chop
    end

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

    -- [EVIDENCE] Deixar vestígio forense no local do veículo (digital + DNA vinculados ao
    -- criminoso). Reutiliza vehEnt/vehPos já resolvidos server-side acima (trust-no-client).
    -- `plate` (visível, resolvido acima) → placa REAL via VPChopMDT para o heat scaling.
    -- Fallback de coords: ped do jogador se o veículo não pôde ser resolvido.
    do
        local evCoords = vehPos or GetEntityCoords(GetPlayerPed(source))
        local realPlate = (plate ~= '' and VPChopMDT.GetRealPlate(plate)) or plate
        VPChopLeaveEvidence(source, evCoords, 'chop_part', realPlate)
        -- [TYRE] Armar a janela de marca de pneu (mesmo ponto do crime; reusa o hook).
        if Config.TyreMarks and Config.TyreMarks.Enable then
            local armMs = (Config.TyreMarks.ArmWindowSeconds or 45) * 1000
            -- [AUDIT-FIX H1] Arma TAMBÉM a janela server-side (gate anti-cheat do createTyreMark).
            VPChopArmTyreWindow(source, armMs)
            TriggerClientEvent('vp_chopshop:armTyreMark', source, armMs)
        end
    end

    -- Sistema de alarme: rolar chance na primeira peça removida deste veículo.
    local alarmCfg = Config.Alarm
    if alarmCfg and alarmCfg.Enable and not AlarmActive[netId] then
        local vehForAlarm = NetworkGetEntityFromNetworkId(netId)
        if vehForAlarm and vehForAlarm ~= 0 and DoesEntityExist(vehForAlarm) then
            local class = 0
            if rawget(_G, 'GetVehicleClass') then
                local ok, vc = pcall(GetVehicleClass, vehForAlarm)
                if ok and type(vc) == 'number' then class = vc end
            elseif rawget(_G, 'GetVehicleClassFromName') then
                local model = GetEntityModel(vehForAlarm)
                if model and model ~= 0 then
                    local ok, vc = pcall(GetVehicleClassFromName, model)
                    if ok and type(vc) == 'number' and vc >= 0 then class = vc end
                end
            end
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
                        -- [H4 FIX] Original chopper may have disconnected during the disarm window.
                        -- Police dispatch must still fire — find any nearby online player.
                        local dispatchTarget = GetPlayerName(capturedSrc) and capturedSrc
                        if not dispatchTarget then
                            local vehEnt = NetworkGetEntityFromNetworkId(capturedNetId)
                            local vehPos = (vehEnt and vehEnt ~= 0 and DoesEntityExist(vehEnt))
                                           and GetEntityCoords(vehEnt) or nil
                            for _, pid in ipairs(GetPlayers()) do
                                local pidN = tonumber(pid)
                                if pidN and GetPlayerName(pidN) then
                                    if not vehPos then
                                        dispatchTarget = pidN; break
                                    end
                                    local pped = GetPlayerPed(pidN)
                                    if pped and pped ~= 0 and #(GetEntityCoords(pped) - vehPos) < 200.0 then
                                        dispatchTarget = pidN; break
                                    end
                                end
                            end
                        end
                        if dispatchTarget then
                            TriggerClientEvent('vp_chopshop:client:alarmExpired', dispatchTarget, capturedNetId)
                        end
                    end
                end)
            end
        end
    end

    return { ok = true, tyreEntitlementId = tyreEntitlementId }
end

lib.callback.register('vp_chopshop:chopPart', function(source, netId, partKey)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end

    -- Rate limit de segurança (anti-flood independente do cooldown configurável)
    local now = GetGameTimer()
    if _chopPartRateLimit[source] and now < _chopPartRateLimit[source] then
        LogSuspicious(source, 'chopPart', 'Rate limit excedido (flood de callback)')
        return { ok = false, err = 'cooldown', wait = 2 }
    end
    _chopPartRateLimit[source] = now + CHOP_PART_MIN_INTERVAL_MS

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end

    if type(partKey) ~= 'string' or #partKey > 32 or #partKey < 3 then
        return { ok = false, err = 'part' }
    end

    local cd = VPChopChopCooldownRemaining(source)
    if cd > 0 then return { ok = false, err = 'cooldown', wait = cd } end

    if not VPChopHasTool(source, false) then
        return { ok = false, err = 'no_saw' }
    end

    -- [v1.15 PR-F/G] BASE TYRE passa OBRIGATORIAMENTE pela ActionSession quando o
    -- modo está ativo (VPChopActionModeTyre). Um executor NÃO bypassa start/complete
    -- chamando este callback direto p/ wheel_*. Kill-switch: RequireBaseTyres=false.
    if VPChopActionModeTyre() and VPChopPartGtaClass(partKey) == 'tyre' then
        return { ok = false, err = 'action_required' }
    end

    local res = VPChopChopPartCommit(source, netId, partKey)
    if not res.ok then return { ok = false, err = res.err } end
    return { ok = true, tyreEntitlementId = res.tyreEntitlementId }
end)

-- Rate-limit de segurança para benchCraft (_benchCraftRateLimit declarado no topo)
local BENCH_CRAFT_MIN_INTERVAL_MS = 3000

lib.callback.register('vp_chopshop:benchCraft', function(source, benchId, recipeIndex)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    local nowBC = GetGameTimer()
    if _benchCraftRateLimit[source] and nowBC < _benchCraftRateLimit[source] then
        return { ok = false, err = 'busy' }
    end
    _benchCraftRateLimit[source] = nowBC + BENCH_CRAFT_MIN_INTERVAL_MS
    if BenchCraftBusy[source] then return { ok = false, err = 'busy' } end
    BenchCraftBusy[source] = true
    benchId = tonumber(benchId)  -- [AUDIT M3] sanitizar antes do lookup (consistência com pickupBench)
    local bench = benchId and benchById(benchId)
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

--- [PHYSICAL CARRY] Processamento de peça física carregada na bancada de trabalho
lib.callback.register('vp_chopshop:benchProcessPart', function(source, benchId, partKey)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    benchId = tonumber(benchId)
    local bench = benchId and benchById(benchId)
    if not bench then return { ok = false, err = 'bench' } end
    if not ValidatePlayerNearCoords(source, bench.coords) then return { ok = false, err = 'distance' } end
    if not partKey or type(partKey) ~= 'string' then return { ok = false, err = 'part' } end

    if partKey == 'adv_engine' then
        local baseParts = (Config.AdvancedChop and Config.AdvancedChop.EngineReward and Config.AdvancedChop.EngineReward.amount) or 5
        VPChopAddStolenCarParts(source, 0, baseParts)
        InvAdd(source, 'metalscrap', 4)
        InvAdd(source, 'steel', 3)
    elseif Config.CarPartRewards and Config.CarPartRewards[partKey] then
        for itemName, cfg in pairs(Config.CarPartRewards[partKey]) do
            local chance = tonumber(cfg.chance) or 1.0
            if math.random() <= chance then
                local amt = math.random(1, cfg.amount or 1)
                InvAdd(source, itemName, amt)
            end
        end
        VPChopAddStolenCarParts(source, 0, 1)
    else
        VPChopAddStolenCarParts(source, 0, 1)
        InvAdd(source, 'metalscrap', 3)
        InvAdd(source, 'steel', 2)
        InvAdd(source, 'aluminum', 2)
    end

    return { ok = true }
end)

--- [v1.15 PR-D hardening] Retries locais de deleção de mundo. Cada tentativa REVALIDA:
---   1. sessão continua COMPLETED (tombstone);
---   2. a entidade atual ainda PROVA ser a original — via
---      ChopSession.ResolveBoundVehicleForCleanup (VSID/marker/model/ownedId).
---      netId reciclado noutro veículo → devolve nil → retry ABORTA (nunca deleta o
---      veículo novo);
---   3. framework esperado ainda vale (BridgeDeleteWorldVehicle fail-closa em race);
---   4. DisablePersistence confirmado (idem).
--- NUNCA apaga o tombstone. Sem loop infinito: 3 tentativas.
local function scheduleDeleteRetry(sessionId, expectedFw, attemptsLeft)
    attemptsLeft = attemptsLeft or 3
    SetTimeout(2500, function()
        local veh, reason = ChopSession.ResolveBoundVehicleForCleanup(sessionId)
        if not veh then
            -- identidade não confirmável / sessão sumiu / já não é tombstone → parar.
            if reason == 'identity_mismatch' or reason == 'identity_unproven' then
                print(('[vp_chopshop][discard] retry ABORTADA (session %s, %s): identidade da entidade não pode ser provada — auto-delete cancelado, tombstone + cleanupPending preservados.'):format(sessionId, reason))
            end
            return
        end
        local d = BridgeDeleteWorldVehicle(veh, { expectedFramework = expectedFw })
        if not d.existsAfter then return end   -- sucesso → entityRemoved → CleanupVehicle
        if d.retryable and attemptsLeft > 1 then
            scheduleDeleteRetry(sessionId, expectedFw, attemptsLeft - 1)
        else
            print(('[vp_chopshop][discard] session %s: deleção de mundo ainda pendente (method=%s) após retries — tombstone COMPLETED + cleanupPending preservados.'):format(sessionId, d.method))
        end
    end)
end

lib.callback.register('vp_chopshop:discardVehicle', function(source, netId)
    if not (Config.Discard and Config.Discard.Enable) then return { ok = false, err = 'disabled' } end
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    netId = tonumber(netId)
    if not netId then return { ok = false, err = 'args' } end

    local minParts = math.floor(tonumber((Config.Discard or {}).MinPartsToDiscard) or 4)

    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) then return { ok = false, err = 'vehicle' } end

    local maxDist = (Config.VehicleNearLiftRadius or 5.0) + 2.0
    if not ValidatePlayerNearVehicle(source, veh, maxDist) then return { ok = false, err = 'distance' } end

    -- [PR-D] Resolver a ChopSession ANTES do lock (identidade do mutex).
    local sessionId = VPChopDiscardState.resolve(netId)
    if not sessionId then
        -- Sem sessão ativa = nenhuma peça committed = não há o que descartar.
        return { ok = false, err = 'parts_min', count = 0, min = minParts }
    end

    -- [PR-D hardening] Quarentena fail-closed: pagamento commitado + Complete + compensação
    -- todos falharam antes. Nenhum novo discard paga de novo até a entidade sumir.
    if DiscardQuarantine[sessionId] then return { ok = false, err = 'transaction_locked' } end

    -- [P0-4 / PR-D] Mutex por identidade de sessão. Sem yield entre check e set.
    if DiscardBusy[sessionId] then return { ok = false, err = 'processing' } end
    DiscardBusy[sessionId] = netId
    local function releaseDiscard(res) DiscardBusy[sessionId] = nil; return res end

    -- [PR-D] OWNERSHIP GATE — antes de qualquer pagamento/transição.
    -- BridgeResolveVehiclePersistence só LÊ; dúvida ⇒ 'unknown' ⇒ fail-closed.
    local persistence  = BridgeResolveVehiclePersistence(veh, 'discard')
    local ownedPolicy  = (Config.Discard or {}).OwnedPolicy or 'deny'
    if persistence.status ~= 'not_owned' then
        -- 'owned' ou 'unknown'. 'destroy' (apagar registro persistente + compensar)
        -- NÃO é implementado nesta PR → qualquer política que não seja um destroy
        -- funcional resulta em DENY. Preferimos negar a destruir um player vehicle.
        if persistence.status == 'unknown' or Config.Debug then
            print(('[vp_chopshop][discard] netId %s: persistence=%s (src=%s, policy=%s) → DENY')
                :format(netId, persistence.status, persistence.source, tostring(ownedPolicy)))
        end
        return releaseDiscard({ ok = false, err = 'owned', persistence = persistence.status })
    end

    -- [PR-D] CONTAGEM UNIFICADA (base + advanced) — mudança DELIBERADA desta PR.
    local counts = VPChopDiscardState.getCounts(sessionId)
    if counts.total < minParts then
        return releaseDiscard({ ok = false, err = 'parts_min', count = counts.total, min = minParts,
                                base = counts.base, advanced = counts.advanced })
    end

    -- [v1.16 P0.4] BARREIRA PERSISTENTE anti re-discard pós-restart de resource.
    -- O tombstone da ChopSession é in-memory: `ensure vp_chopshop` o apaga e a MESMA
    -- carcaça poderia ser re-chopada (sessão nova) e descartada de novo → 2º payout.
    -- O ledger no DB lembra por (net_id, model) dentro do TTL. Fail-OPEN: erro de
    -- MySQL não bloqueia — a dupe que isto fecha é rara (mesma carcaça, pós-restart).
    if (Config.RestartRecovery or {}).Enable ~= false
        and VPChopCarcassLedger and VPChopCarcassLedger.ready() then
        local already, prevOp = VPChopCarcassLedger.alreadyProcessed(netId, GetEntityModel(veh))
        if already then
            if Config.Debug then
                print(('[vp_chopshop][discard] netId %s: já consta no ledger (op=%s) → DENY already_discarded')
                    :format(netId, tostring(prevOp)))
            end
            return releaseDiscard({ ok = false, err = 'already_discarded' })
        end
    end

    -- Calcular payout (INALTERADO — esta PR não é balance de economia)
    local model  = GetEntityModel(veh)
    local payout = math.floor(tonumber((Config.Discard or {}).DefaultPayout) or 1500)
    local byModel = Config.Discard and Config.Discard.PayoutByModel
    if byModel and byModel[model] then
        payout = math.floor(tonumber(byModel[model]) or payout)
    end
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
    local maxPayout = math.floor((tonumber((Config.Discard or {}).DefaultPayout) or 1500) * 10)
    payout = math.min(payout, maxPayout)

    -- [PR-D] BEGIN DISCARD → SetState(READY_FOR_DISCARD) → FREEZE (MarkPart/LockPart
    -- passam a recusar 'discarding'). Protege a contagem que autorizou o payout
    -- durante um eventual yield de BridgeAddCash.
    local bOk = VPChopDiscardState.begin(sessionId)
    if not bOk then return releaseDiscard({ ok = false, err = 'transaction' }) end

    -- PAYMENT
    if not BridgeAddCash(source, payout, 'discard_payout') then
        VPChopDiscardState.rollback(sessionId)   -- READY_FOR_DISCARD → DISMANTLING; nada perdido
        return releaseDiscard({ ok = false, err = 'payment' })
    end

    -- [PR-D] COMPLETE checado. Com sessão resolvida + lock exclusivo + estado
    -- congelado, Complete() é determinístico; a compensação abaixo é fallback
    -- excepcional (não deve ocorrer).
    local cOk = VPChopDiscardState.complete(sessionId)
    if not cOk then
        -- [PR-D hardening] Pagamento COMMITADO + Complete FALHOU. Tentar compensar e
        -- REFLETIR o resultado real — nunca escrever "compensado" sem confirmar.
        local compensated = BridgeRemoveCash(source, payout, 'discard_compensation')
        if compensated then
            -- Economicamente de volta ao zero → retry legítimo pode ocorrer depois.
            VPChopDiscardState.rollback(sessionId)   -- READY_FOR_DISCARD → DISMANTLING (descongela)
            LogSuspicious(source, 'discardVehicle',
                ('COMPLETE FAILED / PAYOUT COMPENSATED ($%d) — session %s → rollback DISMANTLING'):format(payout, sessionId))
            return releaseDiscard({ ok = false, err = 'transaction' })
        end
        -- Compensação FALHOU: pagamento ficou. NÃO liberar p/ novo payout.
        -- Sessão permanece READY_FOR_DISCARD + FROZEN + em QUARENTENA.
        DiscardQuarantine[sessionId] = netId
        LogSuspicious(source, 'discardVehicle',
            ('SEVERE: PAYMENT COMMITTED + COMPLETE FAILED + COMPENSATION FAILED ($%d) — session %s QUARANTINED (frozen, no re-payout)'):format(payout, sessionId))
        return releaseDiscard({ ok = false, err = 'transaction_locked' })
    end

    -- Ponto terminal atingido: a partir daqui NÃO reabrimos a sessão.
    AlarmActive[netId] = nil

    -- [PR-D hardening] preserva o framework resolvido no ownership gate — se o
    -- qbx_core parar entre aqui e o delete, BridgeDeleteWorldVehicle fail-closa
    -- (não cai silenciosamente p/ DeleteEntity nativo).
    local del = BridgeDeleteWorldVehicle(veh, { expectedFramework = persistence.framework })

    -- CAR_DISCARDED: 1×, SÓ após o terminal commit.
    TriggerEvent(VPChopEvt.CAR_DISCARDED, source, netId, plate, payout)

    local jackItem = (Config.Jackstand and Config.Jackstand.Item) or 'chopshop_jackstand'
    if jackItem and type(InvAdd) == 'function' then
        InvAdd(source, jackItem, 1)
    end

    -- [v1.16 P0.4] persiste no ledger. cleanup_pending = a carcaça ficou no mundo
    -- (del falhou). Se foi deletada agora, a linha ainda serve de barreira até o TTL
    -- (protege contra um netId reciclado rápido no MESMO frame de spawn — improvável,
    -- mas barato). É limpa em entityRemoved / no sweep de boot.
    if (Config.RestartRecovery or {}).Enable ~= false
        and VPChopCarcassLedger and VPChopCarcassLedger.ready() then
        local okv, vsid = pcall(function() return Entity(veh).state.vpChopVsid end)
        VPChopCarcassLedger.mark(netId, model, (okv and vsid) or nil, 'discard',
            ('src:%s'):format(source), del.existsAfter == true)
    end

    if del.existsAfter then
        -- Entidade não sumiu. Jogador JÁ foi pago; sessão JÁ é COMPLETED (tombstone).
        -- Não é retry-able discard. Retries de CLEANUP vinculadas à identidade da sessão.
        print(('[vp_chopshop][discard] session %s (netId %s): BridgeDeleteWorldVehicle não removeu a entidade (method=%s) — cleanupPending, tombstone preservado.')
            :format(sessionId, netId, del.method))
        scheduleDeleteRetry(sessionId, persistence.framework)
        return releaseDiscard({ ok = true, payout = payout, bonus = appliedBonus, cleanupPending = true })
    end

    return releaseDiscard({ ok = true, payout = payout, bonus = appliedBonus })
end)

-- [v1.15 P0-4 / PR-D] Limpa mutex de discard órfão se a entidade sumir por outra via.
AddEventHandler('entityRemoved', function(entity)
    local nid = NetworkGetNetworkIdFromEntity(entity)
    if not nid or nid == 0 then return end
    for sid, lockedNet in pairs(DiscardBusy) do
        if lockedNet == nid then DiscardBusy[sid] = nil end
    end
    -- [PR-D hardening] a entidade quarantined enfim sumiu → libera a quarentena.
    for sid, qNet in pairs(DiscardQuarantine) do
        if qNet == nid then
            DiscardQuarantine[sid] = nil
            print(('[vp_chopshop][discard] session %s: quarentena liberada (entidade removida).'):format(sid))
        end
    end
    -- [v1.16 P0.4] carcaça saiu do mundo → sai do ledger (barreira não é mais necessária).
    -- CreateThread: o handler de entityRemoved não é coroutine; MySQL.await precisa de
    -- contexto de yield. O DELETE é best-effort — se falhar, o TTL expira a linha.
    if VPChopCarcassLedger and VPChopCarcassLedger.ready() then
        CreateThread(function() VPChopCarcassLedger.clear(nid, nil) end)
    end
end)

-- [AUDIT M2] Callback 'vp_chopshop:maybeAmbush' REMOVIDO. A emboscada agora é disparada
-- server-side dentro do callback 'vp_chopshop:chopPart' (acima), após a recompensa, usando
-- o netId/plate já resolvidos — o client não decide mais se/quando sofre emboscada.

lib.callback.register('vp_chopshop:npcAcceptMission', function(source)
    if not IsValidSource(source) then return { ok=false } end
    return VPChopNpcMissionAccept(source)
end)

-- [H3 FIX] vp_chopshop:npcBuy removed — dead callback. All clients now call
-- vp_chopshop:fence:buyBench (validates against rotative fence location).

lib.callback.register('vp_chopshop:pickupBench', function(source, benchId)
    if not ServerPlayerIsReady(source) then return { ok = false, err = 'player' } end
    benchId = tonumber(benchId)
    if not benchId then return { ok = false, err = 'args' } end
    local bench = benchById(benchId)
    if not bench then return { ok = false, err = 'bench' } end
    if not ValidatePlayerNearCoords(source, bench.coords) then return { ok = false, err = 'distance' } end

    local key = ServerChopPlayerKey(source)
    local isPlacer = not bench.placed_by or bench.placed_by == key
    local isAdmin = IsPlayerAceAllowed(source, 'command.chopshop_admin')
    if not isPlacer and not isAdmin then
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
    if type(payload) ~= 'table' then return { ok = false, err = 'coords' } end
    local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z)
    local heading = tonumber(payload.heading) or 0.0
    if not x or not y or not z then return { ok = false, err = 'coords' } end
    local coords = vector3(x, y, z)
    if not ValidateMapCoords(coords) then return { ok = false, err = 'coords' } end
    if not ValidatePlayerPlacementRange(source, coords) then return { ok = false, err = 'distance' } end
    if isWelderTooClose(coords) then return { ok = false, err = 'too_close' } end

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
    local isPlacer = not w.placed_by or w.placed_by == key
    local isAdmin = IsPlayerAceAllowed(source, 'command.chopshop_admin')
    if not isPlacer and not isAdmin then
        return { ok = false, err = 'unauthorized' }
    end

    local item = Config.Items.placeWelder
    if not InvAdd(source, item, 1) then return { ok = false, err = 'inventory' } end

    VPChopDbDeleteWelder(welderId)
    removeWelderFromMemory(welderId)
    broadcastRemoveWelder(welderId)
    return { ok = true }
end)

RegisterCommand('chopbenches', function(src, _)
    if src ~= 0 and not IsPlayerAceAllowed(src, 'command.chopshop_admin') then return end
    local lines = {
        ('[vp_chopshop] Bancadas (%d) | Soldadoras (%d):'):format(#ServerBenches, #ServerWelders),
    }
    for _, bench in ipairs(ServerBenches) do
        lines[#lines + 1] = ('  [BENCH]  id=%-4d pos=%.1f,%.1f,%.1f by=%s'):format(
            bench.id, bench.coords.x, bench.coords.y, bench.coords.z,
            tostring(bench.placed_by or '?'))
    end
    for _, w in ipairs(ServerWelders) do
        lines[#lines + 1] = ('  [WELDER] id=%-4d pos=%.1f,%.1f,%.1f by=%s'):format(
            w.id, w.coords.x, w.coords.y, w.coords.z,
            tostring(w.placed_by or '?'))
    end
    local msg = table.concat(lines, '\n')
    if src == 0 then
        print(msg)
    else
        print(msg)
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'inform',
            title = 'vp_chopshop props',
            description = ('Bancadas: %d | Soldadoras: %d (detalhes no console F8)'):format(#ServerBenches, #ServerWelders),
        })
    end
end, false)

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

    local kit = {
        { item = Config.Items.placeBench,  qty = 1 },
        { item = Config.Items.placeWelder, qty = 1 },
    }
    -- [M2 FIX] Config.ChopTool never existed; iterate Config.Tools (the real tool registry).
    for toolName, _ in pairs(Config.Tools or {}) do
        kit[#kit + 1] = { item = toolName, qty = 1 }
    end
    if Config.Jackstand and Config.Jackstand.Enable and Config.Jackstand.Item then
        kit[#kit + 1] = { item = Config.Jackstand.Item, qty = 1 }
    end

    local given, failed = {}, {}
    for _, entry in ipairs(kit) do
        local ok = InvAdd(target, entry.item, entry.qty)
        if ok then
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
    if src ~= 0 and not IsPlayerAceAllowed(src, 'command.chopshop_admin') then
        if src ~= 0 then TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = 'Sem permissão.' }) end
        return
    end
    local kind = args[1]
    local id   = tonumber(args[2])
    if not kind or not id then
        local msg = 'Uso: /chopremove <bench|welder> <id>'
        if src == 0 then print('[vp_chopshop] ' .. msg) else TriggerClientEvent('ox_lib:notify', src, { type = 'inform', description = msg }) end
        return
    end
    if kind == 'bench' or kind == 'bancada' then
        if not benchById(id) then
            local msg = 'Bancada ID ' .. id .. ' não encontrada.'
            if src == 0 then print('[vp_chopshop] ' .. msg) else TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = msg }) end
            return
        end
        VPChopDbDeleteBench(id)
        removeBenchFromMemory(id)
        broadcastRemoveBench(id)
        local msg = 'Bancada ID ' .. id .. ' removida do mundo e banco.'
        if src == 0 then print('[vp_chopshop] ' .. msg) else TriggerClientEvent('ox_lib:notify', src, { type = 'success', description = msg }) end
    elseif kind == 'welder' or kind == 'solda' or kind == 'compressor' then
        if not welderById(id) then
            local msg = 'Soldadora ID ' .. id .. ' não encontrada.'
            if src == 0 then print('[vp_chopshop] ' .. msg) else TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = msg }) end
            return
        end
        VPChopDbDeleteWelder(id)
        removeWelderFromMemory(id)
        broadcastRemoveWelder(id)
        local msg = 'Soldadora ID ' .. id .. ' removida do mundo e banco.'
        if src == 0 then print('[vp_chopshop] ' .. msg) else TriggerClientEvent('ox_lib:notify', src, { type = 'success', description = msg }) end
    else
        local msg = 'Uso: /chopremove <bench|welder> <id>'
        if src == 0 then print('[vp_chopshop] ' .. msg) else TriggerClientEvent('ox_lib:notify', src, { type = 'inform', description = msg }) end
    end
end, false)

RegisterCommand('chopclear', function(src, args)
    if src ~= 0 and not IsPlayerAceAllowed(src, 'command.chopshop_admin') then
        if src ~= 0 then TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = 'Sem permissão.' }) end
        return
    end

    local filter = args[1] or 'all'
    local benchesRemoved, weldersRemoved = 0, 0

    if filter == 'all' or filter == 'bench' or filter == 'benches' or filter == 'bancada' then
        local benchIds = {}
        for _, b in ipairs(ServerBenches) do benchIds[#benchIds + 1] = b.id end
        for _, id in ipairs(benchIds) do
            VPChopDbDeleteBench(id)
            removeBenchFromMemory(id)
            broadcastRemoveBench(id)
            benchesRemoved = benchesRemoved + 1
        end
    end

    if filter == 'all' or filter == 'welder' or filter == 'welders' or filter == 'solda' or filter == 'compressor' then
        local welderIds = {}
        for _, w in ipairs(ServerWelders) do welderIds[#welderIds + 1] = w.id end
        for _, id in ipairs(welderIds) do
            VPChopDbDeleteWelder(id)
            removeWelderFromMemory(id)
            broadcastRemoveWelder(id)
            weldersRemoved = weldersRemoved + 1
        end
    end

    TriggerClientEvent('vp_chopshop:client:clearWorldProps', -1, filter)

    local msg = ('[vp_chopshop] Limpeza concluída: %d bancada(s) e %d soldadora(s) removidas.'):format(benchesRemoved, weldersRemoved)
    if src == 0 then
        print(msg)
    else
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'success',
            title = 'vp_chopshop admin',
            description = ('Removidos: %d bancada(s), %d soldadora(s)'):format(benchesRemoved, weldersRemoved),
        })
        print(('[vp_chopshop] Admin %s executou /chopclear (%s)'):format(GetPlayerName(src), filter))
    end
end, false)
