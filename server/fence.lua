-- server/fence.lua
-- Fence NPC rotativo: trust, rotação, ordens, compra de itens, entrega de carros.
-- NPCs removidos: server/npc.lua, server/tyres.lua (funcionalidade migrada aqui).
-- Expõe: VPChopFenceGetTrust(src), VPChopFenceCurrentLocation()
-- ─── Estado do fence ──────────────────────────────────────────────────────────
local CurrentLocationIdx = 1  -- índice em Config.Fence.Locations
local FenceNpcNetId      = nil ---@type integer|nil

--- Cache de trust em memória por source
local TrustCache = {} ---@type table<number, {trust_level:integer, trust_xp:integer, last_seen:integer}>

--- Mutex para geração de ordens (previne dois pedidos simultâneos por jogador)
local OrderGenBusy  = {} ---@type table<string, boolean>
--- Mutex para entrega de carro inteiro (previne double-call no cooldown DB check)
local DeliveryBusy  = {} ---@type table<string, boolean>
--- Mutex para venda de pneus (previne double-payout por double-fire simultâneo)
local SellTyresBusy = {} ---@type table<number, boolean>

--- [H1 FIX] Contagem server-side de pneus por veículo (netId → count).
--- Substitui leitura do state bag do cliente, que era manipulável.
--- [v1.15 P0-1] Fonte única de verdade para o payout de sellTyres. Só é incrementada
--- pelo handler 'vp_chopshop:tyre:loadToTruck' (abaixo), que consome um crédito
--- PlayerTyreStock ganho ao remover uma roda legítima via chopPart.
ServerTyreCounts    = {} ---@type table<integer, integer>  netId → count
local TruckLoadCooldown   = {} ---@type table<number, number>    src  → expiry GetGameTimer

-- ─── Helpers de trust ────────────────────────────────────────────────────────

local function trustMult(level)
    local mults = { [0]=0, [1]=1.0, [2]=1.15, [3]=1.30, [4]=1.50 }
    return mults[level] or 1.0
end

local function loadTrust(src)
    if TrustCache[src] then return TrustCache[src] end
    local key = ServerChopPlayerKey(src)
    local row = MySQL.single.await(
        'SELECT trust_level, trust_xp, UNIX_TIMESTAMP(last_seen) as last_seen FROM vp_chop_fence_trust WHERE identifier = ?',
        {key}
    )
    if row then
        -- Aplicar decay passivo ao carregar
        local daysSince = math.floor((os.time() - (row.last_seen or os.time())) / 86400)
        local decayDays = (Config.Fence and Config.Fence.TrustDecayDays) or 7
        if daysSince >= decayDays and row.trust_level > 0 then
            row.trust_level = math.max(0, row.trust_level - 1)
            -- [H2 FIX] Reset trust_xp to the floor of the new level so the next
            -- addTrustXp call does not re-fire tierUp notifications for lost levels.
            local _xpFloor = (Config.Fence and Config.Fence.TrustXpPerLevel) or { [1]=100, [2]=300, [3]=600, [4]=1000 }
            row.trust_xp = (row.trust_level > 0 and _xpFloor[row.trust_level]) or 0
            MySQL.query.await(
                'UPDATE vp_chop_fence_trust SET trust_level=?, trust_xp=?, last_seen=NOW() WHERE identifier=?',
                {row.trust_level, row.trust_xp, key}
            )
        end
        TrustCache[src] = { trust_level=row.trust_level, trust_xp=row.trust_xp, last_seen=row.last_seen or os.time() }
    else
        TrustCache[src] = { trust_level=0, trust_xp=0, last_seen=os.time() }
    end
    return TrustCache[src]
end

local function saveTrust(src)
    local t = TrustCache[src]
    if not t then return end
    local key = ServerChopPlayerKey(src)
    MySQL.query.await(
        'INSERT INTO vp_chop_fence_trust (identifier, trust_level, trust_xp, last_seen) VALUES (?,?,?,NOW()) '..
        'ON DUPLICATE KEY UPDATE trust_level=VALUES(trust_level), trust_xp=VALUES(trust_xp), last_seen=NOW()',
        {key, t.trust_level, t.trust_xp}
    )
end

