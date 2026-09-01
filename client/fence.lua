-- client/fence.lua
-- Blip rotativo, targets ox_target no NPC fence, menus de interação do fence.
-- (O fluxo vivo de pneu→ombro→truck está em client/main.lua.)

local FenceNpcEnt    = nil ---@type integer|nil
local FenceBlip      = nil ---@type integer|nil
local CurrentLocIdx  = 1

-- Cache de hashes de modelo de truck (calculado uma vez, não por-frame)
local TruckModelHashes = nil
local function getTruckHashes()
    if TruckModelHashes then return TruckModelHashes end
    TruckModelHashes = {}
    for _, m in ipairs(Config.TyreSelling and Config.TyreSelling.PickupTruckModels or {}) do
        TruckModelHashes[#TruckModelHashes + 1] = joaat(m)
    end
    return TruckModelHashes
end

-- [M1 FIX] Cache compartilhado de proximidade de truck para canInteract.
-- Todos os props de pneu fazem o mesmo check — cache evita N GetGamePool por frame.
local _truckNearCache = false
local _truckNearTimer = 0
local TRUCK_NEAR_INTERVAL = 500  -- ms entre scans

-- [AUDIT A1] Global para reuso no canInteract de props de pneu no chão (client/main.lua),
-- que antes usava VPChopFindNearestTruck (GetGamePool nu) por frame.
function VPChopIsTruckNearby()
    local now = GetGameTimer()
    if now - _truckNearTimer < TRUCK_NEAR_INTERVAL then return _truckNearCache end
    _truckNearTimer = now
    _truckNearCache = false
    local ppos   = GetEntityCoords(PlayerPedId())
    local hashes = getTruckHashes()
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) and #(ppos - GetEntityCoords(veh)) < 5.0 then
            local model = GetEntityModel(veh)
            for _, h in ipairs(hashes) do
                if model == h then _truckNearCache = true; break end
            end
        end
        if _truckNearCache then break end
    end
    return _truckNearCache
end

function VPChopFindNearestTruck(radius)
    local maxDist = radius or 5.0
    local ppos = GetEntityCoords(PlayerPedId())
    local hashes = getTruckHashes()
    local nearest, minDist = nil, maxDist
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) then
            local dist = #(ppos - GetEntityCoords(veh))
            if dist < minDist then
                local model = GetEntityModel(veh)
                for _, h in ipairs(hashes) do
                    if model == h then
                        nearest = veh
                        minDist = dist
                        break
                    end
                end
            end
        end
    end
    return nearest
end

-- ─── Blip ─────────────────────────────────────────────────────────────────────

local function removeFenceBlip()
    if FenceBlip and DoesBlipExist(FenceBlip) then RemoveBlip(FenceBlip) end
    FenceBlip = nil
end

