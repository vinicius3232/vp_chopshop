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
local DeliveryBusy  = {} ---@type table<string, boolean>   playerKey → true
--- [v1.15 PR-H] Guard por VEÍCULO na entrega inteira (previne dois jogadores
--- entregarem a MESMA entidade) + tombstone que bloqueia re-entrega do mesmo netId
--- enquanto a entidade não sumir de fato (ex.: BridgeDeleteWorldVehicle falhou).
local DeliverCarBusy      = {} ---@type table<integer, string>   netId → playerKey
local DeliveredTombstone  = {} ---@type table<integer, { model:integer, mark:string, at:integer }>
--- [PR-H] Nesta ordem transacional (reserva de cooldown ANTES do pagamento) o
--- dinheiro só entra depois de reserva + marcador confirmados. Se algo falha
--- depois disso, ou o dinheiro nunca entrou (rollback simples) ou a entrega
--- ocorreu de fato (cleanupPending). Não há mais janela "pago sem barreira" →
--- a quarentena econômica de deliverCar deixou de ser necessária.
local _deliverMarkSeq = 0
--- Mutex para venda de pneus (previne double-payout por double-fire simultâneo)
local SellTyresBusy = {} ---@type table<number, boolean>
--- [v1.15 PR-E hardening] Quarentena econômica: pagamento CONFIRMADO + CommitSold
--- parcial + estorno FALHOU → o jogador ficou com dinheiro a mais. Nenhuma nova
--- venda de pneu até limpeza explícita (admin/futuro — não nesta PR). Keyed por
--- ServerChopPlayerKey (estável entre reconexões). value = valor não recuperado.
local TyreSaleQuarantine = {} ---@type table<string, integer>

-- [v1.15 PR-E] `ServerTyreCounts` REMOVIDO. A contagem de pneus no truck agora é
-- DERIVADA de `TruckStorage.Count(storageId)` (nº de tyre entitlements STORED).
-- O state bag `chopTyreCount` continua só p/ UX (nunca autoridade).
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
-- [v1.15 PR-E] Fluxo autoritativo por ENTITLEMENT (substitui `PlayerTyreStock`):
--   chopPart(wheel_*) → peça committed (origin='base', kind='tyre')
--     → TyreEntitlement.Issue (server-side, imediato, idempotente) → 'te:<n>' (REMOVED)
--   loadToTruck(src, truckNetId, entitlementId) → TruckStorage.Load → entitlement STORED
--   sellTyres(truck) → paga pelos entitlements STORED → SOLD
-- O listener PART_CHOPPED que creditava `PlayerTyreStock` foi REMOVIDO — a emissão
-- do entitlement é EXPLÍCITA no callback de chop (server/main.lua), p/ devolver o
-- id ao client. PART_CHOPPED segue para progression/heat/outros listeners.

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
local TruckLoadBusy = {} ---@type table<number, boolean>   src   → carga em curso
--- [v1.15 PR-E] Lock econômico por STORAGE IDENTITY (não netId cru): carga E venda
--- do mesmo storage compartilham este lock. Nenhuma venda enquanto entra pneu;
--- nenhum load enquanto vende. Cada handler libera o próprio lock em TODO return.
local TruckStorageBusy = {} ---@type table<string, boolean>  storageId → operação em curso

