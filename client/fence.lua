-- client/fence.lua
-- Blip rotativo, targets ox_target no NPC fence, props de pneu no chão,
-- sistema de carry de pneu no ombro e carregamento em pickup truck.

local FenceNpcEnt    = nil ---@type integer|nil
local FenceBlip      = nil ---@type integer|nil
local CurrentLocIdx  = 1
local TyrePropList   = {} ---@type table<integer, {prop:integer, timer:integer}>  [propHandle] = dados
local CarryingTyre   = nil ---@type {prop:integer}|nil

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

        if trust >= 1 then
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
            options[#options+1] = {
                name='vp_fence_tyre_contract', label=L('fence_target_tyre_contract'),
                icon='fa-solid fa-file-contract', distance=2.5,
                onSelect=function() TyreMissionStart() end,
            }
        end

        if trust >= 2 then
            options[#options+1] = {
                name='vp_fence_hot_job', label=L('fence_target_hot_job'),
                icon='fa-solid fa-skull-crossbones', distance=2.5,
                onSelect=function() tryNpcMission() end,
            }
            options[#options+1] = {
                name='vp_fence_buy_bench', label=L('fence_target_buy_bench'),
                icon='fa-solid fa-toolbox', distance=2.5,
                onSelect=function() tryNpcBuy('bench') end,
            }
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
        lib.notify({ description='Contato mudou para: ' .. label, type='inform', duration=6000 })
        setFenceBlip(coords, true)
    else
        lib.notify({ description='O contato mudou de local.', type='inform', duration=5000 })
    end
end)