local function addTrustXp(src, amount)
    local t = loadTrust(src)
    t.trust_xp = t.trust_xp + amount
    -- Verificar avanço de nível
    local xpTable = (Config.Fence and Config.Fence.TrustXpPerLevel) or { [1]=100, [2]=300, [3]=600, [4]=1000 }
    local prevLevel = t.trust_level
    while t.trust_level < 4 do
        local needed = xpTable[t.trust_level + 1]
        if needed and t.trust_xp >= needed then
            t.trust_level = t.trust_level + 1
        else
            break
        end
    end
    for lv = prevLevel + 1, t.trust_level do
        TriggerClientEvent('vp_chopshop:client:trustUp', src, lv)
    end
    -- [FIX L-3] pcall: falha de DB ao salvar XP não deve abortar o payout já realizado
    pcall(saveTrust, src)
end

--- Retorna nível de trust de um jogador (0-4).
---@param src number
---@return integer
function VPChopFenceGetTrust(src)
    return loadTrust(src).trust_level
end

-- ─── Localização atual do fence ──────────────────────────────────────────────

--- Retorna a localização atual do fence.
---@return table  { coords, scenario, label }
function VPChopFenceCurrentLocation()
    local locs = Config.Fence and Config.Fence.Locations
    if not locs or #locs == 0 then return nil end
    return locs[CurrentLocationIdx]
end

