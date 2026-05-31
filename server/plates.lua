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

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [FASE2 placas] FORJAR + APLICAR placa falsa  |  [FASE3] reversão segura   ║
-- ╚══════════════════════════════════════════════════════════════════════════╝

-- ─── Estado por jogador (cooldowns das novas ações) ──────────────────────────
local ForgeCooldown  = {} ---@type table<number, number>  src → expiry (GetGameTimer)
local ApplyCooldown  = {} ---@type table<number, number>
local RemoveCooldown = {} ---@type table<number, number>

AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1] capturar antes de qualquer yield
    ForgeCooldown[src]  = nil
    ApplyCooldown[src]  = nil
    RemoveCooldown[src] = nil
end)

--- Cooldowns (segundos → ms) com fallbacks seguros.
local function forgeCdMs()  return (tonumber(Config.Plates and Config.Plates.ForgeCooldownSeconds)  or 15) * 1000 end
local function applyCdMs()  return (tonumber(Config.Plates and Config.Plates.ApplyCooldownSeconds)  or 5)  * 1000 end
local function removeCdMs() return (tonumber(Config.Plates and Config.Plates.RemoveCooldownSeconds) or 3)  * 1000 end

--- Normaliza/valida formato de placa GTA (alfanumérico, ≤ 8). Devolve uppercase sem espaços.
---@param raw any
---@return string|nil
local function sanitizePlate(raw)
    if type(raw) ~= 'string' then return nil end
    local p = raw:gsub('%s+', ''):upper()
    if p == '' or #p > 8 then return nil end
    -- Apenas A-Z e 0-9 (rejeita injeção/metadata maliciosa de lua executor)
    if p:find('[^A-Z0-9]') then return nil end
    return p
end

-- ─── Bancada mais próxima do jogador (gate de forja) ─────────────────────────
--- A forja exige estar JUNTO a uma bancada (ServerBenches + ValidatePlayerNearCoords),
--- exatamente como o craft normal. Não confiamos em índice vindo do client.
---@param src number
---@return boolean
local function isPlayerNearAnyBench(src)
    if not ServerBenches then return false end
    for _, bench in ipairs(ServerBenches) do
        if bench and bench.coords and ValidatePlayerNearCoords(src, bench.coords) then
            return true
        end
    end
    return false
end

