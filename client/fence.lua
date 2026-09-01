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

-- ─── Venda Direta de Peça Carregada ──────────────────────────────────────────

local physicalPartKeys = {
    catalytic_converter = true,
    adv_engine          = true,
    bonnet              = true,
    boot                = true,
    door_dside_f        = true,
    door_pside_f        = true,
    door_dside_r        = true,
    door_pside_r        = true,
}

local function sellCarriedPart()
    if not VPChopCarryingPart or not physicalPartKeys[VPChopCarryingPart.partKey] then return end
    local entId = VPChopCarryingPart.entitlementId
    if not entId then
        VPChopNotify(L('notify_generic_error'), 'error')
        return
    end

    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:fence:sellCarriedPart', false, entId)
    if not cbOk or not res or not res.ok then
        if res and res.terminalConsumed then
            VPChopDropCarryPart()
        end
        VPChopNotify(VPChopLocaleErr(res and res.err) or L('notify_generic_error'), 'error')
        return
    end

    VPChopDropCarryPart()
    local payout = res.payout or 0
    VPChopNotify(L('fence_part_sold_fmt', payout), 'success')
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

        -- Montar targets: UMA interação principal com o Intermediário + deliverCar em veículo
        local options = {}

        options[#options + 1] = {
            name     = 'vp_broker_talk',
            label    = L('broker_target_talk'),
            icon     = 'fa-solid fa-comments',
            distance = 2.5,
            onSelect = function()
                openBrokerMainMenu()
            end,
        }

        if trust >= 4 then
            options[#options + 1] = {
                name        = 'vp_fence_deliver_car',
                label       = L('fence_target_deliver_car'),
                icon        = 'fa-solid fa-car-burst',
                distance    = 4.5,
                canInteract = function()
                    return IsPedInAnyVehicle(PlayerPedId(), false)
                end,
                onSelect    = function()
                    deliverCar()
                end,
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

-- ─── Broker Context UI (v1.17 BROKER-5) ──────────────────────────────────────

local function fetchBrokerContext()
    local ok, res = pcall(lib.callback.await, 'vp_chopshop:broker:getNpcContext', false)
    if not ok or not res or not res.ok then
        VPChopNotify(VPChopLocaleErr(res and res.err) or L('notify_generic_error'), 'error')
        return nil
    end
    return res
end

function openBrokerMainMenu()
    local ctx = fetchBrokerContext()
    if not ctx then return end

    local trustLvl = (ctx.trust and ctx.trust.level) or 0
    local greetingKey = 'broker_greeting_trust_' .. tostring(math.min(4, math.max(0, trustLvl)))
    local greeting = L(greetingKey)
    local alias = (ctx.broker and ctx.broker.alias) or L('broker_menu_main_title')
    local cap = ctx.capabilities or {}

    local options = {}

    -- Introdução (Trust 0)
    if cap.introduce then
        options[#options + 1] = {
            title       = L('fence_target_introduce'),
            description = greeting,
            icon        = 'fa-solid fa-handshake',
            onSelect    = function()
                local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:fence:introduce', false)
                if cbOk and res and res.ok then
                    lib.notify({ description = L('fence_notify_introduced'), type = 'success' })
                    openBrokerMainMenu()
                else
                    lib.notify({ description = L('fence_notify_no_referral'), type = 'error' })
                end
            end,
        }
    else
        -- Cabeçalho / Cartão de Persona
        options[#options + 1] = {
            title       = alias .. ' — ' .. L('fence_trust_level_' .. tostring(trustLvl)),
            description = greeting,
            readOnly    = true,
            icon        = 'fa-solid fa-user-secret',
            metadata    = {
                { label = L('fence_status_profile'), value = L('tier_label_' .. (ctx.progression and ctx.progression.tier or 1)) },
                { label = 'Local', value = (ctx.broker and ctx.broker.locationLabel) or 'Los Santos' },
            },
        }

        -- Vender (peça carregada, materiais, pneus)
        if cap.sellPart or cap.sellItems or cap.sellTyres then
            options[#options + 1] = {
                title       = L('broker_menu_sell'),
                description = L('broker_menu_sell_desc'),
                icon        = 'fa-solid fa-hand-holding-dollar',
                onSelect    = function()
                    openBrokerSellMenu(ctx)
                end,
            }
        end

        -- Procura & Contratos
        if cap.contracts then
            options[#options + 1] = {
                title       = L('broker_menu_contracts'),
                description = L('broker_menu_contracts_desc'),
                icon        = 'fa-solid fa-file-contract',
                onSelect    = function()
                    openBrokerContractsMenu()
                end,
            }
        end

        -- Trabalhos / Missões
        if cap.hotJob then
            options[#options + 1] = {
                title       = L('broker_menu_jobs'),
                description = L('broker_menu_jobs_desc'),
                icon        = 'fa-solid fa-skull-crossbones',
                onSelect    = function()
                    tryNpcMission()
                end,
            }
        end

        -- Serviços / Loja de Bancada
        if cap.buyBench then
            options[#options + 1] = {
                title       = L('broker_menu_services'),
                description = L('broker_menu_services_desc'),
                icon        = 'fa-solid fa-toolbox',
                onSelect    = function()
                    tryNpcBuy('bench')
                end,
            }
        end

        -- Meu Perfil
        if cap.status then
            options[#options + 1] = {
                title       = L('broker_menu_profile'),
                description = L('broker_menu_profile_desc'),
                icon        = 'fa-solid fa-id-card',
                onSelect    = function()
                    openBrokerProfileMenu(ctx)
                end,
            }
        end

        -- Encomenda Especial (Legacy Order)
        if cap.legacyOrder then
            options[#options + 1] = {
                title       = L('broker_menu_legacy_order'),
                description = L('broker_menu_legacy_order_desc'),
                icon        = 'fa-solid fa-clipboard-list',
                onSelect    = function()
                    openBrokerLegacyOrderMenu(ctx)
                end,
            }
        end

        -- Entregar Veículo Inteiro (Trust 4)
        if cap.deliverCar then
            options[#options + 1] = {
                title       = L('broker_menu_deliver_car'),
                description = L('broker_menu_deliver_car_desc'),
                icon        = 'fa-solid fa-car-burst',
                onSelect    = function()
                    deliverCar()
                end,
            }
        end
    end

    lib.registerContext({
        id      = 'vp_broker_main',
        title   = alias,
        options = options,
    })
    lib.showContext('vp_broker_main')
end

function openBrokerSellMenu(ctx)
    local cap = ctx and ctx.capabilities or {}
    local options = {}

    -- Vender peça física que está nos braços
    if cap.sellPart and VPChopCarryingPart and physicalPartKeys[VPChopCarryingPart.partKey] then
        local pKey = VPChopCarryingPart.partKey
        options[#options + 1] = {
            title       = L('fence_sell_part_label') .. ' (' .. (L('part_' .. pKey) or pKey) .. ')',
            description = L('fence_sell_price_dynamic'),
            icon        = 'fa-solid fa-hand-holding-dollar',
            onSelect    = function()
                sellCarriedPart()
                openBrokerMainMenu()
            end,
        }
    end

    if cap.sellItems then
        options[#options + 1] = {
            title       = L('fence_target_sell_items'),
            description = L('broker_menu_sell_desc'),
            icon        = 'fa-solid fa-boxes-stacked',
            onSelect    = function()
                openSellMenu()
            end,
        }
    end

    if cap.sellTyres then
        options[#options + 1] = {
            title       = L('fence_target_sell_tyres'),
            description = 'Truck / Inventário',
            icon        = 'fa-solid fa-circle-dot',
            onSelect    = function()
                sellTyres()
            end,
        }
    end

    options[#options + 1] = {
        title    = 'Voltar',
        icon     = 'fa-solid fa-arrow-left',
        onSelect = function()
            openBrokerMainMenu()
        end,
    }

    lib.registerContext({
        id      = 'vp_broker_sell',
        title   = L('broker_menu_sell'),
        menu    = 'vp_broker_main',
        options = options,
    })
    lib.showContext('vp_broker_sell')
end

function openBrokerContractsMenu()
    local ok, res = pcall(lib.callback.await, 'vp_chopshop:broker:getContracts', false)
    if not ok or not res or not res.ok then
        VPChopNotify(VPChopLocaleErr(res and res.err) or L('notify_generic_error'), 'error')
        return
    end

    local contracts = res.contracts or {}
    local globals = contracts.global or {}
    local personals = contracts.personal or {}
    local serverNow = os.time()

    local options = {}

    -- ─── SEÇÃO: ALTA PROCURA GLOBAL ───
    options[#options + 1] = {
        title    = '─── ' .. L('broker_contracts_global_title') .. ' ───',
        readOnly = true,
        icon     = 'fa-solid fa-globe',
    }

    if #globals == 0 then
        options[#options + 1] = {
            title    = L('broker_contract_no_contracts'),
            readOnly = true,
        }
    else
        for _, c in ipairs(globals) do
            local remSec = math.max(0, (c.expiresAt or 0) - serverNow)
            local mins = math.floor(remSec / 60)
            local targetName = L('part_' .. tostring(c.targetKey))
            if targetName == 'part_' .. tostring(c.targetKey) then targetName = tostring(c.targetKey) end

            local meta = {
                { label = 'Restante', value = string.format('%d / %d', c.remaining or 0, c.quantity or 0) },
                { label = 'Recompensa', value = string.format('%.2fx', c.rewardMult or 1.0) .. (c.bonusCash and c.bonusCash > 0 and (' +$' .. c.bonusCash) or '') },
                { label = 'Tempo', value = mins .. ' min' },
            }

            local canFulfill = VPChopCarryingPart and VPChopCarryingPart.entitlementId
            options[#options + 1] = {
                title       = targetName,
                description = string.format('Tipo: %s | Qtd: %d/%d', c.contractType or 'part', c.remaining or 0, c.quantity or 0),
                icon        = 'fa-solid fa-fire',
                metadata    = meta,
                onSelect    = function()
                    if canFulfill then
                        local entId = VPChopCarryingPart.entitlementId
                        local fOk, fRes = pcall(lib.callback.await, 'vp_chopshop:broker:fulfillContract', false, c.id, entId)
                        if fOk and fRes and fRes.ok then
                            VPChopDropCarryPart()
                            lib.notify({
                                description = L('broker_contract_fulfilled_notify', fRes.payout or 0, fRes.bonus or 0),
                                type        = 'success',
                                duration    = 7000,
                            })
                        else
                            if fRes and fRes.terminalConsumed then VPChopDropCarryPart() end
                            VPChopNotify(VPChopLocaleErr(fRes and fRes.err) or L('notify_generic_error'), 'error')
                        end
                        openBrokerContractsMenu()
                    else
                        lib.notify({ description = 'Carregue uma peça compatível para entregar nesta alta procura.', type = 'inform' })
                    end
                end,
            }
        end
    end

    -- ─── SEÇÃO: CONTRATOS PESSOAIS ───
    options[#options + 1] = {
        title    = '─── ' .. L('broker_contracts_personal_title') .. ' ───',
        readOnly = true,
        icon     = 'fa-solid fa-user-tag',
    }

    if #personals == 0 then
        options[#options + 1] = {
            title    = L('broker_contract_no_contracts'),
            readOnly = true,
        }
    else
        for _, c in ipairs(personals) do
            local remSec = math.max(0, (c.expiresAt or 0) - serverNow)
            local mins = math.floor(remSec / 60)
            local targetName = L('part_' .. tostring(c.targetKey))
            if targetName == 'part_' .. tostring(c.targetKey) then targetName = tostring(c.targetKey) end

            local isAccepted = (c.state == 'ACCEPTED')
            local stateBadge = isAccepted and (' [' .. L('broker_contract_accepted_badge') .. ']') or ' [Disponível]'

            local meta = {
                { label = 'Status', value = isAccepted and 'Em Andamento' or 'Aguardando Aceite' },
                { label = 'Restante', value = string.format('%d / %d', c.remaining or 0, c.quantity or 0) },
                { label = 'Multiplicador', value = string.format('%.2fx', c.rewardMult or 1.0) .. (c.bonusCash and c.bonusCash > 0 and (' +$' .. c.bonusCash) or '') },
                { label = 'Tempo', value = mins .. ' min' },
            }

            options[#options + 1] = {
                title       = targetName .. stateBadge,
                description = isAccepted and 'Clique para entregar peça carregada' or 'Clique para aceitar o contrato',
                icon        = isAccepted and 'fa-solid fa-circle-check' or 'fa-solid fa-handshake-simple',
                metadata    = meta,
                onSelect    = function()
                    if not isAccepted then
                        -- Aceitar contrato
                        local aOk, aRes = pcall(lib.callback.await, 'vp_chopshop:broker:acceptContract', false, c.id)
                        if aOk and aRes and aRes.ok then
                            lib.notify({ description = L('broker_contract_accepted_notify'), type = 'success', duration = 6000 })
                        else
                            VPChopNotify(VPChopLocaleErr(aRes and aRes.err) or L('notify_generic_error'), 'error')
                        end
                        openBrokerContractsMenu()
                    else
                        -- Entregar peça para o contrato aceito
                        if VPChopCarryingPart and VPChopCarryingPart.entitlementId then
                            local entId = VPChopCarryingPart.entitlementId
                            local fOk, fRes = pcall(lib.callback.await, 'vp_chopshop:broker:fulfillContract', false, c.id, entId)
                            if fOk and fRes and fRes.ok then
                                VPChopDropCarryPart()
                                lib.notify({
                                    description = L('broker_contract_fulfilled_notify', fRes.payout or 0, fRes.bonus or 0),
                                    type        = 'success',
                                    duration    = 7000,
                                })
                            else
                                if fRes and fRes.terminalConsumed then VPChopDropCarryPart() end
                                VPChopNotify(VPChopLocaleErr(fRes and fRes.err) or L('notify_generic_error'), 'error')
                            end
                            openBrokerContractsMenu()
                        else
                            lib.notify({ description = 'Carregue uma peça compatível nos braços para entregar.', type = 'inform' })
                        end
                    end
                end,
            }
        end
    end

    options[#options + 1] = {
        title    = 'Voltar',
        icon     = 'fa-solid fa-arrow-left',
        onSelect = function()
            openBrokerMainMenu()
        end,
    }

    lib.registerContext({
        id      = 'vp_broker_contracts',
        title   = L('broker_menu_contracts'),
        menu    = 'vp_broker_main',
        options = options,
    })
    lib.showContext('vp_broker_contracts')
end

function openBrokerProfileMenu(ctx)
    local tLvl = ctx and ctx.trust and ctx.trust.level or 0
    local prog = ctx and ctx.progression or {}

    lib.registerContext({
        id      = 'vp_broker_profile',
        title   = L('broker_menu_profile'),
        menu    = 'vp_broker_main',
        options = {
            {
                title    = L('fence_status_profile'),
                readOnly = true,
                metadata = {
                    { label = 'Reputação / Trust', value = L('fence_trust_level_' .. tostring(tLvl)) .. ' (Nível ' .. tLvl .. '/4)' },
                    { label = L('fence_tier_label'), value = L('tier_label_' .. (prog.tier or 1)) },
                    { label = L('fence_xp_label'),   value = (prog.xp or 0) .. (prog.nextXp and ' / ' .. prog.nextXp or ' (máx)') },
                    { label = L('fence_chops_label'),value = tostring(prog.totalChops or 0) },
                },
            },
            {
                title    = 'Voltar',
                icon     = 'fa-solid fa-arrow-left',
                onSelect = function()
                    openBrokerMainMenu()
                end,
            }
        }
    })
    lib.showContext('vp_broker_profile')
end

function openBrokerLegacyOrderMenu(ctx)
    lib.registerContext({
        id      = 'vp_broker_legacy_order',
        title   = L('broker_menu_legacy_order'),
        menu    = 'vp_broker_main',
        options = {
            {
                title       = L('fence_target_order'),
                description = 'Ver detalhes dos itens solicitados e prazo',
                icon        = 'fa-solid fa-clipboard-list',
                onSelect    = function()
                    showOrder()
                end,
            },
            {
                title       = L('fence_target_fulfill'),
                description = 'Entregar itens do inventário para concluir a encomenda',
                icon        = 'fa-solid fa-box-open',
                onSelect    = function()
                    fulfillOrder()
                end,
            },
            {
                title    = 'Voltar',
                icon     = 'fa-solid fa-arrow-left',
                onSelect = function()
                    openBrokerMainMenu()
                end,
            }
        }
    })
    lib.showContext('vp_broker_legacy_order')
end

-- ─── Menus de interação ───────────────────────────────────────────────────────

function openSellMenu()
    local sellable = {}
    local prices   = Config.Fence and Config.Fence.BasePrices or {}
    local isBrokerEnabled = (Config.Broker and Config.Broker.Enable ~= false)
    local itemMap  = (Config.Broker and Config.Broker.Integration and Config.Broker.Integration.ItemToCommodity) or {}

    for item, _ in pairs(prices) do
        local count = exports.ox_inventory:Search('count', item)
        if count and count > 0 then
            local isDynamic = isBrokerEnabled and (itemMap[item] ~= nil)
            sellable[#sellable+1] = { name=item, amount=count, unitPrice=prices[item], isDynamic=isDynamic }
        end
    end
    if #sellable == 0 then
        lib.notify({ description=L('fence_nothing_to_sell'), type='error' }); return
    end
    -- Montar context menu com todos os itens vendáveis
    local opts = {}
    for _, s in ipairs(sellable) do
        local priceLabel = s.isDynamic and (L('fence_sell_price_dynamic') or 'Preço variável de mercado') or ('$'..s.unitPrice..' un.')
        opts[#opts+1] = {
            title    = s.name .. ' ×' .. s.amount,
            metadata = {{ label=L('fence_sell_price_label'), value=priceLabel }},
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