--- Rotaciona o fence para o próximo local e notifica jogadores online.
local function rotateFence()
    local locs = Config.Fence and Config.Fence.Locations
    if not locs or #locs < 2 then return end

    -- Escolher próximo sem repetir atual
    local next
    repeat
        next = math.random(1, #locs)
    until next ~= CurrentLocationIdx
    CurrentLocationIdx = next

    local loc = locs[CurrentLocationIdx]

    -- [FIX H-5] Despawn síncrono antes de spawnar: evita race entre as duas threads onde
    -- o spawn pode completar antes do despawn, deixando o NPC antigo como entidade orphan.
    if FenceNpcNetId then
        local oldEnt = NetworkGetEntityFromNetworkId(FenceNpcNetId)
        if oldEnt and oldEnt ~= 0 and DoesEntityExist(oldEnt) then DeleteEntity(oldEnt) end
        TriggerClientEvent('vp_chopshop:client:removeFenceNpc', -1, FenceNpcNetId)
        FenceNpcNetId = nil
    end
    TriggerEvent('vp_chopshop:server:spawnFenceNpc', loc)

    -- [M2 FIX] Notificar jogadores por nível de trust — usa apenas TrustCache.
    -- VPChopFenceGetTrust faz MySQL.single.await para jogadores não cacheados;
    -- na rotação isso geraria N queries simultâneas. Jogadores sem cache não recebem
    -- notificação de rotação (irrelevante: trust==0 não usa o blip de qualquer forma).
    for _, playerId in ipairs(GetPlayers()) do
        local pid = tonumber(playerId)
        if pid and GetPlayerName(pid) then
            local cached = TrustCache[pid]
            local trust  = cached and cached.trust_level or 0
            if trust == 1 then
                TriggerClientEvent('vp_chopshop:client:fenceRotated', pid, nil, nil)
            elseif trust >= 2 then
                TriggerClientEvent('vp_chopshop:client:fenceRotated', pid, loc.label, loc.coords)
            end
        end
    end
end

-- Timer de rotação
CreateThread(function()
    while not VPChopDBReady do Wait(500) end
    local rotMs = math.floor(((Config.Fence and Config.Fence.RotationMinutes) or 45) * 60 * 1000)
    while true do
        Wait(rotMs)
        rotateFence()
    end
end)

-- [OPT] Limpeza periódica de ordens cumpridas antigas para evitar crescimento ilimitado da tabela.
-- Roda a cada 6h; remove ordens fulfilled há mais de 7 dias.
CreateThread(function()
    while not VPChopDBReady do Wait(500) end
    local cleanupMs = 6 * 60 * 60 * 1000
    while true do
        Wait(cleanupMs)
        pcall(function()
            MySQL.query.await(
                'DELETE FROM vp_chop_fence_orders WHERE fulfilled_at IS NOT NULL AND fulfilled_at < DATE_SUB(NOW(), INTERVAL 7 DAY)',
                {}
            )
        end)
    end
end)

-- ─── Spawn/despawn do NPC ──────────────────────────────────────────────────────

AddEventHandler('vp_chopshop:server:spawnFenceNpc', function(loc)
    if not loc then return end
    -- [FIX C-3] Wait() só pode ser chamado dentro de CreateThread server-side.
    -- AddEventHandler NÃO é uma coroutine — envolve toda a lógica de spawn num thread.
    CreateThread(function()
        local model = joaat('g_m_m_mexboss_01')

        local ped = CreatePed(4, model, loc.coords.x, loc.coords.y, loc.coords.z, loc.coords.w, true, true)
        if not ped or ped == 0 then return end

        -- A config visual do ped (freeze/invincible/blocking/scenario) é feita CLIENT-side
        -- no handler 'vp_chopshop:client:setupFenceNpc'. Esses natives são client-only e
        -- não existem no server (SetEntityAsMissionEntity etc. → nil value).

        FenceNpcNetId = NetworkGetNetworkIdFromEntity(ped)
        -- Notificar todos os clientes para registrar targets
        TriggerClientEvent('vp_chopshop:client:setupFenceNpc', -1, { nwid=FenceNpcNetId, locationIdx=CurrentLocationIdx })
    end)
end)

AddEventHandler('vp_chopshop:server:despawnFenceNpc', function()
    if not FenceNpcNetId then return end
    local ent = NetworkGetEntityFromNetworkId(FenceNpcNetId)
    if ent and ent ~= 0 and DoesEntityExist(ent) then DeleteEntity(ent) end
    TriggerClientEvent('vp_chopshop:client:removeFenceNpc', -1, FenceNpcNetId)
    FenceNpcNetId = nil
end)

-- Spawn inicial ao carregar
CreateThread(function()
    while not VPChopDBReady do Wait(500) end
    Wait(1000)
    local loc = VPChopFenceCurrentLocation()
    if loc then TriggerEvent('vp_chopshop:server:spawnFenceNpc', loc) end
end)

-- ─── Pneus: stock autoritativo por jogador + carga no truck ──────────────────
-- [v1.15 P0-3] O evento legado 'vp_chopshop:tyres:jackstandTyreStolen' foi REMOVIDO.
--   Era dead code (nenhum call site cliente/servidor legítimo — o fluxo real de roubo
--   de roda migrou para 'vp_chopshop:chopPart' em v1.14) e uma superfície de exploit:
--   um lua executor disparava o evento e recebia chopshop_tyre sem prova de que uma
--   roda foi desmontada (mitigado a 4/netId, mas repetível em cada veículo).
--
-- [v1.15 P0-1] Os DOIS handlers concorrentes de carga no truck
--   ('vp_chopshop:tyre:truckLoad' aqui e 'vp_chopshop:server:addTyreToTruck' em
--   server/main.lua) foram unificados no handler único 'vp_chopshop:tyre:loadToTruck'
--   abaixo, que CONSOME um crédito de pneu ganho ao remover uma roda legítima.
--
-- Fluxo autoritativo: chopPart(wheel_*) [single-use por wheel/netId, server-side]
--   → listener PART_CHOPPED credita PlayerTyreStock[src] += 1
--   → loadToTruck consome 1 crédito e incrementa ServerTyreCounts[truckNetId]
--   → sellTyres paga por ServerTyreCounts[truckNetId].
-- Sem crédito → sem incremento. O contador do truck nunca sobe por evento não lastreado.

--- Crédito de pneus por jogador (ganho ao remover uma roda; consumido ao carregar no truck).
local PlayerTyreStock = {} ---@type table<number, integer>
local function tyreStockCap()
    return math.max(4, math.floor(tonumber(Config.TyreSelling and Config.TyreSelling.MaxPlayerTyreStock) or 12))
end

AddEventHandler(VPChopEvt.PART_CHOPPED, function(src, netId, partKey, phase)
    if not (Config.TyreSelling and Config.TyreSelling.Enable) then return end
    local def = ChopParts and ChopParts[partKey]
    if not def or def.kind ~= 'tyre' then return end
    if not IsValidSource(src) then return end
    PlayerTyreStock[src] = math.min((PlayerTyreStock[src] or 0) + 1, tyreStockCap())
end)

--- Set de hashes de modelos de pickup truck aceites (resolvido 1× server-side).
local _truckHashSet
local function isPickupTruckModel(model)
    if not _truckHashSet then
        _truckHashSet = {}
        for _, m in ipairs((Config.TyreSelling and Config.TyreSelling.PickupTruckModels) or {}) do
            _truckHashSet[GetHashKey(m)] = true
        end
    end
    return _truckHashSet[model] == true
end

local TRUCK_LOAD_COOLDOWN_MS = 1500
local TruckLoadBusy = {} ---@type table<number, boolean>

--- [v1.15 P0-1] API única e autenticada de carga de pneu no truck.
RegisterNetEvent('vp_chopshop:tyre:loadToTruck', function(netId)
    local src = source
    if not IsValidSource(src) then return end
    if not (Config.TyreSelling and Config.TyreSelling.Enable) then return end
    netId = tonumber(netId)
    if not netId then return end

    -- Mutex por jogador: impede double-fire concorrente consumir 1 crédito e somar 2
    if TruckLoadBusy[src] then return end
    TruckLoadBusy[src] = true
    local function done() TruckLoadBusy[src] = nil end

    local now = GetGameTimer()
    if TruckLoadCooldown[src] and now < TruckLoadCooldown[src] then return done() end
    TruckLoadCooldown[src] = now + TRUCK_LOAD_COOLDOWN_MS

    -- Precisa ter removido uma roda legítima antes (crédito server-side)
    if (PlayerTyreStock[src] or 0) < 1 then
        LogSuspicious(src, 'tyre:loadToTruck', 'Sem crédito de pneu (nenhuma roda removida)')
        return done()
    end

    -- Truck: entidade + modelo + proximidade (trust-no-client)
    local truck = NetworkGetEntityFromNetworkId(netId)
    if not truck or truck == 0 or not DoesEntityExist(truck) then return done() end
    if not isPickupTruckModel(GetEntityModel(truck)) then
        LogSuspicious(src, 'tyre:loadToTruck', 'Veículo alvo não é pickup truck (netId=' .. netId .. ')')
        return done()
    end
    if not ValidatePlayerNearVehicle(src, truck, 8.0) then return done() end

    local maxTyres = math.max(1, math.floor(tonumber(Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4))
    local cur = ServerTyreCounts[netId] or 0
    if cur >= maxTyres then return done() end

    -- Consumir crédito e incrementar o contador autoritativo
    PlayerTyreStock[src] = PlayerTyreStock[src] - 1
    ServerTyreCounts[netId] = cur + 1
    Entity(truck).state:set('chopTyreCount', cur + 1, true)
    done()
end)

AddEventHandler('playerDropped', function()
    local src = source
    PlayerTyreStock[src]   = nil
    TruckLoadBusy[src]     = nil
    TruckLoadCooldown[src] = nil
end)

-- Limpar contador de pneus do truck ao destruir a entidade
AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId and netId ~= 0 then
        ServerTyreCounts[netId] = nil
    end
end)

-- ─── Callbacks de interação ───────────────────────────────────────────────────

-- Apresentar-se (trust 0 → 1)
lib.callback.register('vp_chopshop:fence:introduce', function(src)
    if not IsValidSource(src) then return { ok=false } end
    local trust = VPChopFenceGetTrust(src)
    if trust > 0 then return { ok=false, err='already_known' } end

    if not exports.ox_inventory:RemoveItem(src, 'fence_referral', 1) then
        return { ok=false, err='no_referral' }
    end

    local t = loadTrust(src)
    t.trust_level = 1
    t.trust_xp    = 0
    -- [M1 FIX] pcall: se DB falhar, devolve o item e retorna erro em vez de
    -- deixar o jogador sem fence_referral E sem trust persistido no banco.
    local saveOk = pcall(saveTrust, src)
    if not saveOk then
        -- [M1 FIX] Check refund return: if inventory is also full, log so the item can be
        -- manually restored — otherwise player loses the referral with nothing granted.
        if not exports.ox_inventory:AddItem(src, 'fence_referral', 1) then
            print(('[vp_chopshop] WARN: fence_referral refund failed (inv full) for %s'):format(ServerChopPlayerKey(src)))
        end
        return { ok=false, err='db' }
    end
    TrustCache[src] = t

    return { ok=true }
end)

local function getNightBonusMultiplier()
    if not Config.Fence or not Config.Fence.NightBonus or not Config.Fence.NightBonus.Enable then
        return 1.0
    end
    local h = GetClockHours()
    local s = Config.Fence.NightBonus.StartHour or 21
    local e = Config.Fence.NightBonus.EndHour or 6
    if s > e then
        if h >= s or h < e then return (Config.Fence.NightBonus.Multiplier or 1.0) end
    else
        if h >= s and h < e then return (Config.Fence.NightBonus.Multiplier or 1.0) end
    end
    return 1.0
end

-- Rate-limit para venda de itens (anti-spam de cash)
local _sellItemsRateLimit = {}  ---@type table<number, number>  src → expiry GetGameTimer
local SELL_ITEMS_MIN_INTERVAL_MS = 3000

-- Vender materiais do inventário
lib.callback.register('vp_chopshop:fence:sellItems', function(src, itemList)
    if not IsValidSource(src) then return { ok=false } end
    local nowSI = GetGameTimer()
    if _sellItemsRateLimit[src] and nowSI < _sellItemsRateLimit[src] then
        return { ok=false, err='cooldown' }
    end
    _sellItemsRateLimit[src] = nowSI + SELL_ITEMS_MIN_INTERVAL_MS
    local trust = VPChopFenceGetTrust(src)
    if trust < 1 then return { ok=false, err='no_trust' } end

    -- Validar proximidade ao fence
    local loc = VPChopFenceCurrentLocation()
    if not loc then return { ok=false, err='no_fence' } end
    if not ValidatePlayerNearPoint(src, vector3(loc.coords.x, loc.coords.y, loc.coords.z), 5.0) then
        return { ok=false, err='range' }
    end

    -- Limitar tamanho da lista (defesa contra payload gigante de lua executor)
    if type(itemList) ~= 'table' or #itemList > 50 then
        return { ok=false, err='invalid' }
    end

    local prog      = VPChopGetProgression(src)
    local tierMult  = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.0
    local trustM    = trustMult(trust)
    local nightM    = getNightBonusMultiplier()
    local basePrices = (Config.Fence and Config.Fence.BasePrices) or {}

    -- [FIX M1] Dry-run: calcular valor total antes de remover qualquer item.
    -- Isso evita remoção parcial quando totalValue acaba sendo 0.
    local totalValue = 0
    local candidates = {}

    for _, entry in ipairs(itemList or {}) do
        local item   = type(entry.name) == 'string' and entry.name or nil
        local amount = math.floor(tonumber(entry.amount) or 0)
        if item and amount > 0 and basePrices[item] then
            local have = exports.ox_inventory:GetItemCount(src, item)
            local sell = math.min(amount, math.floor(tonumber(have) or 0))
            if sell > 0 then
                local price  = math.floor(basePrices[item] * trustM * tierMult * nightM)
                local earned = price * sell
                totalValue   = totalValue + earned
                candidates[#candidates+1] = { name=item, amount=sell, earned=earned }
            end
        end
    end

    if totalValue <= 0 then return { ok=false, err='nothing_sold' } end

    -- Remover itens confirmados; acumular apenas o que foi realmente removido
    local soldItems = {}
    local realTotal = 0
    for _, c in ipairs(candidates) do
        if exports.ox_inventory:RemoveItem(src, c.name, c.amount) then
            soldItems[#soldItems+1] = c
            realTotal = realTotal + c.earned
        end
    end

    if #soldItems == 0 then return { ok=false, err='nothing_sold' } end

    -- [FIX C-1] Pagar apenas pelo que foi realmente removido (evita pagar totalValue
    -- quando algum RemoveItem falha silenciosamente entre o dry-run e a remoção real).
    BridgeAddCash(src, realTotal, 'fence_sale')

    -- XP de trust
    addTrustXp(src, (Config.Fence and Config.Fence.XpPerDelivery) or 20)

    -- Emitir evento para progressão
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, soldItems, realTotal, 'material')

    return { ok=true, total=realTotal }
end)

-- Vender pneus (truck OU inventário)
lib.callback.register('vp_chopshop:fence:sellTyres', function(src, source_type, truckNetId)
    if not IsValidSource(src) then return { ok=false } end
    -- [H1 FIX] Mutex per player: prevents double-payout from rapid double-fire.
    -- release() clears it on every code path and returns the result table.
    if SellTyresBusy[src] then return { ok=false, err='processing' } end
    SellTyresBusy[src] = true
    local function release(res) SellTyresBusy[src] = nil; return res end

    -- [AUDIT M4] Validar o tipo recebido do client ANTES de qualquer yield (.await do trust).
    if source_type ~= 'truck' and source_type ~= 'inventory' then
        return release({ ok=false, err='invalid_type' })
    end

    local trust = VPChopFenceGetTrust(src)
    if trust < 1 then return release({ ok=false, err='no_trust' }) end

    local loc = VPChopFenceCurrentLocation()
    if not loc then return release({ ok=false, err='no_fence' }) end
    if not ValidatePlayerNearPoint(src, vector3(loc.coords.x, loc.coords.y, loc.coords.z), 5.0) then
        return release({ ok=false, err='range' })
    end

    local prog     = VPChopGetProgression(src)
    local tierMult = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.0
    local trustM   = trustMult(trust)
    local nightM   = getNightBonusMultiplier()
    local unitPrice = math.floor(((Config.Fence and Config.Fence.BasePrices and Config.Fence.BasePrices.chopshop_tyre) or 400) * trustM * tierMult * nightM)

    local xpPerTyre = math.floor(((Config.Fence and Config.Fence.XpPerDelivery) or 20) * 0.5)

    if source_type == 'truck' and truckNetId then
        -- Truck: contador server-side é a verdade (nunca o state bag do cliente).
        local nid = tonumber(truckNetId)
        local truck = NetworkGetEntityFromNetworkId(nid or 0)
        if not truck or truck == 0 or not DoesEntityExist(truck) then
            return release({ ok=false, err='no_truck' })
        end
        -- [v1.15 P0-2] Validar modelo + proximidade ao truck (antes só checava existência).
        if not isPickupTruckModel(GetEntityModel(truck)) then
            LogSuspicious(src, 'fence:sellTyres', 'Veículo alvo não é pickup truck')
            return release({ ok=false, err='bad_truck' })
        end
        if not ValidatePlayerNearVehicle(src, truck, 8.0) then
            return release({ ok=false, err='truck_range' })
        end

        local count = ServerTyreCounts[nid] or 0
        if count <= 0 then return release({ ok=false, err='no_tyres' }) end

        -- [v1.15 P0-2] Pagar ANTES de zerar o contador; se o pagamento falhar, nada é perdido.
        local total = unitPrice * count
        if not BridgeAddCash(src, total, 'fence_tyres') then
            return release({ ok=false, err='payment' })
        end
        ServerTyreCounts[nid] = nil
        Entity(truck).state:set('chopTyreCount', 0, true)
        addTrustXp(src, xpPerTyre * count)
        TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, {}, total, 'tyre')
        return release({ ok=true, count=count, total=total })
    end

    -- Inventário: chopshop_tyre items
    local count = exports.ox_inventory:GetItemCount(src, 'chopshop_tyre') or 0
    if count <= 0 then return release({ ok=false, err='no_tyres' }) end
    if not exports.ox_inventory:RemoveItem(src, 'chopshop_tyre', count) then
        return release({ ok=false, err='remove_failed' })
    end

    local total = unitPrice * count
    if not BridgeAddCash(src, total, 'fence_tyres') then
        -- [v1.15 P0-2] Compensação: devolver os pneus removidos se o pagamento falhar.
        if not exports.ox_inventory:AddItem(src, 'chopshop_tyre', count) then
            print(('[vp_chopshop] WARN: sellTyres refund falhou (inv cheio) para %s — %d pneus'):format(ServerChopPlayerKey(src), count))
        end
        return release({ ok=false, err='payment' })
    end
    addTrustXp(src, xpPerTyre * count)
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, {}, total, 'tyre')
    return release({ ok=true, count=count, total=total })
end)