local function truckMaxTyres()
    return math.max(1, math.floor(tonumber(Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4))
end

--- [v1.15 PR-E] Carga de UM tyre entitlement no truck — REQUEST/RESPONSE.
--- Contrato NOVO: (src, truckNetId, entitlementId). O client SEMPRE envia o id
--- específico do pneu que está carregando — nunca "qualquer crédito do player".
--- O cliente só remove o prop / encerra o carry se ok==true. `count` é server-side.
--- Em QUALQUER deny o entitlement continua REMOVED (client mantém prop/carry).
lib.callback.register('vp_chopshop:tyre:loadToTruck', function(src, netId, entitlementId)
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not (Config.TyreSelling and Config.TyreSelling.Enable) then return { ok = false, err = 'disabled' } end
    netId = tonumber(netId)
    if not netId then return { ok = false, err = 'net' } end
    if type(entitlementId) ~= 'string' then return { ok = false, err = 'entitlement' } end

    -- Mutex por jogador: impede double-fire concorrente do mesmo entitlement
    if TruckLoadBusy[src] then return { ok = false, err = 'processing' } end
    TruckLoadBusy[src] = true
    local function release(res) TruckLoadBusy[src] = nil; return res end

    local now = GetGameTimer()
    if TruckLoadCooldown[src] and now < TruckLoadCooldown[src] then
        return release({ ok = false, err = 'cooldown' })
    end
    TruckLoadCooldown[src] = now + TRUCK_LOAD_COOLDOWN_MS

    -- Entitlement: existe + é do jogador + ainda REMOVED (não STORED/SOLD/LOST)
    local ent = TyreEntitlement.Get(entitlementId)
    if not ent then
        LogSuspicious(src, 'tyre:loadToTruck', 'entitlementId inválido: ' .. tostring(entitlementId))
        return release({ ok = false, err = 'entitlement' })
    end
    if ent.removedBy ~= src then
        LogSuspicious(src, 'tyre:loadToTruck', 'entitlement ' .. entitlementId .. ' pertence a outro jogador')
        return release({ ok = false, err = 'owner' })
    end
    if ent.state == 'STORED' then return release({ ok = false, err = 'already_stored' }) end
    if ent.state ~= 'REMOVED' then return release({ ok = false, err = 'bad_state' }) end

    -- Truck: entidade + modelo + proximidade (trust-no-client)
    local truck = NetworkGetEntityFromNetworkId(netId)
    if not truck or truck == 0 or not DoesEntityExist(truck) then
        return release({ ok = false, err = 'no_truck' })
    end
    if not isPickupTruckModel(GetEntityModel(truck)) then
        LogSuspicious(src, 'tyre:loadToTruck', 'Veículo alvo não é pickup truck (netId=' .. netId .. ')')
        return release({ ok = false, err = 'bad_truck' })
    end
    if not ValidatePlayerNearVehicle(src, truck, 8.0) then
        return release({ ok = false, err = 'range' })
    end

    -- [PR-E] Identidade do storage (cunha no 1º load + marcador WRITE+READBACK).
    -- Fail-closed: marcador não-confirmável ⇒ 'storage_identity'.
    local storageId, sErr = TruckStorage.Resolve(netId)
    if not storageId then return release({ ok = false, err = sErr or 'storage_identity' }) end

    -- Lock por STORAGE (carga OU venda do mesmo storage serializadas).
    if TruckStorageBusy[storageId] then return release({ ok = false, err = 'truck_busy' }) end
    TruckStorageBusy[storageId] = true
    local function releaseAll(res) TruckStorageBusy[storageId] = nil; return release(res) end

    -- Atômico: capacidade + REMOVED→STORED + insere o id no storage.
    local ok, countOrErr = TruckStorage.Load(storageId, entitlementId)
    if not ok then return releaseAll({ ok = false, err = countOrErr }) end   -- entitlement segue REMOVED

    return releaseAll({ ok = true, count = countOrErr, max = truckMaxTyres() })
end)

--- [PR-E] Recuperação/diagnóstico: entitlements REMOVED do jogador ainda não
--- stored/sold/lost. READ-ONLY — não cria entitlement, não recompensa.
lib.callback.register('vp_chopshop:tyre:getPendingEntitlements', function(src)
    if not IsValidSource(src) then return {} end
    return TyreEntitlement.GetPendingForPlayer(src, 12)
end)

AddEventHandler('playerDropped', function()
    local src = source
    TruckLoadBusy[src]     = nil
    TruckLoadCooldown[src] = nil
    -- Entitlements REMOVED do jogador → LOST: TyreEntitlement.CleanupPlayer (próprio hook).
end)

-- [PR-E] O estado econômico do truck (entitlements STORED → LOST) é tratado pelo
-- hook entityRemoved de server/logistics/truck_storage.lua (TruckStorage.OnTruckRemoved).
-- `TruckStorageBusy` (por storageId) é sempre liberado pelo próprio handler.

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

    -- [PR-E hardening] Quarentena econômica de venda de pneu (estorno falhou antes).
    local qKey = ServerChopPlayerKey(src)
    if TyreSaleQuarantine[qKey] then
        return release({ ok=false, err='transaction_locked' })
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
        local nid = tonumber(truckNetId)
        if not nid then return release({ ok=false, err='no_truck' }) end

        -- [PR-E] Identidade do storage (read-only — não cunha). netId reciclado /
        -- marcador não bate ⇒ 'storage_identity'.
        local storageId, sErr = TruckStorage.Peek(nid)
        if not storageId then return release({ ok=false, err = sErr or 'no_tyres' }) end

        -- Lock por STORAGE: dois vendedores não vendem o mesmo storage, e nenhuma
        -- carga entra durante a venda. releaseTruck() encadeia release() do player.
        if TruckStorageBusy[storageId] then return release({ ok=false, err='truck_busy' }) end
        TruckStorageBusy[storageId] = true
        local function releaseTruck(res) TruckStorageBusy[storageId] = nil; return release(res) end

        local truck = NetworkGetEntityFromNetworkId(nid)
        if not truck or truck == 0 or not DoesEntityExist(truck) then
            return releaseTruck({ ok=false, err='no_truck' })
        end
        if not isPickupTruckModel(GetEntityModel(truck)) then
            LogSuspicious(src, 'fence:sellTyres', 'Veículo alvo não é pickup truck')
            return releaseTruck({ ok=false, err='bad_truck' })
        end
        if not ValidatePlayerNearVehicle(src, truck, 8.0) then
            return releaseTruck({ ok=false, err='truck_range' })
        end

        -- Contagem DERIVADA + snapshot ANTES do pagamento.
        local ids   = TruckStorage.SnapshotStored(storageId)
        local count = #ids
        if count <= 0 then return releaseTruck({ ok=false, err='no_tyres' }) end

        -- Pagar ANTES de comprometer SOLD; se falhar, os entitlements seguem STORED.
        local total = unitPrice * count
        if not BridgeAddCash(src, total, 'fence_tyres') then
            return releaseTruck({ ok=false, err='payment' })
        end
        -- Commit SOLD (idempotente por entitlement; SOLD nunca volta p/ STORED).
        local sold = TruckStorage.CommitSold(storageId, ids)
        if sold < count then
            -- [PR-E hardening] Algum entitlement do snapshot deixou de estar STORED
            -- durante o yield do pagamento (ex.: truck sumiu → OnTruckRemoved → LOST).
            -- Estornar a diferença — o jogador foi pago por count, só `sold` foram vendidos.
            local refund = unitPrice * (count - sold)
            if not BridgeRemoveCash(src, refund, 'fence_tyres_rollback') then
                -- Estorno FALHOU: o jogador ficou com $refund a mais. Fail-closed
                -- econômico — nenhuma nova venda de pneu até limpeza explícita.
                -- NÃO mexer no ledger SOLD/LOST (a venda parcial em si está correta).
                TyreSaleQuarantine[qKey] = (TyreSaleQuarantine[qKey] or 0) + refund
                LogSuspicious(src, 'fence:sellTyres',
                    ('SEVERE: venda parcial player=%s storage=%s count=%d sold=%d refund_esperado=$%d NÃO RECUPERADO — QUARANTINED'):format(
                        qKey, tostring(storageId), count, sold, refund))
            end
            total = unitPrice * sold
        end
        if sold <= 0 then return releaseTruck({ ok=false, err='no_tyres' }) end
        addTrustXp(src, xpPerTyre * sold)
        TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, {}, total, 'tyre')
        return releaseTruck({ ok=true, count=sold, total=total })
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