local function setFenceBlip(coords, precise)
    removeFenceBlip()
    local bx, by = coords.x, coords.y
    if not precise then
        -- Offset aleatório ~150m para trust 1-2
        bx = bx + math.random(-150, 150)
        by = by + math.random(-150, 150)
    end
    FenceBlip = AddBlipForCoord(bx, by, coords.z)
    SetBlipSprite(FenceBlip, precise and 140 or 161)
    SetBlipColour(FenceBlip, precise and 1 or 4)
    SetBlipScale(FenceBlip, 0.8)
    SetBlipAsShortRange(FenceBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(precise and 'Fence' or '?')
    EndTextCommandSetBlipName(FenceBlip)
end

-- ─── Setup NPC ───────────────────────────────────────────────────────────────

RegisterNetEvent('vp_chopshop:client:setupFenceNpc', function(data)
    if not data or not data.nwid then return end
    CurrentLocIdx = data.locationIdx or 1

    CreateThread(function()
        local ent, tries = 0, 0
        while (not ent or ent == 0 or not DoesEntityExist(ent)) and tries < 40 do
            Wait(100)
            ent = NetworkGetEntityFromNetworkId(data.nwid)
            tries = tries + 1
        end
        if not ent or ent == 0 or not DoesEntityExist(ent) then return end

        FenceNpcEnt = ent
        FreezeEntityPosition(ent, true)
        SetEntityInvincible(ent, true)
        SetBlockingOfNonTemporaryEvents(ent, true)

        -- Scenario do ped: aplicado client-side (era feito no server, mas TaskStartScenarioInPlace é client-only)
        local locCfg = Config.Fence and Config.Fence.Locations and Config.Fence.Locations[CurrentLocIdx]
        if locCfg and locCfg.scenario and locCfg.scenario ~= '' then
            TaskStartScenarioInPlace(ent, locCfg.scenario, 0, true)
        end

        -- Buscar nível de trust (callback separado — getProgression NÃO retorna trust)
        local ok, trust = pcall(lib.callback.await, 'vp_chopshop:fence:getTrust', false)
        trust = (ok and type(trust) == 'number') and trust or 0

        -- Blip baseado em trust
        local locs = Config.Fence and Config.Fence.Locations
        if locs and locs[CurrentLocIdx] then
            local c = locs[CurrentLocIdx].coords
            if trust <= 0 then
                removeFenceBlip()
            elseif trust <= 2 then
                setFenceBlip(c, false)
            else
                setFenceBlip(c, true)
            end
        end

        -- Montar targets
        local options = {}

        -- [FIX L-2] Labels via L() para respeitar o sistema de locales (pt/en/es/fr/tr)
        if trust == 0 then
            options[#options+1] = {
                name='vp_fence_introduce', label=L('fence_target_introduce'),
                icon='fa-solid fa-handshake', distance=2.5,
                onSelect=function()
                    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:fence:introduce', false)
                    if cbOk and res and res.ok then
                        lib.notify({ description=L('fence_notify_introduced'), type='success' })
                    else
                        lib.notify({ description=L('fence_notify_no_referral'), type='error' })
                    end
                end,
            }
        end

local function sellCarriedCatalytic()
    if not VPChopCarryingPart or VPChopCarryingPart.partKey ~= 'catalytic_converter' then return end

    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:fence:sellCatalytic', false)
    if not cbOk or not res or not res.ok then
        VPChopNotify(L('notify_generic_error'), 'error')
        return
    end

    VPChopDropCarryPart()
    VPChopNotify(L('fence_catalytic_sold_fmt', res.payout or 1500), 'success')
end

        if trust >= 1 then
            options[#options+1] = {
                name='vp_fence_sell_catalytic', label=L('fence_sell_catalytic_label'),
                icon='fa-solid fa-fire-flame-curved', distance=2.5,
                canInteract=function()
                    return VPChopCarryingPart and VPChopCarryingPart.partKey == 'catalytic_converter'
                end,
                onSelect=function() sellCarriedCatalytic() end,
            }
            options[#options+1] = {
                name='vp_fence_sell_items', label=L('fence_target_sell_items'),
                icon='fa-solid fa-boxes-stacked', distance=2.5,
                onSelect=function() openSellMenu() end,
            }
            options[#options+1] = {
                name='vp_fence_sell_tyres', label=L('fence_target_sell_tyres'),
                icon='fa-solid fa-circle-dot', distance=2.5,
                onSelect=function() sellTyres() end,
            }
            -- [M3 FIX] Only register the contract target when the feature is actually
            -- enabled. When disabled the stub body shows "Erro." — hide instead.
            if Config.TyreMission and Config.TyreMission.Enable then
                options[#options+1] = {
                    name='vp_fence_tyre_contract', label=L('fence_target_tyre_contract'),
                    icon='fa-solid fa-file-contract', distance=2.5,
                    onSelect=function() TyreMissionStart() end,
                }
            end
        end

        if trust >= 2 then
            options[#options+1] = {
                name='vp_fence_hot_job', label=L('fence_target_hot_job'),
                icon='fa-solid fa-skull-crossbones', distance=2.5,
                onSelect=function() tryNpcMission() end,
            }
            -- [LIMPEZA] Só mostra "comprar bancada" se a loja estiver ligada — senão o
            -- callback retorna err='disabled' e o jogador via uma notificação de erro.
            if Config.NPC and Config.NPC.Shop and Config.NPC.Shop.Enable then
                options[#options+1] = {
                    name='vp_fence_buy_bench', label=L('fence_target_buy_bench'),
                    icon='fa-solid fa-toolbox', distance=2.5,
                    onSelect=function() tryNpcBuy('bench') end,
                }
            end
            options[#options+1] = {
                name='vp_fence_status', label=L('fence_target_status'),
                icon='fa-solid fa-chart-line', distance=2.5,
                onSelect=function() showStatus() end,
            }
        end

        if trust >= 3 then
            options[#options+1] = {
                name='vp_fence_order', label=L('fence_target_order'),
                icon='fa-solid fa-clipboard-list', distance=2.5,
                onSelect=function() showOrder() end,
            }
            options[#options+1] = {
                name='vp_fence_fulfill', label=L('fence_target_fulfill'),
                icon='fa-solid fa-box-open', distance=2.5,
                onSelect=function() fulfillOrder() end,
            }
        end

        if trust >= 4 then
            options[#options+1] = {
                name='vp_fence_deliver_car', label=L('fence_target_deliver_car'),
                icon='fa-solid fa-car-burst', distance=2.5,
                onSelect=function() deliverCar() end,
            }
        end

        exports.ox_target:addLocalEntity(FenceNpcEnt, options)
    end)
end)

RegisterNetEvent('vp_chopshop:client:removeFenceNpc', function(nwid)
    if FenceNpcEnt then
        exports.ox_target:removeLocalEntity(FenceNpcEnt)
        FenceNpcEnt = nil
    end
    removeFenceBlip()
end)

RegisterNetEvent('vp_chopshop:client:fenceRotated', function(label, coords)
    if label and coords then
        lib.notify({ description=L('fence_rotated_to_fmt', label), type='inform', duration=6000 })
        setFenceBlip(coords, true)
    else
        lib.notify({ description=L('fence_rotated_unknown'), type='inform', duration=5000 })
    end
end)

RegisterNetEvent('vp_chopshop:client:trustUp', function(newLevel)
    local levelLabel = L('fence_trust_level_' .. tostring(newLevel))
    lib.notify({
        title=L('fence_trust_up_title_fmt', levelLabel),
        description=L('fence_trust_up_desc'),
        type='success', duration=7000,
    })
end)

-- ─── Funções migradas de client/npc.lua (tombstone) ─────────────────────────
-- [FIX M-2] tryNpcMission e tryNpcBuy eram locais em client/npc.lua.
-- Como client/npc.lua vira tombstone, devem ser definidas aqui como globals.

function tryNpcMission()
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:npcAcceptMission', false)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopNotify(L('notify_mission_accepted'), 'inform', 9000)
    elseif res and res.err == 'distance' then
        VPChopNotify(L('notify_npc_too_far'), 'error')
    elseif res and res.err == 'cooldown' and res.wait then
        VPChopNotify(L('notify_mission_cooldown_fmt', res.wait), 'error')
    elseif res and res.err == 'active' then
        VPChopNotify(L('notify_mission_active'), 'error')
    elseif res and res.err == 'ambush_off' then
        VPChopNotify(L('notify_mission_ambush_off'), 'error')
    elseif res and res.err == 'disabled' then
        VPChopNotify(L('notify_mission_disabled'), 'error')
    else
        VPChopNotify(L('notify_generic_error'), 'error')
    end
end

-- [C1 FIX] TyreMissionStart não foi migrada de client/npc.lua.
-- Stub adicionado para evitar erro Lua (call nil). Implementação completa pendente
-- (requer callback servidor + spawn de veículo alvo + tracking de missão).
function TyreMissionStart()
    if not Config.TyreMission or not Config.TyreMission.Enable then
        VPChopNotify(L('notify_mission_disabled'), 'error'); return
    end
    VPChopNotify(L('notify_generic_error'), 'error')
    -- TODO: implementar callback vp_chopshop:fence:tyreMissionAccept e
    --       fluxo completo de missão (spawn veículo, blip, tracking, bônus).
end

-- [FIX M-2] Usa vp_chopshop:fence:buyBench em vez de vp_chopshop:npcBuy.
-- O callback legado npcBuy valida contra Config.NPC.Coords (coords fixas) —
-- incompatível com o fence rotativo. O novo callback valida contra a localização atual do fence.
function tryNpcBuy(kind)
    if kind ~= 'bench' then return end  -- apenas bench implementado no fence
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:fence:buyBench', false)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopNotify(L('notify_buy_ok'), 'success')
    elseif res and res.err == 'money' then
        VPChopNotify(L('notify_buy_fail_money'), 'error')
    elseif res and res.err == 'distance' then
        VPChopNotify(L('notify_npc_too_far'), 'error')
    else
        VPChopNotify(
            (res and res.err) and L('notify_chop_failed_fmt', VPChopLocaleErr(res.err)) or L('notify_generic_error'),
            'error'
        )
    end
end

-- ─── Menus de interação ───────────────────────────────────────────────────────

function openSellMenu()
    local sellable = {}
    local prices   = Config.Fence and Config.Fence.BasePrices or {}
    for item, _ in pairs(prices) do
        local count = exports.ox_inventory:Search('count', item)
        if count and count > 0 then
            sellable[#sellable+1] = { name=item, amount=count, unitPrice=prices[item] }
        end
    end
    if #sellable == 0 then
        lib.notify({ description=L('fence_nothing_to_sell'), type='error' }); return
    end
    -- Montar context menu com todos os itens vendáveis
    local opts = {}
    for _, s in ipairs(sellable) do
        opts[#opts+1] = {
            title    = s.name .. ' ×' .. s.amount,
            metadata = {{ label=L('fence_sell_price_label'), value='$'..s.unitPrice..' un.' }},
            onSelect = function()
                local ok, res = pcall(lib.callback.await, 'vp_chopshop:fence:sellItems', false, {{name=s.name, amount=s.amount}})
                if ok and res and res.ok then
                    lib.notify({ description=L('fence_sold_fmt', res.total), type='success' })
                else
                    lib.notify({ description=L('fence_sale_failed'), type='error' })
                end
            end,
        }
    end
    lib.registerContext({ id='vp_fence_sell', title=L('fence_sell_title'), options=opts })
    lib.showContext('vp_fence_sell')
end

function sellTyres()
    -- Detectar pickup truck próxima com pneus carregados
    local ped = PlayerPedId()
    local pcoords = GetEntityCoords(ped)
    local truckNetId = nil
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) then
            local dist = #(pcoords - GetEntityCoords(veh))
            if dist < 8.0 and Entity(veh).state.chopTyreCount and Entity(veh).state.chopTyreCount > 0 then
                truckNetId = NetworkGetNetworkIdFromEntity(veh)
                break
            end
        end
    end

    local srcType = truckNetId and 'truck' or 'inventory'
    local ok, res = pcall(lib.callback.await, 'vp_chopshop:fence:sellTyres', false, srcType, truckNetId)
    if ok and res and res.ok then
        lib.notify({ description=L('fence_tyres_sold_fmt', res.count, res.total), type='success' })
    else
        lib.notify({ description=L(res and res.err == 'no_tyres' and 'fence_no_tyres' or 'fence_sale_generic_failed'), type='error' })
    end
end

function showStatus()
    local ok, prog = pcall(lib.callback.await, 'vp_chopshop:getProgression', false)
    if not ok or not prog then lib.notify({ description=L('fence_status_error'), type='error' }); return end
    lib.registerContext({
        id='vp_fence_status', title=L('fence_status_title'),
        options={{
            title=L('fence_status_profile'),
            readOnly=true,
            metadata={
                { label=L('fence_tier_label'),  value=L('tier_label_' .. prog.tier) },
                { label=L('fence_xp_label'),    value=prog.xp .. (prog.nextXp and ' / '..prog.nextXp or ' (máx)') },
                { label=L('fence_chops_label'), value=prog.totalChops },
            }
        }}
    })
    lib.showContext('vp_fence_status')
end

function showOrder()
    local ok, order = pcall(lib.callback.await, 'vp_chopshop:fence:getOrder', false)
    if not ok or not order then
        lib.notify({ description=L('fence_no_order'), type='inform' }); return
    end
    local remaining = math.max(0, order.deadline - os.time())
    local hours = math.floor(remaining / 3600)
    local mins  = math.floor((remaining % 3600) / 60)
    local itemStr = ''
    for item, amount in pairs(order.items) do
        itemStr = itemStr .. amount .. '× ' .. item .. '  '
    end
    lib.registerContext({
        id='vp_fence_order_view', title=L('fence_order_title'),
        options={{
            title=L('fence_order_details'),
            readOnly=true,
            metadata={
                { label=L('fence_order_items_label'),    value=itemStr },
                { label=L('fence_order_bonus_label'),    value='\195\151'..order.mult },
                { label=L('fence_order_deadline_label'), value=hours..'h '..mins..'min' },
            }
        }}
    })
    lib.showContext('vp_fence_order_view')
end

function fulfillOrder()
    local ok, order = pcall(lib.callback.await, 'vp_chopshop:fence:getOrder', false)
    if not ok or not order then
        lib.notify({ description=L('fence_no_active_order'), type='error' }); return
    end
    local ok2, res = pcall(lib.callback.await, 'vp_chopshop:fence:fulfillOrder', false, order.id)
    if ok2 and res and res.ok then
        lib.notify({ description=L('fence_order_delivered_fmt', res.total), type='success', duration=7000 })
    elseif res and res.err == 'missing_item' then
        lib.notify({ description=L('fence_order_missing_fmt', res.need, res.item), type='error' })
    elseif res and res.err == 'expired' then
        lib.notify({ description=L('fence_order_expired'), type='error' })
    else
        lib.notify({ description=L('fence_delivery_failed'), type='error' })
    end
end

function deliverCar()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then
        lib.notify({ description=L('fence_car_no_vehicle'), type='error' }); return
    end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local ok, res = pcall(lib.callback.await, 'vp_chopshop:fence:deliverCar', false, netId)
    if ok and res and res.ok then
        lib.notify({ description=L('fence_car_delivered_fmt', res.payout), type='success', duration=7000 })
    elseif res and res.err == 'too_hot' then
        lib.notify({ description=L('fence_car_too_hot'), type='error' })
    elseif res and res.err == 'cooldown' then
        local mins = math.ceil(res.wait / 60)
        lib.notify({ description=L('fence_car_wait_fmt', mins), type='error' })
    elseif res and (res.err == 'owned' or res.err == 'already_delivered' or res.err == 'identity') then
        lib.notify({ description=L('err_' .. res.err), type='error' })
    elseif res and res.err == 'cooldown_race' then
        lib.notify({ description=L('err_cooldown'), type='error' })
    elseif res and res.err == 'payment' then
        lib.notify({ description=L('err_payment'), type='error' })
    else
        lib.notify({ description=L('fence_car_refused'), type='error' })
    end
end

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeFenceBlip()
    if FenceNpcEnt then exports.ox_target:removeLocalEntity(FenceNpcEnt) end
end)