-- ─── Callback: FORJAR placa falsa ─────────────────────────────────────────────
-- Fluxo DEDICADO (fora de Config.BenchRecipes) porque o output herda a placa do
-- `stolen_plate` específico. Consome a placa roubada escolhida + insumos, com ROLLBACK
-- atômico (padrão de server/bench.lua), e devolve `fake_plate` com metadata { plate }.
lib.callback.register('vp_chopshop:forgeFakePlate', function(src, sourcePlate)
    -- Feature desligada
    if not Config.Plates or not Config.Plates.Enable then return { ok = false, err = 'disabled' } end

    -- Guards de fonte + jogador carregado
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    -- Cooldown anti-farm
    local now = GetGameTimer()
    if ForgeCooldown[src] and now < ForgeCooldown[src] then return { ok = false, err = 'cooldown' } end

    -- Proximidade de bancada (verdade server-side — nunca confiar no client)
    if not isPlayerNearAnyBench(src) then return { ok = false, err = 'distance' } end

    -- Gate de tier (Fase 2 = tier 2 por padrão)
    local needTier = tonumber(Config.Plates.ForgeTier) or 2
    local prog = VPChopGetProgression(src)
    if not prog or prog.tier < needTier then return { ok = false, err = 'tier' } end

    -- Resolver a `stolen_plate` a usar. O client pode mandar a placa-fonte escolhida;
    -- validamos o formato e CONFIRMAMOS que o jogador realmente possui esse item com
    -- essa metadata (Search 'slots' → metadata.plate). Sem confiar no client.
    local wantPlate = sanitizePlate(sourcePlate)  -- pode ser nil (pega a primeira disponível)
    local slots = exports.ox_inventory:Search(src, 'slots', 'stolen_plate')
    if type(slots) ~= 'table' or #slots == 0 then return { ok = false, err = 'no_source' } end

    local chosenMeta, chosenPlate
    for i = 1, #slots do
        local s = slots[i]
        local meta = s and s.metadata
        local pl = meta and sanitizePlate(meta.plate)
        if pl then
            if not wantPlate or wantPlate == pl then
                chosenMeta, chosenPlate = meta, pl
                break
            end
        end
    end
    if not chosenPlate then return { ok = false, err = 'no_source' } end

    -- Conferir insumos ANTES de remover qualquer coisa
    local inputs = Config.Plates.ForgeInputs or {}
    for itemName, need in pairs(inputs) do
        if InvCount(src, itemName) < (tonumber(need) or 0) then return { ok = false, err = 'inputs' } end
    end

    -- ── Remoção atômica com rollback (padrão server/bench.lua) ──
    -- 1) Consumir a `stolen_plate` ESPECÍFICA (match por metadata → remove a instância certa).
    local removedStolen = exports.ox_inventory:RemoveItem(src, 'stolen_plate', 1, chosenMeta) == true
    if not removedStolen then return { ok = false, err = 'remove' } end

    -- 2) Consumir insumos; se algum falhar, devolver tudo o que já saiu.
    local removed = {}
    for itemName, need in pairs(inputs) do
        local n = tonumber(need) or 0
        if n > 0 then
            if not InvRemove(src, itemName, n) then
                for rName, rAmt in pairs(removed) do InvAdd(src, rName, rAmt) end
                exports.ox_inventory:AddItem(src, 'stolen_plate', 1, chosenMeta)  -- restaurar placa-fonte
                return { ok = false, err = 'remove' }
            end
            removed[itemName] = n
        end
    end

    -- 3) Entregar a placa FALSA com metadata { plate = placa da roubada }.
    local added = exports.ox_inventory:AddItem(src, 'fake_plate', 1, { plate = chosenPlate })
    if not added then
        -- Inventário cheio: reverter insumos E a placa-fonte (rollback completo).
        for rName, rAmt in pairs(removed) do InvAdd(src, rName, rAmt) end
        exports.ox_inventory:AddItem(src, 'stolen_plate', 1, chosenMeta)
        return { ok = false, err = 'inventory' }
    end

    -- Sucesso: ativar cooldown e creditar XP (reason 'fake_plate' na XP_TABLE).
    ForgeCooldown[src] = now + forgeCdMs()
    VPChopAddXp(src, tonumber(Config.Plates.ForgeXp) or 22, 'fake_plate')
    VPChopDiscordLog('[FASE2 placas] Forja de placa falsa',
        ('Placa-fonte: %s | src: %s'):format(chosenPlate, tostring(src)))

    return { ok = true, plate = chosenPlate }
end)

-- ─── Broadcast filtrado: setar/restaurar a placa VISÍVEL nos clientes próximos ─
--- A placa falsa em si NÃO vai em statebag (segurança); só um MARCADOR booleano vai.
--- A placa visível é cosmética → pode ir no broadcast e no re-sync de scope.
---@param netId integer
---@param text string  texto da placa a exibir
---@param coords vector3|nil
local function broadcastPlateText(netId, text, coords)
    local radius = tonumber(Config.Plates and Config.Plates.VisibleSyncRadius) or 200.0
    for _, pid in ipairs(GetPlayers()) do
        local pidN = tonumber(pid)
        if pidN then
            local send = true
            if coords then
                local pped = GetPlayerPed(pidN)
                send = pped and pped ~= 0 and #(GetEntityCoords(pped) - coords) < radius
            end
            if send then
                TriggerClientEvent('vp_chopshop:client:setVisiblePlate', pidN, netId, text)
            end
        end
    end
end