-- Entregar carro inteiro (Tier 4 + trust 4)
lib.callback.register('vp_chopshop:fence:deliverCar', function(src, netId)
    if not IsValidSource(src) then return { ok=false } end
    local trust = VPChopFenceGetTrust(src)
    if trust < 4 then return { ok=false, err='no_trust' } end

    local prog = VPChopGetProgression(src)
    if prog.tier < 4 then return { ok=false, err='tier' } end

    -- [FIX M-3] Mutex por jogador: previne dois deliverCar simultâneos passarem pelo cooldown check
    local key = ServerChopPlayerKey(src)
    if DeliveryBusy[key] then return { ok=false, err='processing' } end
    DeliveryBusy[key] = true

    -- [FIX M-2] Cooldown comparado inteiramente no MySQL para eliminar risco de clock skew
    -- entre os relógios do servidor FiveM (os.time) e do servidor MySQL (UNIX_TIMESTAMP).
    local cooldownSec = ((Config.Fence and Config.Fence.WholeCarCooldownMin) or 20) * 60
    local cdRow = MySQL.single.await(
        'SELECT GREATEST(0, ? - TIMESTAMPDIFF(SECOND, last_car_delivery, NOW())) as wait_sec FROM vp_chop_progression WHERE identifier=?',
        {cooldownSec, key}
    )
    if cdRow and (cdRow.wait_sec or 0) > 0 then
        DeliveryBusy[key] = nil
        return { ok=false, err='cooldown', wait=cdRow.wait_sec }
    end

    local veh = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        DeliveryBusy[key] = nil
        return { ok=false, err='vehicle' }
    end
    if not ValidatePlayerNearVehicle(src, veh, 6.0) then
        DeliveryBusy[key] = nil
        return { ok=false, err='range' }
    end

    local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')

    -- [M1 FIX] Calcular label uma vez (VPChopHeatCalc tem SQL query interna).
    -- VPChopHeatGetLabel + VPChopHeatGetPriceMult chamariam VPChopHeatCalc 2×; mapeamos localmente.
    local heatLabel = VPChopHeatGetLabel(plate)
    if heatLabel == 'queimando' then
        DeliveryBusy[key] = nil
        return { ok=false, err='too_hot' }
    end
    local _heatLabelToMult = { frio=1.0, morno=0.90, quente=0.75, queimando=0.0 }
    local heatMult  = _heatLabelToMult[heatLabel] or 1.0
    local tierMult  = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.10
    local trustM    = trustMult(trust)
    local nightM    = getNightBonusMultiplier()
    local base      = (Config.Fence and Config.Fence.WholeCarBasePayout) or 8000
    local payout    = math.floor(base * trustM * tierMult * heatMult * nightM)

    -- Sanity cap: entrega de carro não deve exceder 5× o WholeCarBasePayout
    local maxCarPayout = math.floor(((Config.Fence and Config.Fence.WholeCarBasePayout) or 8000) * 5)
    payout = math.min(payout, maxCarPayout)

    -- Persistir cooldown ANTES de pagar (garante que falha de DB não permite spam)
    local cdOk = pcall(function()
        MySQL.query.await('UPDATE vp_chop_progression SET last_car_delivery=NOW() WHERE identifier=?', {key})
    end)
    if not cdOk then
        DeliveryBusy[key] = nil
        return { ok=false, err='db' }
    end

    -- Deletar veículo e pagar
    DeleteEntity(veh)
    BridgeAddCash(src, payout, 'fence_car')

    addTrustXp(src, (Config.Fence and Config.Fence.XpOrderBonus) or 80)
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, {}, payout, 'car')

    DeliveryBusy[key] = nil
    return { ok=true, payout=payout }