RegisterNetEvent('vp_chopshop:client:trustUp', function(newLevel)
    local labels = { [1]='Conhecido', [2]='Confiável', [3]='Parceiro', [4]='Sócio' }
    lib.notify({
        title='Fence — ' .. (labels[newLevel] or 'Nível ' .. newLevel),
        description='Você ganhou a confiança do contato.',
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
        lib.notify({ description='Nada para vender.', type='error' }); return
    end
    -- Montar context menu com todos os itens vendáveis
    local opts = {}
    for _, s in ipairs(sellable) do
        opts[#opts+1] = {
            title    = s.name .. ' ×' .. s.amount,
            metadata = {{ label='Preço base', value='$'..s.unitPrice..' un.' }},
            onSelect = function()
                local ok, res = pcall(lib.callback.await, 'vp_chopshop:fence:sellItems', false, {{name=s.name, amount=s.amount}})
                if ok and res and res.ok then
                    lib.notify({ description='Vendido por $'..res.total, type='success' })
                else
                    lib.notify({ description='Falha na venda.', type='error' })
                end
            end,
        }
    end
    lib.registerContext({ id='vp_fence_sell', title='Vender Materiais', options=opts })
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
        lib.notify({ description=res.count..' pneu(s) vendido(s) por $'..res.total, type='success' })
    else
        lib.notify({ description=(res and res.err == 'no_tyres') and 'Nenhum pneu disponível.' or 'Falha.', type='error' })
    end
end

function showStatus()
    local ok, prog = pcall(lib.callback.await, 'vp_chopshop:getProgression', false)
    if not ok or not prog then lib.notify({ description='Erro ao carregar status.', type='error' }); return end
    local tierLabels = { [1]='Novato', [2]='Mecânico', [3]='Especialista', [4]='Mestre' }
    lib.registerContext({
        id='vp_fence_status', title='Seu Status',
        options={{
            title='Perfil',
            readOnly=true,
            metadata={
                { label='Tier',    value=tierLabels[prog.tier] or prog.tier },
                { label='XP',      value=prog.xp .. (prog.nextXp and ' / '..prog.nextXp or ' (máx)') },
                { label='Chapas',  value=prog.totalChops },
            }
        }}
    })
    lib.showContext('vp_fence_status')
end

function showOrder()
    local ok, order = pcall(lib.callback.await, 'vp_chopshop:fence:getOrder', false)
    if not ok or not order then
        lib.notify({ description='Nenhuma encomenda disponível.', type='inform' }); return
    end
    local remaining = math.max(0, order.deadline - os.time())
    local hours = math.floor(remaining / 3600)
    local mins  = math.floor((remaining % 3600) / 60)
    local itemStr = ''
    for item, amount in pairs(order.items) do
        itemStr = itemStr .. amount .. '× ' .. item .. '  '
    end
    lib.registerContext({
        id='vp_fence_order_view', title='Encomenda Ativa',
        options={{
            title='Detalhes',
            readOnly=true,
            metadata={
                { label='Itens',    value=itemStr },
                { label='Bônus',    value='×'..order.mult },
                { label='Prazo',    value=hours..'h '..mins..'min' },
            }
        }}
    })
    lib.showContext('vp_fence_order_view')
end

function fulfillOrder()
    local ok, order = pcall(lib.callback.await, 'vp_chopshop:fence:getOrder', false)
    if not ok or not order then
        lib.notify({ description='Nenhuma encomenda ativa.', type='error' }); return
    end
    local ok2, res = pcall(lib.callback.await, 'vp_chopshop:fence:fulfillOrder', false, order.id)
    if ok2 and res and res.ok then
        lib.notify({ description='Encomenda entregue! $'..res.total, type='success', duration=7000 })
    elseif res and res.err == 'missing_item' then
        lib.notify({ description='Faltam '..res.need..'× '..res.item, type='error' })
    elseif res and res.err == 'expired' then
        lib.notify({ description='Encomenda expirou.', type='error' })
    else
        lib.notify({ description='Falha na entrega.', type='error' })
    end
end

function deliverCar()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then
        lib.notify({ description='Entre no veículo que quer entregar.', type='error' }); return
    end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local ok, res = pcall(lib.callback.await, 'vp_chopshop:fence:deliverCar', false, netId)
    if ok and res and res.ok then
        lib.notify({ description='Veículo entregue por $'..res.payout, type='success', duration=7000 })
    elseif res and res.err == 'too_hot' then
        lib.notify({ description='Veículo quente demais. Fence recusa.', type='error' })
    elseif res and res.err == 'cooldown' then
        local mins = math.ceil(res.wait / 60)
        lib.notify({ description='Aguarde '..mins..' min.', type='error' })
    else
        lib.notify({ description='Fence não quer isso agora.', type='error' })
    end
end

-- ─── Props de pneu no chão ────────────────────────────────────────────────────

--- Spawna prop de pneu no chão na posição indicada.
---@param position vector3
---@return integer  propHandle
function VPChopSpawnTyreProp(position)
    local model = `prop_cs_wheel_01`
    RequestModel(model)
    -- [FIX M-5] Wait(100) em vez de Wait(10): sub-frame polling desperdiça wakeups
    local t = GetGameTimer() + 4000
    while not HasModelLoaded(model) and GetGameTimer() < t do Wait(100) end
    if not HasModelLoaded(model) then return 0 end

    local prop = CreateObjectNoOffset(model, position.x, position.y, position.z, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not prop or prop == 0 then return 0 end

    PlaceObjectOnGroundProperly(prop)

    local despawnMs = (Config.Fence and Config.Fence.TyrePropDespawnMs) or 600000
    local spawnTime = GetGameTimer()

    -- Target no prop
    exports.ox_target:addLocalEntity(prop, {
        {
            name     = 'vp_tyre_pick_' .. tostring(prop),
            label    = 'Pegar pneu',
            icon     = 'fa-solid fa-hand',
            distance = 2.0,
            onSelect = function() VPChopPickUpTyre(prop) end,
        },
        {
            name     = 'vp_tyre_load_' .. tostring(prop),
            label    = 'Carregar no truck',
            icon     = 'fa-solid fa-truck',
            distance = 2.0,
            canInteract = function()
                local ppos = GetEntityCoords(PlayerPedId())
                local hashes = getTruckHashes()
                for _, veh in ipairs(GetGamePool('CVehicle')) do
                    if DoesEntityExist(veh) and #(ppos - GetEntityCoords(veh)) < 5.0 then
                        local model = GetEntityModel(veh)
                        for _, h in ipairs(hashes) do
                            if model == h then return true end
                        end
                    end
                end
                return false
            end,
            onSelect = function() VPChopLoadTyreInTruck(prop) end,
        },
    })

    TyrePropList[prop] = { prop=prop, timer=spawnTime }

    -- Auto-despawn
    CreateThread(function()
        Wait(despawnMs)
        VPChopRemoveTyreProp(prop)
    end)

    return prop
end

--- Remove prop de pneu do mundo.
---@param propHandle integer
function VPChopRemoveTyreProp(propHandle)
    if not TyrePropList[propHandle] then return end
    exports.ox_target:removeLocalEntity(propHandle)
    if DoesEntityExist(propHandle) then DeleteObject(propHandle) end
    TyrePropList[propHandle] = nil
end

--- Pega pneu do chão e carrega no ombro.
---@param propHandle integer
function VPChopPickUpTyre(propHandle)
    if CarryingTyre then
        lib.notify({ description='Já está carregando um pneu.', type='error' }); return
    end
    VPChopRemoveTyreProp(propHandle)

    local model = `prop_cs_wheel_01`
    RequestModel(model)
    -- [FIX M-5] Wait(100)
    local t = GetGameTimer() + 3000
    while not HasModelLoaded(model) and GetGameTimer() < t do Wait(100) end
    if not HasModelLoaded(model) then return end

    local ped  = PlayerPedId()
    local prop = CreateObjectNoOffset(model, 0, 0, 0, false, false, false)
    SetModelAsNoLongerNeeded(model)
    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, 60309),
        0.15, 0.05, 0.0,  -- offset
        0.0, 90.0, 0.0,   -- rotation
        true, true, false, true, 1, true)

    CarryingTyre = { prop=prop }
    lib.notify({ description='Carregando pneu. [E] = carregar no truck · [X] = largar', type='inform', duration=4000 })

    -- Thread para E/X enquanto carrega
    CreateThread(function()
        while CarryingTyre do
            Wait(50)
            -- X = largar no chão
            if IsControlJustReleased(0, 73) then  -- X
                VPChopDropTyre()
                return
            end
            -- E = carregar no truck próximo
            if IsControlJustReleased(0, 38) then  -- E
                local ppos = GetEntityCoords(ped)
                local hashes = getTruckHashes()
                for _, veh in ipairs(GetGamePool('CVehicle')) do
                    if DoesEntityExist(veh) and #(ppos - GetEntityCoords(veh)) < 4.0 then
                        local vm = GetEntityModel(veh)
                        for _, h in ipairs(hashes) do
                            if vm == h then
                                VPChopLoadTyreInTruckFromCarry(veh)
                                return
                            end
                        end
                    end
                end
            end
        end
    end)
end

--- Larga pneu no chão.
function VPChopDropTyre()
    if not CarryingTyre then return end
    local prop = CarryingTyre.prop
    CarryingTyre = nil
    if DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        local pos = GetEntityCoords(PlayerPedId())
        VPChopSpawnTyreProp(pos)
        DeleteObject(prop)
    end
end

--- Carrega pneu no truck (a partir de prop no chão).
---@param propHandle integer
function VPChopLoadTyreInTruck(propHandle)
    local ped   = PlayerPedId()
    local ppos  = GetEntityCoords(ped)
    -- [FIX M-1] Usar getTruckHashes() (cache) em vez de joaat(m) por iteração
    local hashes = getTruckHashes()
    local truck = nil
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) and #(ppos - GetEntityCoords(veh)) < 5.0 then
            local vm = GetEntityModel(veh)
            for _, h in ipairs(hashes) do
                if vm == h then truck = veh; break end
            end
        end
        if truck then break end
    end
    if not truck then lib.notify({ description='Sem pickup perto.', type='error' }); return end

    local max = (Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4
    local cur = math.floor(tonumber(Entity(truck).state.chopTyreCount) or 0)
    if cur >= max then lib.notify({ description='Truck cheio!', type='error' }); return end

    VPChopRemoveTyreProp(propHandle)
    Entity(truck).state:set('chopTyreCount', cur + 1, true)
    lib.notify({ description='Pneu carregado ('.. (cur+1) ..'/'..max..').', type='success', duration=2500 })
end

--- Carrega pneu no truck a partir do carry.
---@param truck integer
function VPChopLoadTyreInTruckFromCarry(truck)
    if not CarryingTyre then return end
    local max = (Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4
    local cur = math.floor(tonumber(Entity(truck).state.chopTyreCount) or 0)
    if cur >= max then lib.notify({ description='Truck cheio!', type='error' }); return end

    local prop = CarryingTyre.prop
    CarryingTyre = nil
    if DoesEntityExist(prop) then DeleteObject(prop) end

    Entity(truck).state:set('chopTyreCount', cur + 1, true)
    lib.notify({ description='Pneu carregado ('.. (cur+1) ..'/'..max..').', type='success', duration=2500 })
end

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeFenceBlip()
    if FenceNpcEnt then exports.ox_target:removeLocalEntity(FenceNpcEnt) end
    if CarryingTyre and DoesEntityExist(CarryingTyre.prop) then DeleteObject(CarryingTyre.prop) end
    for handle, _ in pairs(TyrePropList) do
        exports.ox_target:removeLocalEntity(handle)
        if DoesEntityExist(handle) then DeleteObject(handle) end
    end
    TyrePropList = {}
end)