-- ─── Callback: APLICAR placa falsa ────────────────────────────────────────────
lib.callback.register('vp_chopshop:applyFakePlate', function(src, netId, sourcePlate)
    if not Config.Plates or not Config.Plates.Enable then return { ok = false, err = 'disabled' } end
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    local now = GetGameTimer()
    if ApplyCooldown[src] and now < ApplyCooldown[src] then return { ok = false, err = 'cooldown' } end

    -- Resolver veículo (netId vem do client; revalidamos tudo)
    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return { ok = false, err = 'vehicle' } end

    -- Proximidade server-side
    local maxDist = tonumber(Config.Plates.ApplyMaxDistance) or 4.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then return { ok = false, err = 'range' } end

    -- [FASE3 garagem] Bloquear em veículo PRÓPRIO/owned (decisão de design — ver item 8).
    -- Carro owned do qbx tem `Entity(veh).state.vehicleid` setado no spawn. Se aplicássemos a
    -- falsa e o jogador guardasse, qbx_garages gravaria a placa FALSA em player_vehicles.
    -- Bloquear aqui elimina o risco SEM editar qbx_garages. Carros criminosos (alvo real) não
    -- têm vehicleid → o disfarce funciona neles, que é o caso de uso pretendido.
    if Config.Plates.BlockOnOwned ~= false then
        local okState, vehId = pcall(function() return Entity(veh).state.vehicleid end)
        if okState and vehId ~= nil then
            return { ok = false, err = 'owned' }
        end
    end

    -- Ler a metadata da `fake_plate` que o jogador possui (placa-alvo do disfarce).
    -- O client manda a placa escolhida; confirmamos posse + formato (trust-no-client).
    local wantPlate = sanitizePlate(sourcePlate)
    local slots = exports.ox_inventory:Search(src, 'slots', 'fake_plate')
    if type(slots) ~= 'table' or #slots == 0 then return { ok = false, err = 'no_item' } end

    local chosenMeta, fakePlate
    for i = 1, #slots do
        local s = slots[i]
        local meta = s and s.metadata
        local pl = meta and sanitizePlate(meta.plate)
        if pl then
            if not wantPlate or wantPlate == pl then
                chosenMeta, fakePlate = meta, pl
                break
            end
        end
    end
    if not fakePlate then return { ok = false, err = 'no_item' } end

    -- Placa REAL ATUAL resolvida no servidor. Se já houver disfarce ativo neste carro,
    -- a "real" verdadeira é a resolvida pelo resolver (não empilhar disfarces).
    local visibleNow = GetVehicleNumberPlateText(veh):gsub('%s+', '')
    local realPlate = VPChopMDT.GetRealPlate(visibleNow)
    if not realPlate or realPlate == '' then return { ok = false, err = 'no_plate' } end

    -- Aplicar a si mesma é no-op inútil; rejeitar.
    if fakePlate == realPlate then return { ok = false, err = 'same' } end

    -- Colisão: a placa falsa já está em uso por OUTRO carro? (PK em vp_chop_fake_plates)
    if VPChopDbFakePlateInUse(fakePlate) then return { ok = false, err = 'in_use' } end

    -- Persistir o mapeamento (INSERT puro = checagem atômica de colisão por PK).
    local appliedBy = ServerChopPlayerKey(src)
    if not VPChopDbInsertFakePlate(fakePlate, realPlate, appliedBy) then
        return { ok = false, err = 'in_use' }
    end

    -- Consumir a `fake_plate` específica (match por metadata).
    if exports.ox_inventory:RemoveItem(src, 'fake_plate', 1, chosenMeta) ~= true then
        -- Falha rara: reverter o INSERT para não deixar mapeamento órfão.
        VPChopDbDeleteFakePlate(fakePlate)
        return { ok = false, err = 'remove' }
    end

    -- Statebag: MARCADOR de que há disfarce ativo + a placa REAL (replicado p/ re-sync robusto).
    -- A placa FALSA NÃO vai no statebag (segurança); a visível é setada via broadcast cosmético.
    local stateOk = pcall(function()
        Entity(veh).state:set('vpFakeRealPlate', realPlate, true)
    end)
    if not stateOk then
        -- Em teoria nunca falha; se falhar, o disfarce ainda funciona via broadcast + DB.
    end

    ApplyCooldown[src] = now + applyCdMs()

    -- Broadcast cosmético: clientes próximos exibem a placa FALSA.
    broadcastPlateText(netId, fakePlate, GetEntityCoords(veh))

    -- MDT: registrar (o crime segue a REAL; a consulta normal vê a falsa naturalmente).
    VPChopMDT.ReportActivity(realPlate, src, 'fake_plate_applied')
    VPChopDiscordLog('[FASE2 placas] Placa falsa aplicada',
        ('Falsa: %s → Real: %s | src: %s'):format(fakePlate, realPlate, tostring(src)))

    return { ok = true, fake = fakePlate }
end)