end)

-- Retornar nível de trust do jogador (usado pelo cliente para montar targets)
lib.callback.register('vp_chopshop:fence:getTrust', function(src)
    if not IsValidSource(src) then return 0 end
    return VPChopFenceGetTrust(src)
end)

-- Comprar bancada via fence (valida proximidade ao fence rotativo, não ao NPC legado)
-- Substitui vp_chopshop:npcBuy para o contexto do fence (server/main.lua ainda registra
-- vp_chopshop:npcBuy mas valida contra Config.NPC.Coords — coordenada estática incorreta).
lib.callback.register('vp_chopshop:fence:buyBench', function(src)
    if not IsValidSource(src) then return { ok=false, err='invalid' } end
    local shop = Config.NPC and Config.NPC.Shop
    if not shop or not shop.Enable then return { ok=false, err='disabled' } end

    local loc = VPChopFenceCurrentLocation()
    if not loc then return { ok=false, err='no_fence' } end
    if not ValidatePlayerNearPoint(src, vector3(loc.coords.x, loc.coords.y, loc.coords.z), 5.0) then
        return { ok=false, err='distance' }
    end

    local price = math.floor(tonumber(shop.BenchPrice) or 0)
    if price < 1 then return { ok=false, err='disabled' } end
    if not BridgeRemoveCash(src, price, 'npc_buy_bench') then
        return { ok=false, err='money' }
    end

    local itemName = Config.Items and Config.Items.placeBench or 'chopshop_bench'
    if not exports.ox_inventory:AddItem(src, itemName, 1) then
        BridgeAddCash(src, price, 'npc_buy_bench_refund')
        return { ok=false, err='inventory' }
    end

    return { ok=true }
end)