--- [v1.15 PR-H] Retries de deleção de mundo — IDENTIDADE ESTRITA por MARCADOR
--- server-local. A tentativa em si é `VPChopDeliverCar.tryDeleteCleanupOnce`
--- (sem timer, testável direto); aqui só agendamos e reagendamos.
local function scheduleCarDeleteRetry(netId, mark, expectedFw, attemptsLeft)
    attemptsLeft = attemptsLeft or 5
    SetTimeout(2500, function()
        local res = VPChopDeliverCar.tryDeleteCleanupOnce(DeliveredTombstone[netId], netId, mark, expectedFw)
        if res.aborted then
            print(('[vp_chopshop][deliverCar] retry ABORTADA netId %s: %s. Sem auto-delete.'):format(netId, res.reason or '?'))
            return
        end
        if res.done then return end
        if res.retryable and attemptsLeft > 1 then
            scheduleCarDeleteRetry(netId, mark, expectedFw, attemptsLeft - 1)
        else
            print(('[vp_chopshop][deliverCar] netId %s: deleção de mundo pendente (method=%s) após retries — jogador JÁ pago, tombstone mantido.'):format(netId, res.method))
        end
    end)
end

-- Entregar carro inteiro (Tier 4 + trust 4)
-- [v1.15 PR-H] ORDEM TERMINAL (a reserva de cooldown é a AUTORIDADE, vem ANTES do dinheiro):
--   guards → entity/range → MARCADOR (barreira de entrada) → ownership gate →
--   cooldown SELECT (só p/ `wait`) → RESERVA de cooldown condicional (affectedRows==1) →
--   marcador write+readback → BridgeAddCash → tombstone → BridgeDeleteWorldVehicle →
--   trust → FENCE_DELIVERY.
lib.callback.register('vp_chopshop:fence:deliverCar', function(src, netId)
    if not IsValidSource(src) then return { ok=false } end
    local trust = VPChopFenceGetTrust(src)
    if trust < 4 then return { ok=false, err='no_trust' } end

    local prog = VPChopGetProgression(src)
    if prog.tier < 4 then return { ok=false, err='tier' } end

    local key = ServerChopPlayerKey(src)

    -- [FIX M-3] Mutex por jogador: previne dois deliverCar simultâneos passarem pelo cooldown check
    if DeliveryBusy[key] then return { ok=false, err='processing' } end
    DeliveryBusy[key] = true
    local function release(res) DeliveryBusy[key] = nil; return res end

    netId = tonumber(netId) or 0
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return release({ ok=false, err='vehicle' })
    end
    if not ValidatePlayerNearVehicle(src, veh, 6.0) then
        return release({ ok=false, err='range' })
    end

    -- Guard por veículo (dois jogadores não entregam a MESMA entidade em paralelo).
    if DeliverCarBusy[netId] then return release({ ok=false, err='processing' }) end
    DeliverCarBusy[netId] = key
    local function releaseAll(res) DeliverCarBusy[netId] = nil; return release(res) end

    -- [PR-H] MARCADOR = BARREIRA DE ENTRADA. É a autoridade de identidade da
    -- entidade viva já entregue: sobrevive a resource restart enquanto a carcaça
    -- não some do mundo. Resultado distinguível:
    --   leitura FALHOU        → 'identity' (fail-closed, não sabemos se já foi entregue)
    --   marcador PRESENTE     → 'already_delivered'
    --   marcador AUSENTE      → segue (o tombstone por si só, sem marcador, NÃO bloqueia:
    --                            netId reciclado p/ outra entidade é identidade nova)
    local mrok, curMark = VPChopDeliverCar.readMark(veh)
    if not mrok then
        return releaseAll({ ok=false, err='identity' })
    end
    if curMark ~= nil then
        return releaseAll({ ok=false, err='already_delivered' })
    end

    -- [PR-H] OWNERSHIP GATE — carro persistido (player vehicle) NÃO é entregável.
    -- BridgeResolveVehiclePersistence só LÊ; dúvida ⇒ 'unknown' ⇒ fail-closed.
    -- `DeliverCarOwnedPolicy` (default 'deny'): 'destroy' NÃO implementado → owned|unknown
    -- resulta SEMPRE em DENY (preferimos negar a destruir um player vehicle).
    local ownedPolicy = (Config.Fence and Config.Fence.DeliverCarOwnedPolicy) or 'deny'
    local persistence = BridgeResolveVehiclePersistence(veh, 'deliver_car')
    if persistence.status ~= 'not_owned' then
        if persistence.status == 'unknown' or Config.Debug then
            print(('[vp_chopshop][deliverCar] netId %s: persistence=%s (src=%s, policy=%s) → DENY'):format(
                netId, persistence.status, persistence.source, tostring(ownedPolicy)))
        end
        return releaseAll({ ok=false, err='owned', persistence=persistence.status })
    end

    -- [FIX M-2] Cooldown SELECT — só p/ devolver um `wait` amigável e o valor
    -- anterior de last_car_delivery (p/ rollback). O UPDATE abaixo é a autoridade.
    local cooldownSec = ((Config.Fence and Config.Fence.WholeCarCooldownMin) or 20) * 60
    local cdRow = MySQL.single.await(
        'SELECT GREATEST(0, ? - TIMESTAMPDIFF(SECOND, last_car_delivery, NOW())) as wait_sec, '..
        'UNIX_TIMESTAMP(last_car_delivery) as prev_ts FROM vp_chop_progression WHERE identifier=?',
        {cooldownSec, key}
    )
    if cdRow and (cdRow.wait_sec or 0) > 0 then
        return releaseAll({ ok=false, err='cooldown', wait=cdRow.wait_sec })
    end
    local prevCdTs = cdRow and cdRow.prev_ts or nil

    local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')
    local heatLabel = VPChopHeatGetLabel(plate)
    if heatLabel == 'queimando' then return releaseAll({ ok=false, err='too_hot' }) end

    -- Payout (INALTERADO — esta PR não é balance)
    local _heatLabelToMult = { frio=1.0, morno=0.90, quente=0.75, queimando=0.0 }
    local heatMult  = _heatLabelToMult[heatLabel] or 1.0
    local tierMult  = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.10
    local trustM    = trustMult(trust)
    local nightM    = getNightBonusMultiplier()
    local base      = (Config.Fence and Config.Fence.WholeCarBasePayout) or 8000
    local payout    = math.floor(base * trustM * tierMult * heatMult * nightM)
    local maxCarPayout = math.floor(base * 5)
    payout = math.min(payout, maxCarPayout)

    -- [PR-H] 1) RESERVA DE COOLDOWN CONDICIONAL — autoridade terminal, ANTES do dinheiro.
    -- UPDATE atômico: só grava se o cooldown continua liberado. affectedRows==1
    -- obrigatório. Query lançou erro / affected nil / affected ~= 1 ⇒ NÃO pagar.
    local reserveOk, affected = pcall(function()
        return MySQL.update.await(
            'UPDATE vp_chop_progression SET last_car_delivery=NOW() WHERE identifier=? AND '..
            '(last_car_delivery IS NULL OR TIMESTAMPDIFF(SECOND, last_car_delivery, NOW()) >= ?)',
            {key, cooldownSec}
        )
    end)
    if not reserveOk or affected ~= 1 then
        -- affected==0 → outro caminho reservou primeiro (race) ou linha ausente;
        -- erro na query → 'db'. Nenhum dos dois paga.
        return releaseAll({ ok=false, err = (reserveOk and 'cooldown_race' or 'db') })
    end

    -- [RC-FIX-1a] Rollback da reserva: restaura last_car_delivery ao valor anterior
    -- (ou NULL). Só é CONFIRMADO com affectedRows==1 — `pcall==true` prova apenas
    -- que a query não lançou. query error / nil / false / 0 / >1 ⇒ NÃO confirmado
    -- ⇒ fail-closed (jogador pode ficar com cooldown indevido; preferível a abrir
    -- janela de payout). Nenhuma compensação automática adicional.
    local function rollbackCooldown()
        local ok, affected = pcall(function()
            if prevCdTs then
                return MySQL.update.await('UPDATE vp_chop_progression SET last_car_delivery=FROM_UNIXTIME(?) WHERE identifier=?', {prevCdTs, key})
            end
            return MySQL.update.await('UPDATE vp_chop_progression SET last_car_delivery=NULL WHERE identifier=?', {key})
        end)
        return ok == true and affected == 1
    end

    -- [PR-H] 2) MARCADOR write+readback ANTES de qualquer dinheiro. Não confirmou
    -- ⇒ rollback da reserva + 'identity' (o dinheiro ainda não entrou).
    _deliverMarkSeq = _deliverMarkSeq + 1
    local mark = ('dcm:%d'):format(_deliverMarkSeq)
    if not VPChopDeliverCar.writeMark(veh, mark) then
        if not rollbackCooldown() then
            LogSuspicious(src, 'fence:deliverCar',
                ('SEVERE: marcador não confirmado + rollback de cooldown FALHOU — player %s (sem perda monetária; cooldown fail-closed)'):format(key))
        end
        return releaseAll({ ok=false, err='identity' })
    end

    -- [PR-H] 3) PAGAR. Falha ⇒ limpar marcador + rollback da reserva (dinheiro não entrou).
    if not BridgeAddCash(src, payout, 'fence_car') then
        -- [RC-FIX-1b] clearMark pode falhar — se falhar, o veículo permanece
        -- fail-closed como already_delivered (nova entrega dele é NEGADA), sem
        -- perda econômica. Não forçar limpeza por outro mecanismo — só registrar.
        local markCleared = VPChopDeliverCar.clearMark(veh)
        if not markCleared then
            LogSuspicious(src, 'fence:deliverCar',
                ('SEVERE: pagamento falhou e marcador de entrega NÃO pôde ser removido — player %s, netId %s; veículo pode permanecer fail-closed como already_delivered; nenhum dinheiro foi pago.'):format(key, tostring(netId)))
        end
        if not rollbackCooldown() then
            LogSuspicious(src, 'fence:deliverCar',
                ('pagamento falhou + rollback de cooldown FALHOU — player %s (sem perda monetária; cooldown fail-closed)'):format(key))
        end
        return releaseAll({ ok=false, err='payment' })
    end

    -- [PR-H] 4) tombstone + deleção de mundo. Marcador já gravado → a retry só
    -- deleta ESTA entidade.
    DeliveredTombstone[netId] = { model = GetEntityModel(veh), mark = mark, at = os.time() }
    local del = BridgeDeleteWorldVehicle(veh, { expectedFramework = persistence.framework })

    -- [v1.16 P0.4] persiste no ledger — SÓ para o sweep de boot re-dirigir o cleanup
    -- se a carcaça ficar presa (o retry timer morre num `ensure vp_chopshop`). A
    -- BARREIRA de pagamento do deliverCar continua sendo o statebag vpChopDeliveredMark
    -- acima (ele sobrevive ao restart de resource, o único em que a carcaça sobrevive).
    if (Config.RestartRecovery or {}).Enable ~= false
        and VPChopCarcassLedger and VPChopCarcassLedger.ready() then
        local okv, vsid = pcall(function() return Entity(veh).state.vpChopVsid end)
        VPChopCarcassLedger.mark(netId, GetEntityModel(veh), (okv and vsid) or nil, 'deliver',
            tostring(key), del.existsAfter == true)
    end

    addTrustXp(src, (Config.Fence and Config.Fence.XpOrderBonus) or 80)
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, {}, payout, 'car')

    if del.existsAfter then
        -- Carro não sumiu. Jogador JÁ pago + cooldown reservado; o marcador bloqueia
        -- re-entrega. NÃO estornar (a entrega ocorreu). Retries com identidade estrita.
        print(('[vp_chopshop][deliverCar] netId %s: BridgeDeleteWorldVehicle não removeu o carro (method=%s) — jogador pago, cleanupPending.'):format(netId, del.method))
        scheduleCarDeleteRetry(netId, mark, persistence.framework)
        return releaseAll({ ok=true, payout=payout, cleanupPending=true })
    end

    return releaseAll({ ok=true, payout=payout })
end)

-- [v1.15 PR-H] Limpeza do guard/tombstone de entrega quando o carro enfim sai do mundo.
AddEventHandler('entityRemoved', function(entity)
    local nid = NetworkGetNetworkIdFromEntity(entity)
    if not nid or nid == 0 then return end
    DeliverCarBusy[nid] = nil
    DeliveredTombstone[nid] = nil
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