-- ─── Callback: REMOVER placa falsa (POLÍCIA) ─────────────────────────────────
-- Fura o disfarce: restaura a placa REAL visível, apaga o mapeamento e limpa o statebag.
lib.callback.register('vp_chopshop:removeFakePlate', function(src, netId)
    if not Config.Plates or not Config.Plates.Enable then return { ok = false, err = 'disabled' } end
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    -- Gate de JOB policial (verdade server-side; o target no client é só UX)
    local policeJobs = Config.Plates.PoliceJobs or { 'police', 'bcso', 'sheriff' }
    if not BridgeIsPolice(src, policeJobs) then return { ok = false, err = 'not_police' } end

    local now = GetGameTimer()
    if RemoveCooldown[src] and now < RemoveCooldown[src] then return { ok = false, err = 'cooldown' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return { ok = false, err = 'vehicle' } end

    local maxDist = (tonumber(Config.Plates.ApplyMaxDistance) or 4.0) + 1.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then return { ok = false, err = 'range' } end

    -- Placa VISÍVEL atual = candidata a falsa. Buscar a real mapeada.
    local visible = GetVehicleNumberPlateText(veh):gsub('%s+', '')
    local realPlate = VPChopDbGetRealByFake(visible)
    if not realPlate then return { ok = false, err = 'no_fake' } end

    RemoveCooldown[src] = now + removeCdMs()

    -- Apagar mapeamento + limpar statebag + restaurar placa REAL visível.
    VPChopDbDeleteFakePlate(visible)
    pcall(function() Entity(veh).state:set('vpFakeRealPlate', nil, true) end)
    broadcastPlateText(netId, realPlate, GetEntityCoords(veh))

    VPChopMDT.ReportActivity(realPlate, src, 'fake_plate_removed')
    VPChopDiscordLog('[FASE2 placas] Placa falsa REMOVIDA pela polícia',
        ('Falsa: %s → Real restaurada: %s | src: %s'):format(visible, realPlate, tostring(src)))

    return { ok = true, real = realPlate }
end)

-- ─── Callback: o veículo tem disfarce ativo? (UX do target policial) ──────────
-- Permite ao client mostrar a opção de remoção SÓ em carros disfarçados. Trust-no-client:
-- a remoção em si revalida tudo. Aqui só ajudamos a UI a não poluir todos os carros.
lib.callback.register('vp_chopshop:isFakePlated', function(src, netId)
    if not IsValidSource(src) then return false end
    netId = tonumber(netId)
    if not netId or netId <= 0 then return false end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local visible = GetVehicleNumberPlateText(veh):gsub('%s+', '')
    return VPChopDbFakePlateInUse(visible)
end)

-- ─── Callback: texto da placa FALSA a exibir (re-sync de scope) ───────────────
-- Chamado pelo handler de statebag no client quando entra no scope de um carro disfarçado.
-- Lê a placa REAL do statebag (replicado) e devolve a FALSA mapeada para exibição cosmética.
-- A placa falsa não vai no statebag por segurança — por isso o client a pede aqui.
lib.callback.register('vp_chopshop:getVisibleFakePlate', function(src, netId)
    if not IsValidSource(src) then return nil end
    netId = tonumber(netId)
    if not netId or netId <= 0 then return nil end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    local realPlate = nil
    pcall(function() realPlate = Entity(veh).state.vpFakeRealPlate end)
    if not realPlate or realPlate == '' then return nil end
    return VPChopDbGetFakeByReal(realPlate)
end)

-- ─── [FASE3 garagem] Limpeza ao a entidade sumir ──────────────────────────────
-- Quando o veículo deixa de existir (despawn / delete / guardado), o mapeamento da
-- placa falsa deixa de fazer sentido — limpamos a entrada de vp_chop_fake_plates para
-- não acumular lixo nem reservar uma placa falsa para sempre. Usamos o statebag
-- 'vpFakeRealPlate' como marcador rápido: só consultamos/deletamos se houver disfarce.
AddEventHandler('entityRemoved', function(entity)
    if not entity or entity == 0 then return end
    -- Só veículos interessam; pcall pois state pode não existir em algumas entidades.
    local okState, marker = pcall(function() return Entity(entity).state.vpFakeRealPlate end)
    if not okState or marker == nil then return end
    -- A placa VISÍVEL no momento do despawn é a falsa registrada → deletar por ela.
    local okPlate, visible = pcall(function()
        return (GetVehicleNumberPlateText(entity) or ''):gsub('%s+', '')
    end)
    if okPlate and visible and visible ~= '' then
        -- Deletar em thread para não bloquear o handler (await fora de contexto seguro).
        CreateThread(function()
            VPChopDbDeleteFakePlate(visible)
        end)
    end
end)