-- Pegar ordem ativa (trust ≥ 3)
lib.callback.register('vp_chopshop:fence:getOrder', function(src)
    if not IsValidSource(src) then return nil end
    if VPChopFenceGetTrust(src) < 3 then return nil end

    local key = ServerChopPlayerKey(src)
    -- [FIX M2] Mutex: previne dupla inserção de ordem por callbacks simultâneos
    if OrderGenBusy[key] then return nil end
    OrderGenBusy[key] = true

    local row = MySQL.single.await(
        'SELECT id, order_data FROM vp_chop_fence_orders WHERE for_identifier=? AND fulfilled_at IS NULL ORDER BY created_at DESC LIMIT 1',
        {key}
    )
    if not row then
        -- Gerar nova ordem
        local templates = (Config.Fence and Config.Fence.OrderTemplates) or {}
        if #templates == 0 then OrderGenBusy[key] = nil; return nil end
        local tmpl = templates[math.random(1, #templates)]
        local deadline = os.time() + math.floor(tmpl.hours * 3600)
        local orderData = json.encode({ items=tmpl.items, mult=tmpl.mult, deadline=deadline })
        -- [FIX H-2] pcall: se MySQL.insert.await lançar erro, OrderGenBusy seria permanentemente
        -- stuck sem este pcall (o coroutine desmontaria antes de chegar ao nil abaixo).
        local id
        local insertOk = pcall(function()
            id = MySQL.insert.await(
                'INSERT INTO vp_chop_fence_orders (for_identifier, order_data) VALUES (?,?)',
                {key, orderData}
            )
        end)
        OrderGenBusy[key] = nil
        if not insertOk or not id then return nil end
        return { id=id, items=tmpl.items, mult=tmpl.mult, deadline=deadline }
    end

    local data = json.decode(row.order_data)
    -- Verificar expiração
    if data.deadline and os.time() > data.deadline then
        MySQL.query.await('UPDATE vp_chop_fence_orders SET fulfilled_at=NOW() WHERE id=?', {row.id})
        OrderGenBusy[key] = nil
        return nil  -- expirou — nova ordem na próxima chamada
    end
    OrderGenBusy[key] = nil
    return { id=row.id, items=data.items, mult=data.mult, deadline=data.deadline }
end)

-- Entregar ordem
lib.callback.register('vp_chopshop:fence:fulfillOrder', function(src, orderId)
    if not IsValidSource(src) then return { ok=false } end
    -- [M2 FIX] Guardar resultado em variável local para reusar na linha do trustM abaixo
    -- (evita 2ª chamada a VPChopFenceGetTrust que, sem cache, dispararia MySQL.single.await).
    local trust = VPChopFenceGetTrust(src)
    if trust < 3 then return { ok=false, err='no_trust' } end

    local key = ServerChopPlayerKey(src)
    local row = MySQL.single.await(
        'SELECT id, order_data FROM vp_chop_fence_orders WHERE id=? AND for_identifier=? AND fulfilled_at IS NULL',
        {orderId, key}
    )
    if not row then return { ok=false, err='no_order' } end

    local data = json.decode(row.order_data)
    if os.time() > (data.deadline or 0) then
        MySQL.query.await('UPDATE vp_chop_fence_orders SET fulfilled_at=NOW() WHERE id=?', {row.id})
        return { ok=false, err='expired' }
    end

    -- Remover itens atomicamente (RemoveItem retorna false se insuficiente)
    local removed = {}
    for item, amount in pairs(data.items) do
        if exports.ox_inventory:RemoveItem(src, item, amount) then
            removed[item] = amount
        else
            -- Rollback: devolver itens já removidos
            for ri, ra in pairs(removed) do
                exports.ox_inventory:AddItem(src, ri, ra)
            end
            return { ok=false, err='missing_item', item=item, need=amount }
        end
    end

    -- Calcular recompensa
    local basePrices = (Config.Fence and Config.Fence.BasePrices) or {}
    local prog    = VPChopGetProgression(src)
    local tierM   = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.0
    local trustM  = trustMult(trust)  -- [M2 FIX] reutiliza valor já obtido no guard acima
    local baseVal = 0
    for item, amount in pairs(data.items) do
        baseVal = baseVal + ((basePrices[item] or 100) * amount)
    end
    local total = math.floor(baseVal * (data.mult or 1.0) * trustM * tierM)

    -- [FIX C-2] Marcar a ordem atomicamente ANTES de pagar.
    -- UPDATE ... WHERE fulfilled_at IS NULL garante que somente uma chamada simultânea
    -- consiga affectedRows=1. A segunda chamada recebe affectedRows=0 → rollback.
    local markResult = MySQL.query.await(
        'UPDATE vp_chop_fence_orders SET fulfilled_at=NOW() WHERE id=? AND for_identifier=? AND fulfilled_at IS NULL',
        {row.id, key}
    )
    if not markResult or markResult.affectedRows == 0 then
        -- Outra chamada simultânea já fulfillou esta ordem — rollback de itens
        for ri, ra in pairs(removed) do exports.ox_inventory:AddItem(src, ri, ra) end
        return { ok=false, err='no_order' }
    end

    BridgeAddCash(src, total, 'fence_order')

    addTrustXp(src, (Config.Fence and Config.Fence.XpOrderBonus) or 80)
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, data.items, total, 'order')

    return { ok=true, total=total }
end)

-- Drop de fence_referral: lógica implementada diretamente em ambushSpawnOne em server/ambush.lua
-- (Task 8.2 adiciona a thread de verificação de morte do ped lá)

-- ─── Cleanup ao desconectar ───────────────────────────────────────────────────
AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1] localizar antes de qualquer yield potencial
    TrustCache[src] = nil
    TruckLoadCooldown[src] = nil
    SellTyresBusy[src] = nil  -- [H1 FIX] evitar mutex stuck se jogador desconectar mid-sale
    _sellItemsRateLimit[src] = nil
    local k = ServerChopPlayerKey(src)
    OrderGenBusy[k]  = nil
    DeliveryBusy[k]  = nil
end)
