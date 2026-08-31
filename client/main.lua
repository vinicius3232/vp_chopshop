-- [FIX L-4] Forward-declarations obrigatórias: o handler onResourceStop (abaixo) é uma closure
-- que só pode capturar upvalues JÁ EM SCOPE no momento da sua definição (Lua 5.4).
-- Sem estas declarações, o handler acederia às versões globais (_G.xxx = nil).
local AdvChopState   = {}
local JackstandData  = {}
local destroyToolProp           -- função definida mais abaixo; atribuída antes do 1.º uso
local _toolProp      = nil      -- prop handle; partilhado com spawnToolProp / destroyToolProp

local function applyWorld(payload)
    if type(payload) ~= 'table' then return end

    local benchIds = {}
    for _, bench in ipairs(payload.benches or {}) do
        benchIds[bench.id] = true
        VPChopUpsertBench(bench)
    end
    for id in pairs(BenchEntities) do
        if not benchIds[id] then
            VPChopRemoveBench(id)
        end
    end

    local welderIds = {}
    for _, w in ipairs(payload.welders or {}) do
        welderIds[w.id] = true
        VPChopUpsertWelder(w)
    end
    for id in pairs(WelderEntities or {}) do
        if not welderIds[id] then VPChopRemoveWelder(id) end
    end
end

RegisterNetEvent('vp_chopshop:syncWorld', function(payload)
    CreateThread(function() applyWorld(payload) end)
end)

RegisterNetEvent('vp_chopshop:addBench', function(data)
    if type(data) ~= 'table' or not data.id then return end
    CreateThread(function() VPChopUpsertBench(data) end)
end)

RegisterNetEvent('vp_chopshop:removeBench', function(id)
    id = tonumber(id)
    if not id then return end
    VPChopRemoveBench(id)
end)

RegisterNetEvent('vp_chopshop:addWelder', function(data)
    if type(data) ~= 'table' or not data.id then return end
    CreateThread(function() VPChopUpsertWelder(data) end)
end)

RegisterNetEvent('vp_chopshop:removeWelder', function(id)
    id = tonumber(id)
    if not id then return end
    VPChopRemoveWelder(id)
end)

RegisterNetEvent('vp_chopshop:client:ambushWarn', function(kind)
    local k = tostring(kind or '')
    local msg = L('notify_ambush_' .. k)
    if msg == ('notify_ambush_' .. k) then
        msg = L('notify_ambush_generic')
    end
    VPChopNotify(msg, 'error', 7000)
end)

RegisterNetEvent('vp_chopshop:client:breakPart', function(netId, partKey)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) then return end
    local def = VPChopPartRegistry.get(partKey)
    if not def or def.gtaIndex == nil then return end
    if def.gtaClass == 'door' then
        SetVehicleDoorBroken(veh, def.gtaIndex, true)
    elseif def.gtaClass == 'tyre' then
        -- Burst index (0,1,4,5) → sequential wheel index (0,1,2,3) para SetVehicleWheelXOffset
        local seqMap = { [0]=0, [1]=1, [4]=2, [5]=3 }
        local seqIdx = seqMap[def.gtaIndex]
        if seqIdx ~= nil then SetVehicleWheelXOffset(veh, seqIdx, 9999999.0) end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(BenchEntities) do
        VPChopRemoveBench(id)
    end
    for id in pairs(WelderEntities or {}) do
        VPChopRemoveWelder(id)
    end
    -- [FIX W-07] Props de jackstand (imp_prop_axel_stand_01a) criados em JackstandData
    -- precisam ser deletados explicitamente — caso contrário ficam como entidades orphan
    -- no mundo mesmo após o resource parar.
    lib.hideTextUI()  -- garante que TextUI de pneu não fique presa
    for veh, data in pairs(JackstandData) do
        if data._stopTyreThread then data._stopTyreThread() end
        if data.props then
            for _, prop in ipairs(data.props) do
                if DoesEntityExist(prop) then DeleteEntity(prop) end
            end
        end
        if DoesEntityExist(veh) then
            FreezeEntityPosition(veh, false)
        end
    end
    -- Limpar tabelas de estado — libera referências a network IDs obsoletos
    JackstandData  = {}
    AdvChopState   = {}
    -- Destruir prop da ferramenta de desmanche (se ativo durante o chop)
    destroyToolProp()
end)

CreateThread(function()
    while GetResourceState('ox_lib') ~= 'started' do Wait(200) end
    local tries = 0
    while GetResourceState('ox_target') ~= 'started' and tries < 120 do
        Wait(250)
        tries = tries + 1
    end
    if GetResourceState('ox_target') ~= 'started' then
        print('^1[vp_chopshop]^0 ' .. L('ox_target_missing'))
        return
    end

    local wOk, world = pcall(lib.callback.await, 'vp_chopshop:getWorld', false)
    if wOk and world then
        applyWorld(world)
    end
end)

-- ============================================================
-- CHOP UTILITIES (moved from lifts.lua after lift removal)
-- ============================================================

-- _toolProp e destroyToolProp são forward-declarados no topo do ficheiro.
-- As atribuições abaixo preenchem os upvalues capturados pelo onResourceStop.

local function getPlayerTool(requiredType)
    if not Config.Tools then return nil, nil end
    local bestName, bestCfg = nil, nil
    for tName, tCfg in pairs(Config.Tools) do
        local isDrill = (tName == 'mechanic_drill')
        local wantDrill = (requiredType == 'drill')
        if isDrill == wantDrill then
            local count = exports.ox_inventory:Search('count', tName) or 0
            if count > 0 then
                bestName, bestCfg = tName, tCfg
                break
            end
        end
    end
    return bestName, bestCfg
end

function VPChopTriggerDispatch(veh)
    if not Config.Dispatch or not Config.Dispatch.Enable then return end
    local sys = Config.Dispatch.System
    if sys == 'ps-dispatch' then
        pcall(function() exports['ps-dispatch']:SuspiciousActivity() end)
    elseif sys == 'cd_dispatch' then
        pcall(function()
            local data = exports['cd_dispatch']:GetPlayerInfo()
            -- [L2 FIX] Use vehicle coords when available — player may have fled the scene.
            local pos = (veh and DoesEntityExist(veh)) and GetEntityCoords(veh) or data.coords
            TriggerServerEvent('cd_dispatch:AddNotification', {
                job_table = {'police', 'sheriff', 'bcso'},
                coords = pos,
                title = '10-90 - Desmanche Ilegal',
                message = 'Notícia de desmanche de veículo em andamento.',
                flash = 0, unique_id = data.unique_id, sound = 1,
                blip = { sprite = 530, scale = 1.0, color = 1, flashes = false, text = '911 - Desmanche', time = 5, radius = 0 }
            })
        end)
    end
end

function VPChopCheckAlarmAndDispatch(veh, toolCfg)
    -- Alarme agora gerenciado pelo servidor via Config.Alarm (probabilidade por classe).
    -- client/alarm.lua escuta vp_chopshop:client:alarmTriggered.
    if toolCfg and toolCfg.dispatchChance then
        if math.random() <= toolCfg.dispatchChance then
            VPChopTriggerDispatch(veh)
        end
    end
end

local function spawnToolProp(propCfg)
    local cfg = propCfg
    if not cfg then
        local _, tCfg = getPlayerTool()
        cfg = tCfg and tCfg.HandProp
    end
    if not cfg or not cfg.model then return end

    local model = cfg.model
    -- Fail-safe: validação de cdimage / validade do model
    if type(IsModelInCdimage) == 'function' and not IsModelInCdimage(model) then
        if model == 'prop_tool_screwflt01' then
            model = 'prop_tool_drill'
        elseif model == 'v_ind_cs_powersaw' then
            model = 'prop_weld_torch'
        end
        if not IsModelInCdimage(model) then
            return -- Segue a operação sem prop sem travar o requestModel
        end
    end

    local hash = type(model) == 'number' and model or GetHashKey(model)
    RequestModel(hash)
    local t0 = GetGameTimer()
    while not HasModelLoaded(hash) and (GetGameTimer() - t0 < 2000) do
        Wait(20)
    end
    if not HasModelLoaded(hash) then return end

    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local prop = CreateObject(hash, pos.x, pos.y, pos.z, true, true, false)
    SetEntityAsMissionEntity(prop, true, true)
    SetModelAsNoLongerNeeded(hash)
    if not prop or prop == 0 then return end

    local handBone = GetPedBoneIndex(ped, 28422)
    local off = cfg.offset   or { 0.05, 0.02, 0.0 }
    local rot = cfg.rotation or { 20, 0, -50 }
    AttachEntityToEntity(prop, ped, handBone,
        off[1], off[2], off[3], rot[1], rot[2], rot[3],
        true, true, false, true, 1, true)
    _toolProp = prop
end

-- Atribuição ao upvalue forward-declarado (não 'local function' — criaria um novo local)
destroyToolProp = function()
    if _toolProp and DoesEntityExist(_toolProp) then
        DetachEntity(_toolProp, true, true)
        DeleteEntity(_toolProp)
    end
    _toolProp = nil
end

local function spawnAndAttachPart(partKey, veh)
    local category = Config.PartPropCategory and Config.PartPropCategory[partKey]
    if not category then return nil end
    local cfg = Config.PartProps and Config.PartProps[category]
    if not cfg or not cfg.model then return nil end
    local boneIdx = GetEntityBoneIndexByName(veh, partKey)
    local spawnPos
    if boneIdx and boneIdx ~= -1 then
        spawnPos = GetWorldPositionOfEntityBone(veh, boneIdx)
    else
        spawnPos = GetEntityCoords(veh)
    end
    local ok = pcall(lib.requestModel, cfg.model, 5000)
    if not ok then return nil end
    local prop = CreateObject(cfg.model, spawnPos.x, spawnPos.y, spawnPos.z, true, true, false)
    SetEntityAsMissionEntity(prop, true, true)
    SetModelAsNoLongerNeeded(cfg.model)
    if not prop or prop == 0 then return nil end
    local ped = PlayerPedId()
    local handBone = GetPedBoneIndex(ped, 28422)
    local off = cfg.offset   or { 0.1, 0.05, 0.0 }
    local rot = cfg.rotation or { 0, 0, 0 }
    AttachEntityToEntity(prop, ped, handBone,
        off[1], off[2], off[3], rot[1], rot[2], rot[3],
        true, true, false, true, 1, true)
    return prop
end

local function getPartAnimAndSound(partKey)
    local cfg  = Config.ChopAnimations or {}
    local defaultAnim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 }
    if partKey == 'bonnet' or partKey == 'boot' then
        return cfg.grinder or defaultAnim, 'grinder'
    end
    if VPChopPartGtaClass(partKey) == 'tyre' then
        return cfg.pneumatic or defaultAnim, 'pneumatic'
    end
    return cfg.door or defaultAnim, 'grinder'
end

local function playChopSound(soundType)
    if not (Config.ChopSounds and Config.ChopSounds.Enable) then return end
    local soundCfg = Config.ChopSounds[soundType]
    if not soundCfg then return end
    if GetResourceState('xsound') ~= 'started' then return end
    local url = ('https://cfx-nui-%s/sounds/%s'):format(GetCurrentResourceName(), soundCfg.file)
    local id  = 'vp_chopshop_snd_' .. GetGameTimer()
    pcall(function() exports.xsound:PlayUrl(id, url, tonumber(soundCfg.volume) or 0.4, false) end)
end

local function tryChopSkillCheck()
    local sc = Config.ChopSkillCheck
    if not sc then return true end
    local diffs, keys
    if sc == true then
        diffs = { 'easy', 'medium' }
        keys = { 'e', 'e' }
    elseif type(sc) == 'table' then
        diffs = sc.difficulties or { 'easy', 'medium' }
        keys = sc.keys
        if type(keys) ~= 'table' or #keys < 1 then
            keys = {}
            for i = 1, #diffs do keys[i] = 'e' end
        end
    else
        return true
    end
    local ok = lib.skillCheck(diffs, keys)
    if not ok then VPChopNotify(L('notify_skill_fail'), 'error') end
    return ok
end

local function trimPlate(plate)
    return (plate:gsub('^%s*(.-)%s*$', '%1'))
end

local function hasVehicleKeys(vehicle)
    if not Config.RequireVehicleKeys then return true end

    -- Configurable vehicle-keys bridge (recommended for ESX servers).
    local vk = Config.VehicleKeys
    if vk and vk.Enable and type(vk.Resource) == 'string' and vk.Resource ~= '' and GetResourceState(vk.Resource) == 'started' then
        local ok, res
        if (vk.Mode or 'plate') == 'entity' then
            ok, res = pcall(function()
                return exports[vk.Resource][vk.Export](vehicle)
            end)
        else
            local plate = trimPlate(GetVehicleNumberPlateText(vehicle))
            ok, res = pcall(function()
                return exports[vk.Resource][vk.Export](plate)
            end)
        end
        if ok and type(res) == 'boolean' then
            return res
        end
        -- If misconfigured, fall back to embedded integrations below.
    end

    -- Best-effort ESX integrations (non-breaking; only used if resource exists).
    if GetResourceState('esx_vehiclelock') == 'started' then
        local plate = trimPlate(GetVehicleNumberPlateText(vehicle))
        local ok, res = pcall(function()
            return exports.esx_vehiclelock.hasKey and exports.esx_vehiclelock:hasKey(plate)
        end)
        if ok and type(res) == 'boolean' then return res end

        ok, res = pcall(function()
            return exports.esx_vehiclelock.HasKey and exports.esx_vehiclelock:HasKey(plate)
        end)
        if ok and type(res) == 'boolean' then return res end
    end

    return true
end

local function isPartMissing(vehicle, def)
    if def.gtaClass == 'door' then
        return IsVehicleDoorDamaged(vehicle, def.gtaIndex)
    end
    return IsVehicleTyreBurst(vehicle, def.gtaIndex, false)
end

local function openJackstandChopMenu(veh)
    local ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) ~= 0 then
        VPChopNotify(L('notify_exit_vehicle'), 'error')
        return
    end
    if Config.RequireVehicleKeys and not hasVehicleKeys(veh) then
        VPChopNotify(L('notify_no_keys'), 'error')
        return
    end
    local tName, tCfg = getPlayerTool()
    if not tName then
        VPChopNotify(L('notify_no_saw'), 'error')
        return
    end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local options = {}
    for _, partKey in ipairs(VPChopPartRegistry.order) do
        local def = VPChopPartRegistry.get(partKey)
        -- só as 10 peças GTA-native (gtaIndex nil = adv_engine/adv_carcass sintéticas)
        local native = def and def.gtaIndex ~= nil
        -- Quando advanced chop está activo, portas/capô/porta-malas são exclusivas da Fase 2.
        local advOwns = native and Config.AdvancedChop and Config.AdvancedChop.Enable and def.gtaClass == 'door'
        -- Pneus são tratados pelo sistema de proximidade (wheel_theft pattern) — não aparecem aqui.
        if native and not isPartMissing(veh, def) and not advOwns and def.gtaClass ~= 'tyre' then
            local partLabel = L(def.labelKey)
            options[#options + 1] = {
                title = partLabel,
                icon  = 'wrench',
                onSelect = function()
                    if not tryChopSkillCheck() then return end
                    -- [AUDIT M2] Emboscada agora é disparada server-side no callback chopPart.
                    local animCfg, soundType = getPartAnimAndSound(partKey)
                    playChopSound(soundType)
                    spawnToolProp(tCfg and tCfg.HandProp)
                    VPChopCheckAlarmAndDispatch(veh, tCfg)
                    local ok = lib.progressBar({
                        duration     = math.floor(Config.ChopProgressMs * (tCfg and tCfg.speedMult or 1.0)),
                        label        = L('progress_dismantling_fmt', partLabel),
                        useWhileDead = false,
                        canCancel    = true,
                        disable      = { move = true, car = true, combat = true },
                        anim         = { dict = animCfg.dict, clip = animCfg.clip, flag = animCfg.flag or 49 },
                    })
                    destroyToolProp()
                    if not ok then return end
                    local cbOk2, res = pcall(lib.callback.await, 'vp_chopshop:chopPart', false, netId, partKey)
                    if not cbOk2 then res = nil end
                    if res and res.ok then
                        VPChopDropCarryPart()
                        local propHandle = spawnAndAttachPart(partKey, veh)
                        VPChopCarryingPart = { partKey = partKey, propHandle = propHandle }
                        if Config.PartPropCategory and Config.PartPropCategory[partKey] == 'wheel'
                        and Config.TyreSelling and Config.TyreSelling.Enable then
                            VPChopNotify(L('notify_carry_to_bench_or_truck'), 'inform')
                        else
                            VPChopNotify(L('notify_carry_to_bench'), 'inform')
                        end
                    elseif res and res.err == 'cooldown' and res.wait then
                        VPChopNotify(L('notify_cooldown_fmt', res.wait), 'error')
                    else
                        VPChopNotify(
                            (res and res.err) and L('notify_chop_failed_fmt', VPChopLocaleErr(res.err)) or L('notify_generic_error'),
                            'error'
                        )
                    end
                end,
            }
        end
    end
    if #options < 1 then
        VPChopNotify(L('notify_nothing_to_chop'), 'inform')
        return
    end
    lib.registerContext({
        id    = 'vp_chopshop_jackstand_chop_' .. tostring(veh),
        title = L('menu_chop_title'),
        options = options,
    })
    lib.showContext('vp_chopshop_jackstand_chop_' .. tostring(veh))
end

-- ============================================================
-- JACKSTAND SYSTEM (inline — avoids FiveM cache issues)
-- ============================================================

JackstandData = {}   -- forward-declared no topo; re-inicializa sem criar novo local
local JackstandBusy = false

local function attachWheelPropToPed(prop)
    if not prop or not DoesEntityExist(prop) then return false end
    local ped = PlayerPedId()
    local bone = GetPedBoneIndex(ped, 4089)
    AttachEntityToEntity(prop, ped, bone,
        0.1, 0.08, 0.25,
        190.0, 0.0, 0.0,
        true, false, false, false, 2, true)

    RequestAnimDict('anim@heists@box_carry@')
    local t0 = GetGameTimer()
    while not HasAnimDictLoaded('anim@heists@box_carry@') and (GetGameTimer() - t0 < 2000) do
        Wait(50)
    end
    if HasAnimDictLoaded('anim@heists@box_carry@') then
        TaskPlayAnim(ped, 'anim@heists@box_carry@', 'idle', 5.0, 1.0, -1, 49, 0.0, false, false, false)
    end
    return true
end

local function registerGroundTyreTarget(groundProp, groundEntitlementId)
    if not groundProp or not DoesEntityExist(groundProp) then return end

    local max = (Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4
    local targetName = 'vp_ground_tyre_' .. tostring(groundProp)

    exports.ox_target:addLocalEntity(groundProp, {
        {
            name        = targetName .. '_pick',
            label       = L('fence_tyre_pick_label'),
            icon        = 'fa-solid fa-hand',
            distance    = 2.0,
            canInteract = function()
                return not VPChopCarryingPart
            end,
            onSelect    = function()
                if VPChopCarryingPart then return end
                exports.ox_target:removeLocalEntity(groundProp)
                FreezeEntityPosition(groundProp, false)

                -- Animação rápida de pegar
                local ped = PlayerPedId()
                RequestAnimDict('anim@mp_snowball')
                local t0 = GetGameTimer()
                while not HasAnimDictLoaded('anim@mp_snowball') and (GetGameTimer() - t0 < 1000) do
                    Wait(20)
                end
                if HasAnimDictLoaded('anim@mp_snowball') then
                    TaskPlayAnim(ped, 'anim@mp_snowball', 'pickup_snowball', 4.0, -4.0, 600, 0, 0.0, false, false, false)
                    Wait(500)
                end

                attachWheelPropToPed(groundProp)
                VPChopCarryingPart = {
                    partKey       = 'wheel_tyre',
                    propHandle    = groundProp,
                    isTyre        = true,
                    entitlementId = groundEntitlementId,
                }
                lib.showTextUI('[G] ' .. L('tyre_carry_textui') .. ' | [E] ' .. L('tyre_option_drop'), {
                    position = 'left-center',
                    icon     = 'circle-dot',
                })
            end,
        },
        {
            name        = targetName .. '_truck',
            label       = L('tyre_store_in_truck'),
            icon        = 'fa-solid fa-truck-pickup',
            distance    = 2.5,
            canInteract = function()
                return VPChopIsTruckNearby()
            end,
            onSelect    = function()
                local t = VPChopFindNearestTruck(5.0)
                if not t then VPChopNotify(L('tyre_no_truck_nearby'), 'error'); return end
                local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:tyre:loadToTruck', false,
                    NetworkGetNetworkIdFromEntity(t), groundEntitlementId)
                if not cbOk or not res or not res.ok then
                    VPChopNotify(VPChopTyreLoadErr(res and res.err), 'error')
                    return
                end
                exports.ox_target:removeLocalEntity(groundProp)
                DeleteEntity(groundProp)
                VPChopNotify(L('tyre_stored_fmt', res.count, res.max or max), 'success')
            end,
        },
    })
end

local function VPTyreSpawnWheelPropInHand(partKey)
    local modelName = 'prop_wheel_01'
    RequestModel(modelName)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(modelName) do
        if GetGameTimer() > deadline then return nil end
        Wait(100)
    end
    local ped  = PlayerPedId()
    local pos  = GetEntityCoords(ped)
    local prop = CreateObject(GetHashKey(modelName), pos.x, pos.y, pos.z, true, true, true)
    SetEntityAsMissionEntity(prop, true, true)
    SetModelAsNoLongerNeeded(modelName)
    if not prop or prop == 0 then return nil end

    attachWheelPropToPed(prop)
    return prop
end

local function spawnJackstandProps(veh)
    local modelName = 'imp_prop_axel_stand_01a'
    -- [PERF-02] Substituído Wait(0) por Wait(100): modelos carregam em 1-3 frames;
    -- polling a 60fps desperdiça CPU sem benefício visual. Wait(100) é idêntico ao
    -- padrão usado em VPTyreSpawnWheelPropInHand acima.
    RequestModel(modelName)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(modelName) do
        if GetGameTimer() > deadline then return {} end
        Wait(100)
    end
    local vehpos = GetEntityCoords(veh)
    local vmin, vmax = GetModelDimensions(GetEntityModel(veh))
    local hw = ((vmax.x - vmin.x) * 0.5) - ((vmax.x - vmin.x) / 3.3)
    local hl = ((vmax.y - vmin.y) * 0.5) - ((vmax.y - vmin.y) / 3.3)
    local zOff = 0.5
    local mHash = GetHashKey(modelName)
    local corners = {
        { -hw,  hl, -90.0 },
        {  hw,  hl, -90.0 },
        { -hw, -hl,  90.0 },
        {  hw, -hl,  90.0 },
    }
    local props = {}
    for i = 1, #corners do
        local c    = corners[i]
        local prop = CreateObject(mHash,
            vehpos.x + c[1], vehpos.y + c[2], vehpos.z - zOff,
            true, true, true)
        if prop and prop ~= 0 then
            AttachEntityToEntity(prop, veh, 0,
                c[1], c[2], -zOff, 0.0, 0.0, c[3],
                false, false, false, false, 0, true)
            local rot = GetEntityRotation(prop, 5)
            DetachEntity(prop, true, true)
            FreezeEntityPosition(prop, true)
            local coords = GetEntityCoords(prop)
            local gotZ, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 2.0, true)
            if gotZ and groundZ > 0 then
                SetEntityCoords(prop, coords.x, coords.y, groundZ, false, false, false, false)
            end
            PlaceObjectOnGroundProperly(prop)
            SetEntityRotation(prop, rot.x, rot.y, rot.z, 5, 0)
            SetEntityCollision(prop, false, true)
            props[#props + 1] = prop
        end
    end
    SetModelAsNoLongerNeeded(modelName)
    return props
end

local function attachJackstandsToCar(veh, props)
    for i = 1, #props do
        local prop = props[i]
        if DoesEntityExist(prop) then
            local wc     = GetEntityCoords(prop)
            local offset = GetOffsetFromEntityGivenWorldCoords(veh, wc.x, wc.y, wc.z)
            FreezeEntityPosition(prop, false)
            AttachEntityToEntity(prop, veh, 0,
                offset.x, offset.y, offset.z, 0.0, 0.0, 90.0,
                false, false, false, false, 0, true)
        end
    end
end

local function doLiftVehicle(veh)
    local liftH   = (Config.Jackstand and Config.Jackstand.LiftHeight) or 0.18
    local coords  = GetEntityCoords(veh)
    local origZ   = coords.z
    local targetZ = origZ + liftH
    FreezeEntityPosition(veh, true)
    CreateThread(function()
        local duration = 900.0
        local speed = liftH / duration
        while DoesEntityExist(veh) do
            local cur = GetEntityCoords(veh)
            if cur.z >= targetZ then break end
            local dt = GetFrameTime() * 1000.0
            local step = speed * dt
            local nz  = math.min(targetZ, cur.z + step)
            SetEntityCoordsNoOffset(veh, cur.x, cur.y, nz, true, true, true)
            Wait(33)  -- [AUDIT-FIX M6] 16→33ms: delta por GetFrameTime mantém duração/suavidade a ~30fps
        end
    end)
    return origZ
end

local function doLowerVehicle(veh, originalZ)
    local done = false
    CreateThread(function()
        local duration = 450.0
        local speed = ((Config.Jackstand and Config.Jackstand.LiftHeight) or 0.18) / duration
        while DoesEntityExist(veh) do
            local cur = GetEntityCoords(veh)
            if cur.z <= originalZ then
                FreezeEntityPosition(veh, false)
                done = true
                break
            end
            local dt = GetFrameTime() * 1000.0
            local step = speed * dt
            local nz  = math.max(originalZ, cur.z - step)
            SetEntityCoordsNoOffset(veh, cur.x, cur.y, nz, true, true, true)
            Wait(33)  -- [AUDIT-FIX M6] 16→33ms: idem doLiftVehicle
        end
        done = true
    end)
    local deadline = GetGameTimer() + 3000
    while not done and GetGameTimer() < deadline do Wait(50) end
end

-- ─── Desmanche Avançado (Fases 2-4) ─────────────────────────────────────────

-- AdvChopState declarado no topo do arquivo (antes do handler onResourceStop)

local function advIsChopped(netId, key)
    local st = AdvChopState[netId]
    return st and st[key] == true
end

local function advMarkChopped(netId, key)
    if not AdvChopState[netId] then AdvChopState[netId] = {} end
    AdvChopState[netId][key] = true
end

-- Verifica se há uma soldadora (WelderEntities) dentro do raio indicado
local function hasNearbyWelder(pos, radius)
    for _, ent in pairs(WelderEntities or {}) do
        if DoesEntityExist(ent) and #(GetEntityCoords(ent) - pos) <= radius then
            return true
        end
    end
    return false
end

-- ─── Bolt minigame (inline — evita problema de carregamento cross-file lua54) ──
-- Spawna parafusos 3D (bolt.ydr) na face da roda; jogador segura [E] para girar.
-- Fallback: lib.skillCheck se o modelo não carregar.
do
    local BOLT_MODEL = 'bolt'

    local function boltCfg()
        local m = Config.Jackstand and Config.Jackstand.Minigame
        return (m and m.Bolt3D) or {}
    end

    -- Converte coords do mundo para coords de tela (0..1). Usa a native do CFX;
    -- se indisponível, o pcall em volta do loop cai no fallback skillCheck.
    local function world2screen(x, y, z)
        local ok, on, sx, sy = pcall(GetScreenCoordFromWorldCoord, x, y, z)
        if not ok then return false, 0.0, 0.0 end
        return on, sx or 0.0, sy or 0.0
    end

    function VPChopBoltMinigameFallback()
        local jmg   = Config.Jackstand and Config.Jackstand.Minigame
        local diffs = (jmg and jmg.SkillCheckDifficulties) or { 'easy', 'medium', 'medium' }
        local keys  = (jmg and jmg.SkillCheckKeys)         or { 'e', 'e', 'e' }
        local passed = lib.skillCheck(diffs, keys)
        if not passed then VPChopNotify(L('tyremission_minigame_fail'), 'error') end
        return passed
    end

    -- ─── Núcleo genérico do minigame de parafusos ────────────────────────────
    -- Recebe os pontos (world) onde spawnar cada parafuso + parâmetros de câmera e
    -- giro. Serve tanto para a RODA (parafusos em círculo) quanto para a PLACA
    -- (parafusos nos cantos). Retorna: true = concluído · false = cancelar/timeout
    -- · 'fallback' = não conseguiu spawnar (modelo/pontos) → caller usa skillCheck.
    -- o = { points={vec3...}, outward=vec3, camPos=vec3, lookAt=vec3,
    --       baseRot={x,y,z}, needed, sens, hoverR, timeout, fov }
    local function runBoltSurface(o)
        if not o.points or #o.points == 0 then return 'fallback' end

        -- O modelo do parafuso (bolt.ydr) é OPCIONAL: só carrega se houver um archetype .ytyp
        -- válido — sem isso, RequestModel nunca completa. Então tentamos por pouco tempo e, se
        -- não der, rodamos em MODO MARCADOR (parafuso desenhado via DrawMarker, sem entidade).
        -- O minigame SEMPRE roda — nunca cai silenciosamente no skillCheck por falta de modelo.
        local boltHash = GetHashKey(BOLT_MODEL)
        local hasModel = false
        if IsModelValid(boltHash) then
            RequestModel(boltHash)
            local t0 = GetGameTimer()
            while not HasModelLoaded(boltHash) do
                if GetGameTimer() - t0 > 1500 then break end
                Wait(50)
            end
            hasModel = HasModelLoaded(boltHash)
        end

        local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            o.camPos.x, o.camPos.y, o.camPos.z, 0.0, 0.0, 0.0, o.fov or 45.0, false, 0)
        PointCamAtCoord(cam, o.lookAt.x, o.lookAt.y, o.lookAt.z)
        SetCamActive(cam, true)
        RenderScriptCams(true, true, 600, true, true)

        local br    = o.baseRot or { x = 0.0, y = 0.0, z = 0.0 }
        local bolts = {}
        for i = 1, #o.points do
            local p   = o.points[i]
            local obj = nil
            if hasModel then
                obj = CreateObject(boltHash, p.x, p.y, p.z, true, true, false)
                if obj and obj ~= 0 then
                    SetEntityCollision(obj, false, false)
                    SetEntityRotation(obj, br.x, br.y, br.z, 5, true)
                    FreezeEntityPosition(obj, true)
                else
                    obj = nil
                end
            end
            bolts[#bolts + 1] = { ent = obj, pos = p, deg = 0.0, done = false }
        end
        if hasModel then SetModelAsNoLongerNeeded(boltHash) end

        local needed  = o.needed  or 720.0
        local sens    = o.sens    or 900.0
        local hoverR  = o.hoverR  or 0.06
        local timeout = o.timeout or 30000
        local outward = o.outward or vector3(0.0, 0.0, 1.0)

        local ped = PlayerPedId()
        RequestAnimDict('mini@repair')
        t0 = GetGameTimer()
        while not HasAnimDictLoaded('mini@repair') do
            if GetGameTimer() - t0 > 2000 then break end
            Wait(10)
        end
        if HasAnimDictLoaded('mini@repair') then
            TaskPlayAnim(ped, 'mini@repair', 'fixing_a_player', 8.0, -1.0, -1, 49, 0.0, false, false, false)
        end

        lib.showTextUI(L('bolt_minigame_help'), { position = 'top-center', icon = 'wrench' })

        local remaining      = #bolts
        local startMs        = GetGameTimer()
        local prevCx, prevCy = GetControlNormal(0, 239), GetControlNormal(0, 240)
        local result         = nil  -- nil = a correr; true = concluído; false = cancelar/timeout; 'fallback' = geometria/câmera quebrada
        local unprojSince    = nil  -- ms desde que NENHUM parafuso projeta na tela (câmera/geometria off)

        local function cleanup()
            lib.hideTextUI()
            for _, b in ipairs(bolts) do
                if b.ent and DoesEntityExist(b.ent) then DeleteEntity(b.ent) end
            end
            ClearPedTasks(ped)
            RenderScriptCams(false, true, 400, true, true)
            DestroyCam(cam, false)
        end

        local ok = pcall(function()
            while result == nil do
                Wait(0)

                if GetGameTimer() - startMs > timeout then result = false; break end
                -- Cancelar: ESC (322) ou BACKSPACE (177)
                if IsControlJustReleased(0, 322) or IsControlJustReleased(0, 177) then
                    result = false; break
                end

                -- Cursor do mouse ativo; bloquear tiro/mira/câmera/movimento
                SetMouseCursorActiveThisFrame()
                DisableControlAction(0, 24, true)   -- attack (clique esquerdo)
                DisableControlAction(0, 25, true)   -- aim
                DisableControlAction(0, 1,  true)   -- look LR
                DisableControlAction(0, 2,  true)   -- look UD
                DisableControlAction(0, 30, true)   -- move LR
                DisableControlAction(0, 31, true)   -- move UD
                DisableControlAction(0, 22, true)   -- jump
                DisablePlayerFiring(ped, true)

                local cx      = GetControlNormal(0, 239)
                local cy      = GetControlNormal(0, 240)
                local holding = IsDisabledControlPressed(0, 24)

                -- 1ª passada: localizar o parafuso sob o cursor
                local hovered, bestDist = nil, hoverR
                local anyProjected = false
                for _, b in ipairs(bolts) do
                    if not b.done then
                        local on, sx, sy = world2screen(b.pos.x, b.pos.y, b.pos.z)
                        if on then
                            anyProjected = true
                            local dx, dy = sx - cx, sy - cy
                            local d = math.sqrt(dx * dx + dy * dy)
                            if d < bestDist then bestDist = d; hovered = b end
                        end
                    end
                end

                -- Se NENHUM parafuso ativo projeta na tela por >2.5 s, a câmera/geometria
                -- está errada (RC-FINDING-01). Degrada para o skillCheck em vez de travar
                -- o jogador num minigame invisível.
                if anyProjected then
                    unprojSince = nil
                else
                    unprojSince = unprojSince or GetGameTimer()
                    if GetGameTimer() - unprojSince > 2500 then result = 'fallback'; break end
                end

                -- 2ª passada: marcador. Cor vai de vermelho (0%) → verde (100%) conforme rosqueia;
                -- o que está sob o cursor fica mais opaco. Dá feedback de giro mesmo sem o modelo 3D.
                for _, b in ipairs(bolts) do
                    if not b.done then
                        local prog = math.min(1.0, b.deg / needed)
                        local mr = math.floor(230 * (1.0 - prog) + 60 * prog)
                        local mg = math.floor(60 * (1.0 - prog) + 220 * prog)
                        local a  = (b == hovered) and 230 or 120
                        DrawMarker(0, b.pos.x, b.pos.y, b.pos.z + 0.12, 0.0,0.0,0.0, 180.0,0.0,0.0,
                            0.08, 0.08, 0.10, mr, mg, 70, a,
                            true, false, 2, false, nil, nil, false)
                    end
                end

                if hovered and holding then
                    local dcx, dcy = cx - prevCx, cy - prevCy
                    local move = math.sqrt(dcx * dcx + dcy * dcy)
                    if move > 0.08 then move = 0.08 end  -- clamp: salto de cursor (1º frame / borda de tela) não conclui parafuso de uma vez
                    if move > 0.0 then
                        local turn = move * sens
                        hovered.deg = hovered.deg + turn
                        if hovered.ent and DoesEntityExist(hovered.ent) then
                            local r = GetEntityRotation(hovered.ent, 5)
                            SetEntityRotation(hovered.ent, r.x, r.y, r.z + turn, 5, true)
                        end
                        if hovered.deg >= needed then
                            hovered.done = true
                            remaining = remaining - 1
                            if hovered.ent and DoesEntityExist(hovered.ent) then
                                FreezeEntityPosition(hovered.ent, false)
                                SetEntityCollision(hovered.ent, true, true)
                                SetEntityVelocity(hovered.ent,
                                    outward.x * 0.6, outward.y * 0.6, math.random() * 0.3 + 0.2)
                                SetEntityAsNoLongerNeeded(hovered.ent)
                                hovered.ent = nil
                            end
                            PlaySoundFrontend(-1, 'Pin_Good', 'DLC_HEIST_FLEECA_SOUNDSET', true)
                            if remaining <= 0 then result = true end
                        end
                    end
                end

                prevCx, prevCy = cx, cy
            end
        end)

        cleanup()
        if not ok then return 'fallback' end
        if result == 'fallback' then return 'fallback' end
        return result == true
    end

    -- ─── Ponta RODA: parafusos em círculo na face da roda ─────────────────────
    function VPChopBoltMinigame(vehicle, wheelIndex)
        local boneNames = { 'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr' }
        local boneKey   = boneNames[(wheelIndex or 0) + 1] or 'wheel_lf'
        if VPChopDismantleMinigame and VPChopDismantleMinigame.Start then
            return VPChopDismantleMinigame.Start(vehicle, 'wheel', { boneKey = boneKey })
        end
        return VPChopMinigameFallback(vehicle, boneKey, 'minigame_core_missing')
    end

    -- ─── Ponta PLACA: parafusos nos cantos da placa (frente OU traseira) ──────
    local function plateCfg()
        local p = Config.Plates
        return (p and p.Bolt3D) or {}
    end

    local function VPChopPlateBoltFallback()
        local sc = Config.Plates and Config.Plates.SkillCheck
        if not sc then return true end
        local passed = lib.skillCheck(sc.difficulties, sc.keys)
        if not passed then VPChopNotify(L('notify_skill_fail'), 'error') end
        return passed
    end

    --- @param vehicle integer
    --- @param isRear boolean|nil  true = placa traseira (default) · false = dianteira.
    ---   O caller (client/plates.lua) resolve a face pela posição do jogador. É UMA
    ---   placa só — frente/traseira muda apenas o enquadramento (câmera, normal da
    ---   face, offset Y e heading base). O servidor é INALTERADO.
    function VPChopPlateBoltMinigame(vehicle, isRear)
        if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
        if isRear == nil then isRear = true end
        local c = plateCfg()

        local vmin, vmax = GetModelDimensions(GetEntityModel(vehicle))
        local fwd        = GetEntityForwardVector(vehicle)
        local up         = vector3(0.0, 0.0, 1.0)
        local rightV     = vector3(fwd.y, -fwd.x, 0.0)
        local rlen       = #rightV
        if rlen > 0.0 then rightV = rightV / rlen end
        local vehHeading = GetEntityHeading(vehicle)

        -- Centro aproximado da placa na face escolhida. Geometria ainda placeholder —
        -- calibrar in-game via ZFrac / YOffset{Front,Rear} (Config.Plates.Bolt3D).
        local zFrac  = tonumber(c.PlateZFrac) or 0.30
        local zPlate = vmin.z + (vmax.z - vmin.z) * zFrac
        local yOff   = isRear
            and (tonumber(c.PlateYOffsetRear)  or tonumber(c.PlateYOffset) or 0.02)
            or  (tonumber(c.PlateYOffsetFront) or tonumber(c.PlateYOffset) or 0.02)
        local yPlate = isRear and (vmin.y - yOff) or (vmax.y + yOff)
        local center = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, yPlate, zPlate)

        -- Normal da face escolhida (aponta para fora do carro = lado da câmera).
        local outward = isRear and vector3(-fwd.x, -fwd.y, 0.0) or vector3(fwd.x, fwd.y, 0.0)
        local olen = #outward
        if olen > 0.0 then outward = outward / olen end

        -- Disposição: 2 parafusos (topo) ou 4 (cantos do retângulo da placa)
        local hw     = tonumber(c.PlateHalfWidth)  or 0.20
        local hh     = tonumber(c.PlateHalfHeight) or 0.07
        local outOff = 0.03
        local nbolts = math.floor(tonumber(c.Bolts) or 4)
        local layout
        if nbolts <= 2 then
            layout = { { -1.0, 1.0 }, { 1.0, 1.0 } }
        else
            layout = { { -1.0, 1.0 }, { 1.0, 1.0 }, { -1.0, -1.0 }, { 1.0, -1.0 } }
        end

        local points = {}
        for i = 1, #layout do
            local u, v = layout[i][1], layout[i][2]
            points[#points + 1] = center + (rightV * (u * hw)) + (up * (v * hh)) + (outward * outOff)
        end

        -- Câmera POR FORA da face escolhida (model-space: +Y = frente), ~1.2 m
        -- afastada e um pouco acima, olhando de volta para a placa.
        --   traseira: yPlate ≈ vmin.y  → câmera mais para trás  (yPlate - 1.2)
        --   dianteira: yPlate ≈ vmax.y → câmera mais para frente (yPlate + 1.2)
        local camBack = isRear and (yPlate - 1.2) or (yPlate + 1.2)

        local r = runBoltSurface({
            points  = points,
            outward = outward,
            camPos  = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, camBack, zPlate + 0.25),
            lookAt  = center,
            baseRot = { x = 90.0, y = 0.0, z = vehHeading + (isRear and 180.0 or 0.0) },
            needed  = (tonumber(c.TurnsToLoosen) or 1.5) * 360.0,
            sens    = tonumber(c.Sensitivity) or 900.0,
            hoverR  = tonumber(c.HoverRadius)  or 0.09,
            timeout = tonumber(c.Timeout)      or 25000,
        })

        if r == 'fallback' then return VPChopPlateBoltFallback() end
        if not r then VPChopNotify(L('notify_skill_fail'), 'error'); return false end
        return true
    end
end

-- ─── Tyre proximity detection (wheel_theft pattern) ─────────────────────────
-- Localiza a roda MONTADA mais próxima do jogador.
-- isMounted via GetVehicleWheelXOffset: roda intacta ≈ 0.0; removida = 9999999.
-- Só rodas montadas entram na comparação de distância.
local function findNearestMountedWheel(veh)
    local ped     = PlayerPedId()
    local pCoords = GetEntityCoords(ped)
    local vmin, vmax = GetModelDimensions(GetEntityModel(veh))

    -- Posições aproximadas das 4 rodas no espaço do modelo (igual ao wheel_theft)
    local offsets = {
        { x = vmin.x, y = vmax.y - 0.7, z = vmin.z },  -- 0: wheel_lf
        { x = vmax.x, y = vmax.y - 0.7, z = vmin.z },  -- 1: wheel_rf
        { x = vmin.x, y = vmin.y + 0.7, z = vmin.z },  -- 2: wheel_lr
        { x = vmax.x, y = vmin.y + 0.7, z = vmin.z },  -- 3: wheel_rr
    }
    local boneNames = { 'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr' }
    local suspNames = { 'suspension_lf', 'suspension_rf', 'suspension_lr', 'suspension_rr' }

    local bestDist = 1000.0
    local bestIdx, bestCoords

    for i, off in ipairs(offsets) do
        local wheelIdx0 = i - 1  -- índice 0-based
        -- Só considera rodas ainda montadas (offset normal < 300; removidas = 9999999)
        local xOff = GetVehicleWheelXOffset(veh, wheelIdx0)
        if math.abs(xOff) < 300.0 then
            local wc = GetOffsetFromEntityInWorldCoords(veh, off.x, off.y, off.z)
            -- Refinar com bone de suspensão se disponível (mais preciso)
            local suspId = GetEntityBoneIndexByName(veh, suspNames[i])
            if suspId and suspId ~= -1 then
                local sc = GetWorldPositionOfEntityBone(veh, suspId)
                if sc.x ~= 0.0 or sc.y ~= 0.0 then wc = sc end
            end
            local d = #(wc - pCoords)
            if d < bestDist then
                bestDist   = d
                bestIdx    = wheelIdx0
                bestCoords = wc
            end
        end
    end

    if not bestIdx then return nil end  -- todas as rodas já removidas

    local idx1 = bestIdx + 1  -- 1-based para boneNames/suspNames
    -- isMounted = true garantido: só rodas com offset normal chegam aqui
    return bestCoords, bestDist, bestIdx, boneNames[idx1], true
end

--- [v1.16 UX-B.2 / UX-C] Helper comum para cálculo de budget de UX clock-safe.
--- ttlMs = st.expiresAt - st.startedAt (ambos no domínio do servidor).
--- Retorna (budget, nil) se válido, ou (false, errCode) em fail-closed.
local function computeUxBudget(ttlMs, minUxMs, reserveMs)
    if not ttlMs or ttlMs <= 0 then return false, 'budget_invalid' end
    local reserve = reserveMs or 4000
    local minUx   = minUxMs or 4000
    local budget  = ttlMs - reserve
    if budget < minUx then return false, 'budget_insufficient' end
    return budget, nil
end

--- [v1.16 UX-B.2] Executa a experiência física interativa da remoção da roda.
--- Utiliza VPChopDismantleMinigame com o profile 'wheel' (5 parafusos com giro de mouse),
--- seguido de uma animação física de retirada do pneu antes do commit na ActionSession.
---
--- Clock-domain safety:
---   ActionSession.Start retorna { startedAt, expiresAt } em clock do FXServer.
---   O client NÃO pode comparar diretamente expiresAt com GetGameTimer() (clocks distintos).
---   O chamador deve derivar `ttlMs = expiresAt - startedAt` (mesmo domínio de clock do
---   servidor), depois passar esse ttlMs aqui. Aqui aplica-se: clientDeadline = now + ttlMs.
---
--- @param ttlMs     number|nil   Duração total da ActionSession em ms, derivada server-side.
---                               nil indica fluxo legacy (sem ActionSession).
--- @param isAction  boolean|nil  true = modo ActionSession; nil/false = fluxo legacy.
---
--- Retorna: true  → minigame completo + animação OK
---          false → cancelado, falha ou budget insuficiente (caller deve enviar action:cancel)
---          string (2º val, opcional) → código de erro: 'budget_invalid' / 'budget_insufficient'
local function runWheelUx(veh, wheelIdx, partKey, ttlMs, isAction)
    local boneNames = { 'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr' }
    local boneKey   = partKey or boneNames[(wheelIdx or 0) + 1] or 'wheel_lf'

    local PULL_ANIM_MS  = 1500
    local RESERVE_MS    = 4000  -- START transit(1000) + COMPLETE RTT(1000) + jitter(500) + pull(1500)
    local MIN_UX_MS     = 5000  -- mínimo para uma experiência de 5 parafusos ser viável

    local uxTimeout
    if isAction then
        local budget, err = computeUxBudget(ttlMs, MIN_UX_MS, RESERVE_MS)
        if not budget then return false, err end
        uxTimeout = budget
    else
        -- Fluxo legacy (kill-switch desligado): sem ActionSession, usa timeout padrão.
        uxTimeout = 45000
    end

    local minigameOk = false
    if VPChopDismantleMinigame and VPChopDismantleMinigame.Start then
        minigameOk = VPChopDismantleMinigame.Start(veh, 'wheel', {
            boneKey = boneKey,
            uxSpeed = 1.0,
            timeout = uxTimeout,
        })
    else
        minigameOk = VPChopBoltMinigame(veh, wheelIdx)
    end

    if not minigameOk then return false end

    -- Animação física de puxar/remover o pneu do cubo da roda (1.5s)
    return lib.progressBar({
        duration     = PULL_ANIM_MS,
        label        = L('tyremission_pulling_tyre'),
        useWhileDead = false, canCancel = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'anim@heists@box_carry@', clip = 'idle', flag = 1 },
    }) == true
end

--- Executa o roubo de uma roda. BASE TYRE passa pela ActionSession (PR-F):
--- getActive → action:start → UX → action:complete/cancel → visual + carry prop.
--- Kill-switch: se Config.ActionSession.Enable == false, cai no callback legacy.
local function doJackstandTyreSteal(veh, wheelIdx, partKey)
    if JackstandBusy then return end
    JackstandBusy = true
    CreateThread(function()
        local netId = NetworkGetNetworkIdFromEntity(veh)
        local useAction = VPChopActionModeTyre()   -- [PR-G] exclusivo: ActionSession OU legacy
        local tyreEntitlementId

        if useAction then
            -- 1) sessionId server-authoritative (read-only; nunca cria sessão)
            local sOk, sess = pcall(lib.callback.await, 'vp_chopshop:session:getActive', false, netId)
            if not sOk or not sess or not sess.ok or not sess.sessionId then
                JackstandBusy = false
                VPChopNotify(L('notify_chop_failed_fmt', VPChopLocaleErr(sess and sess.err or 'no_session')), 'error')
                return
            end

            -- 2) START
            local stOk, st = pcall(lib.callback.await, 'vp_chopshop:action:start', false,
                { sessionId = sess.sessionId, action = partKey })
            if not stOk or not st or not st.ok then
                JackstandBusy = false
                VPChopNotify(L('notify_chop_failed_fmt', VPChopActionErr(st and st.err)), 'error')
                return
            end
            local actionId = st.actionId

            -- 3) UX — budget derivado do MESMO domínio de clock do servidor.
            -- NUNCA compare st.expiresAt com GetGameTimer() — são clocks distintos.
            -- Derive ttlMs = expiresAt - startedAt (ambos do servidor) e aplique
            -- client-side como: clientDeadline = GetGameTimer() + ttlMs.
            local ttlMs = (st.expiresAt and st.startedAt)
                          and (st.expiresAt - st.startedAt) or 0
            local uxOk, uxErr = runWheelUx(veh, wheelIdx, partKey, ttlMs, true)
            if not uxOk then
                pcall(lib.callback.await, 'vp_chopshop:action:cancel', false, actionId)
                JackstandBusy = false
                if uxErr == 'budget_insufficient' or uxErr == 'budget_invalid' then
                    VPChopNotify(L('notify_chop_failed_fmt', uxErr), 'error')
                end
                return
            end

            -- 4) COMPLETE (com 1 retry curto se too_fast)
            local cOk, res = pcall(lib.callback.await, 'vp_chopshop:action:complete', false, actionId)
            if cOk and res and res.err == 'too_fast' then
                Wait((res.waitMs or 500) + 50)
                cOk, res = pcall(lib.callback.await, 'vp_chopshop:action:complete', false, actionId)
            end
            JackstandBusy = false
            if not cOk or not res or not res.ok then
                VPChopNotify(L('notify_chop_failed_fmt', VPChopActionErr(res and res.err)), 'error')
                return
            end
            tyreEntitlementId = res.result and res.result.tyreEntitlementId
        else
            -- Kill-switch: fluxo legacy direto (ActionSession desligada).
            local uxOk = runWheelUx(veh, wheelIdx, partKey)
            if not uxOk then JackstandBusy = false; return end
            local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:chopPart', false, netId, partKey)
            JackstandBusy = false
            if not cbOk or not res or not res.ok then
                if res and res.err == 'cooldown' and res.wait then
                    VPChopNotify(L('notify_cooldown_fmt', res.wait), 'error')
                else
                    VPChopNotify(L('notify_chop_failed_fmt', VPChopLocaleErr(res and res.err) or L('notify_generic_error')), 'error')
                end
                return
            end
            tyreEntitlementId = res.tyreEntitlementId
        end

        -- wheelIdx é 0-3 sequencial (FL=0, FR=1, RL=2, RR=3) — correto para SetVehicleWheelXOffset
        -- Requer controlo de rede para alterar propriedades visuais do veículo
        NetworkRequestControlOfEntity(veh)
        local deadline = GetGameTimer() + 1000
        while not NetworkHasControlOfEntity(veh) and GetGameTimer() < deadline do
            Wait(50)
        end
        SetVehicleWheelXOffset(veh, wheelIdx, 9999999.0)

        -- 1) Limpar qualquer carry state residual antes de instanciar o novo prop
        VPChopDropCarryPart()

        -- 2) Prop nas mãos + reiniciar carry animation (igual ao PutWheelInHands do wheel_theft)
        local wheelProp = VPTyreSpawnWheelPropInHand(partKey)
        if wheelProp and DoesEntityExist(wheelProp) then
            -- [v1.15 PR-E/F] guarda o entitlementId do pneu (nunca gerado client-side —
            -- vem do RESULTADO terminal da ActionSession, ou do callback legacy).
            VPChopCarryingPart = {
                partKey       = partKey,
                propHandle    = wheelProp,
                isTyre        = true,
                entitlementId = tyreEntitlementId,
            }

            -- [PERF] TextUI exibida UMA vez (persiste até hideTextUI).
            -- VPChopDropCarryPart() (carry.lua) chama hideTextUI ao soltar o pneu.
            lib.showTextUI('[G] ' .. L('tyre_carry_textui') .. ' | [E] ' .. L('tyre_option_drop'), {
                position = 'left-center',
                icon     = 'circle-dot',
            })
        else
            -- Fallback defensivo: se a criação/attach na mão falhar, coloca prop de chão com target de pickup
            local ped = PlayerPedId()
            local fwd = GetEntityForwardVector(ped)
            local px, py, pz = table.unpack(GetEntityCoords(ped))
            local dropX = px + (fwd.x * 0.75)
            local dropY = py + (fwd.y * 0.75)
            local found, gz = GetGroundZFor_3dCoord(dropX, dropY, pz + 2.0, false)
            local finalZ = (found and (gz + 0.12)) or (pz - 0.85)

            local modelHash = GetHashKey('prop_wheel_01')
            RequestModel(modelHash)
            local tLoad = GetGameTimer()
            while not HasModelLoaded(modelHash) and (GetGameTimer() - tLoad < 2000) do Wait(50) end
            local groundProp = CreateObject(modelHash, dropX, dropY, finalZ, true, true, true)
            SetEntityAsMissionEntity(groundProp, true, true)
            SetModelAsNoLongerNeeded(modelHash)
            if groundProp and DoesEntityExist(groundProp) then
                SetEntityRotation(groundProp, 90.0, 0.0, GetEntityHeading(ped), 2, true)
                if PlaceObjectOnGroundProperly then
                    pcall(PlaceObjectOnGroundProperly, groundProp)
                end
                FreezeEntityPosition(groundProp, true)
                registerGroundTyreTarget(groundProp, tyreEntitlementId)
                VPChopNotify(L('tyre_dropped'), 'inform')
            end
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────

-- Broadcast do servidor: porta/capô/porta-malas removida visualmente + atualiza estado local
RegisterNetEvent('vp_chopshop:adv:breakDoor', function(netId, partKey, doorIndex)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehicleDoorBroken(veh, doorIndex, true)
    end
    advMarkChopped(netId, partKey)
end)

--- [v1.15 PR-G] UX de uma fase avançada legada (tool prop + alarm dispatch + progress bar).
--- Retorna true se o jogador concluiu; false se cancelou/falhou.
local function runAdvUx(veh, tCfg, label, ms, anim, defaultDict, defaultClip, defaultFlag)
    spawnToolProp(anim and anim.prop)
    VPChopCheckAlarmAndDispatch(veh, tCfg)
    local ok = lib.progressBar({
        duration = math.floor(ms * ((tCfg and tCfg.speedMult) or 1.0)), label = label,
        useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = {
            dict = (anim and anim.dict) or defaultDict,
            clip = (anim and anim.clip) or defaultClip,
            flag = (anim and anim.flag) or defaultFlag,
        },
    })
    destroyToolProp()
    return ok == true
end

--- [v1.16 UX-C] Executa a experiência física interativa de desmanche de painel (bonnet, boot, portas).
--- 1. Spawna a ferramenta de corte na mão do ped (prop_tool_consaw).
--- 2. Toca a animação nativa contínua de corte do GTA (SawAnim).
--- 3. Abre a NUI com os pontos contextuais de corte (dobradiças / travas) usando primitive 'cut'.
--- 4. Conclui os pontos com velocidade escalada pela ferramenta (saw_cheap vs saw_pro).
--- 5. Toca uma rápida animação física de soltura (800ms).
--- 6. Retorna true para a ActionSession completar no servidor (a peça é removida pelo commit).
local function runPanelUx(veh, partKey, ttlMs, isAction, tCfg)
    local profileName = 'panel_' .. partKey
    local profile = (VPChopProfiles and VPChopProfiles.Get and VPChopProfiles.Get(profileName))
                    or (VPChopProfiles and VPChopProfiles.Get and VPChopProfiles.Get('panel'))

    local uxTimeout
    if isAction then
        local minUx = (profile and profile.minUxMs) or 3500
        local reserve = (profile and profile.reserveMs) or 3500
        local budget, err = computeUxBudget(ttlMs, minUx, reserve)
        if not budget then return false, err end
        uxTimeout = budget
    else
        uxTimeout = 45000
    end

    -- uxSpeed derivado da ferramenta:
    -- saw_cheap: speedMult = 1.4 -> uxSpeed = 1.0 / 1.4 = ~0.714 (mais tempo de corte)
    -- saw_pro:   speedMult = 1.0 -> uxSpeed = 1.0 (baseline)
    local speedMult = (tCfg and (tCfg.speedMult or tCfg.uxSpeed)) or 1.0
    local uxSpeed = (speedMult > 0) and (1.0 / speedMult) or 1.0

    local animCfg = (Config.AdvancedChop and Config.AdvancedChop.SawAnim) or {
        dict = 'anim@scripted@heist@ig16_glass_cut@male@',
        clip = 'cutting_loop',
        flag = 1,
        prop = {
            model    = 'prop_tool_consaw',
            offset   = { 0.05, 0.02, 0.0 },
            rotation = { 20, 0, -50 },
        },
    }

    spawnToolProp(animCfg and animCfg.prop)
    VPChopCheckAlarmAndDispatch(veh, tCfg)

    local minigameOk = false
    if VPChopDismantleMinigame and VPChopDismantleMinigame.Start then
        minigameOk = VPChopDismantleMinigame.Start(veh, profileName, {
            boneKey = partKey,
            uxSpeed = uxSpeed,
            timeout = uxTimeout,
            anim    = animCfg,
        })
    else
        minigameOk = VPChopMinigameFallback(veh, partKey, 'panel_core_missing')
    end

    destroyToolProp()

    if not minigameOk then return false end

    -- Animação física curta de soltura / puxão do painel cortado (800ms)
    return lib.progressBar({
        duration     = 800,
        label        = L('adv_panel_pulling'),
        useWhileDead = false, canCancel = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'anim@heists@box_carry@', clip = 'idle', flag = 1 },
    }) == true
end

--- [v1.16 UX-D] Orienta o ped suavemente para olhar na direção do componente alvo.
local function orientPedToTarget(ped, targetCoords)
    if not ped or not targetCoords then return end
    TaskTurnPedToFaceCoord(ped, targetCoords.x, targetCoords.y, targetCoords.z, 600)
    Wait(300)
end

--- [v1.16 UX-D] Executa a experiência física interativa de desacoplamento do bloco do motor.
--- 1. Orienta o ped para o cofre do motor.
--- 2. Spawna a parafusadeira mecânica (prop_tool_drill) na mão.
--- 3. Inicia animação mecânica contínua (EngineAnim).
--- 4. Abre a NUI com os 4 calços estruturais usando a primitive 'drill'.
--- 5. Executa a perfuração/soltura dos 4 fixadores.
--- 6. Toca uma rápida sequência de desacoplamento físico (800ms).
--- 7. Retorna true para a ActionSession completar no servidor (o motor é comitado como removido).
local function runEngineUx(veh, ttlMs, isAction, tCfg)
    local profile = VPChopProfiles and VPChopProfiles.Get and VPChopProfiles.Get('engine')

    local uxTimeout
    if isAction then
        local minUx = (profile and profile.minUxMs) or 3500
        local reserve = (profile and profile.reserveMs) or 3500
        local budget, err = computeUxBudget(ttlMs, minUx, reserve)
        if not budget then return false, err end
        uxTimeout = budget
    else
        uxTimeout = 45000
    end

    -- uxSpeed derivado de mechanic_drill:
    -- speedMult = 0.7 -> uxSpeed = 1.0 / 0.7 = ~1.43 (rápido torque elétrico)
    local speedMult = (tCfg and (tCfg.speedMult or tCfg.uxSpeed)) or 0.7
    local uxSpeed = (speedMult > 0) and (1.0 / speedMult) or 1.43

    local animCfg = (Config.AdvancedChop and Config.AdvancedChop.EngineAnim) or {
        dict = 'mini@repair',
        clip = 'fixing_a_player',
        flag = 1,
        prop = {
            model    = 'prop_tool_drill',
            offset   = { 0.12, 0.04, -0.02 },
            rotation = { -80.0, 0.0, 0.0 },
        },
    }

    local ped = PlayerPedId()
    local bayPos = GetEntityCoords(veh)
    local bonnetBone = GetEntityBoneIndexByName(veh, 'bonnet')
    if bonnetBone ~= -1 then
        bayPos = GetWorldPositionOfEntityBone(veh, bonnetBone)
    end
    orientPedToTarget(ped, bayPos)

    spawnToolProp(animCfg and animCfg.prop)
    VPChopCheckAlarmAndDispatch(veh, tCfg)

    local minigameOk = false
    if VPChopDismantleMinigame and VPChopDismantleMinigame.Start then
        minigameOk = VPChopDismantleMinigame.Start(veh, 'engine', {
            boneKey = 'bonnet',
            uxSpeed = uxSpeed,
            timeout = uxTimeout,
            anim    = animCfg,
        })
    else
        minigameOk = VPChopMinigameFallback(veh, 'adv_engine', 'engine_core_missing')
    end

    destroyToolProp()

    if not minigameOk then return false end

    -- Animação física curta de desacoplamento do bloco do motor (800ms)
    return lib.progressBar({
        duration     = 800,
        label        = L('adv_engine_pulling'),
        useWhileDead = false, canCancel = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    }) == true
end

--- [v1.16 UX-E / UX-E.1] Executa a experiência física interativa de corte estrutural da carcaça do chassi.
--- 1. Orienta o ped para a lateral/estrutura do veículo.
--- 2. Spawna o maçarico de solda/corte (prop_weld_torch) na mão.
--- 3. Inicia animação contínua de solda/corte GTA (CarcassAnim).
--- 4. Abre a NUI com 5 linhas estruturais (polylines) usando a primitive 'trace'.
--- 5. O jogador acompanha e corta fisicamente as 5 seções do chassi.
--- 6. Toca uma rápida sequência de separação/desprendimento estrutural (800ms).
--- 7. Retorna true para a ActionSession completar no servidor (o chassi entra no estado terminal).
local function runCarcassUx(veh, ttlMs, isAction)
    local profile = VPChopProfiles and VPChopProfiles.Get and VPChopProfiles.Get('carcass')

    local uxTimeout
    if isAction then
        local minUx = (profile and profile.minUxMs) or 6000
        local reserve = (profile and profile.reserveMs) or 4000
        local budget, err = computeUxBudget(ttlMs, minUx, reserve)
        if not budget then return false, err end
        uxTimeout = budget
    else
        uxTimeout = 45000
    end

    -- [UX-E.1] Velocidade de corte da carcaça é independente de serra de inventário
    local uxSpeed = (profile and profile.traceSpeed) or 1.0

    local animCfg = (Config.AdvancedChop and Config.AdvancedChop.CarcassAnim) or {
        dict = 'amb@world_human_welding@male@base',
        clip = 'base',
        flag = 1,
        prop = {
            model    = 'prop_weld_torch',
            offset   = { 0.08, 0.03, 0.0 },
            rotation = { 0, 0, 0 },
        },
    }

    local ped = PlayerPedId()
    orientPedToTarget(ped, GetEntityCoords(veh))

    spawnToolProp(animCfg and animCfg.prop)
    VPChopCheckAlarmAndDispatch(veh, nil)

    local minigameOk = false
    if VPChopDismantleMinigame and VPChopDismantleMinigame.Start then
        minigameOk = VPChopDismantleMinigame.Start(veh, 'carcass', {
            boneKey = 'carcass',
            uxSpeed = uxSpeed,
            timeout = uxTimeout,
            anim    = animCfg,
        })
    else
        minigameOk = VPChopMinigameFallback(veh, 'adv_carcass', 'carcass_core_missing')
    end

    destroyToolProp()

    if not minigameOk then return false end

    -- Animação física curta de separação/desprendimento estrutural (800ms)
    return lib.progressBar({
        duration     = 800,
        label        = L('adv_carcass_pulling'),
        useWhileDead = false, canCancel = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'anim@heists@box_carry@', clip = 'idle', flag = 1 },
    }) == true
end

--- [v1.15 PR-G / v1.16 UX-C / UX-D / UX-E] Fluxo genérico de uma fase avançada via ActionSession:
--- getActive → action:start → UX (física interativa ou progresso) → action:complete/cancel.
--- Kill-switch (Config.ActionSession.Enable == false) cai no callback legacy adv:*.
--- @param opts { action, legacyEvent, label, ms, anim, dict, clip, flag, notifyOk, usePanelUx, useEngineUx, useCarcassUx }
local function doAdvAction(veh, netId, tCfg, opts)
    CreateThread(function()
        local useAction = VPChopActionModeAdvanced()   -- [PR-G] exclusivo: ActionSession OU legacy
        local function ux() return runAdvUx(veh, tCfg, opts.label, opts.ms, opts.anim, opts.dict, opts.clip, opts.flag) end

        if useAction then
            local sOk, sess = pcall(lib.callback.await, 'vp_chopshop:session:getActive', false, netId)
            if not sOk or not sess or not sess.ok or not sess.sessionId then
                JackstandBusy = false
                VPChopNotify(L('notify_chop_failed_fmt', VPChopActionErr(sess and sess.err or 'no_session')), 'error')
                return
            end
            local stOk, st = pcall(lib.callback.await, 'vp_chopshop:action:start', false,
                { sessionId = sess.sessionId, action = opts.action })
            if not stOk or not st or not st.ok then
                JackstandBusy = false
                VPChopNotify(L('notify_chop_failed_fmt', VPChopActionErr(st and st.err)), 'error')
                return
            end
            local actionId = st.actionId

            local uxOk, uxErr
            if opts.usePanelUx then
                local ttlMs = (st.expiresAt and st.startedAt) and (st.expiresAt - st.startedAt) or 0
                uxOk, uxErr = runPanelUx(veh, opts.action, ttlMs, true, tCfg)
            elseif opts.useEngineUx then
                local ttlMs = (st.expiresAt and st.startedAt) and (st.expiresAt - st.startedAt) or 0
                uxOk, uxErr = runEngineUx(veh, ttlMs, true, tCfg)
            elseif opts.useCarcassUx then
                local ttlMs = (st.expiresAt and st.startedAt) and (st.expiresAt - st.startedAt) or 0
                uxOk, uxErr = runCarcassUx(veh, ttlMs, true)
            else
                uxOk = ux()
            end

            if not uxOk then
                pcall(lib.callback.await, 'vp_chopshop:action:cancel', false, actionId)
                JackstandBusy = false
                if uxErr == 'budget_insufficient' or uxErr == 'budget_invalid' then
                    VPChopNotify(L('notify_chop_failed_fmt', uxErr), 'error')
                end
                return
            end
            local cOk, res = pcall(lib.callback.await, 'vp_chopshop:action:complete', false, actionId)
            if cOk and res and res.err == 'too_fast' then
                Wait((res.waitMs or 500) + 50)
                cOk, res = pcall(lib.callback.await, 'vp_chopshop:action:complete', false, actionId)
            end
            JackstandBusy = false
            if not cOk or not res or not res.ok then
                VPChopNotify(L('notify_chop_failed_fmt', VPChopActionErr(res and res.err)), 'error')
                return
            end
        else
            local uxOk
            if opts.usePanelUx then
                uxOk = runPanelUx(veh, opts.action, nil, false, tCfg)
            elseif opts.useEngineUx then
                uxOk = runEngineUx(veh, nil, false, tCfg)
            elseif opts.useCarcassUx then
                uxOk = runCarcassUx(veh, nil, false)
            else
                uxOk = ux()
            end
            if not uxOk then JackstandBusy = false; return end
            local cbOk, result = pcall(lib.callback.await, opts.legacyEvent, false, netId, opts.action)
            JackstandBusy = false
            if not cbOk or not result or not result.ok then
                VPChopNotify(VPChopLocaleErr(result and result.err) or L('notify_generic_error'), 'error')
                return
            end
        end

        advMarkChopped(netId, opts.action)
        VPChopNotify(L(opts.notifyOk), 'success')
    end)
end

local function doAdvChopPart(veh, netId, partKey)
    if JackstandBusy then return end
    local tName, tCfg = getPlayerTool()
    if not tName then VPChopNotify(L('notify_no_saw'), 'error'); return end
    JackstandBusy = true
    doAdvAction(veh, netId, tCfg, {
        action      = partKey,
        legacyEvent = 'vp_chopshop:adv:chopPart',
        label       = L('adv_progress_door'),
        ms          = (Config.AdvancedChop and Config.AdvancedChop.DoorProgressMs) or 6000,
        anim        = Config.AdvancedChop and Config.AdvancedChop.SawAnim,
        dict        = 'anim@scripted@heist@ig16_glass_cut@male@',
        clip        = 'cutting_loop',
        flag        = 1,
        notifyOk    = 'adv_part_removed',
        usePanelUx  = true,  -- [UX-C] Body panels usam a desmontagem física interativa
    })
end

local function doAdvChopEngine(veh, netId)
    if JackstandBusy then return end
    -- [UX-D] Pré-requisito defensivo: o capô precisa ter sido removido primeiro
    if not advIsChopped(netId, 'bonnet') then
        VPChopNotify(L('err_hood_first') or 'Remova o capô primeiro.', 'error')
        return
    end
    local tName, tCfg = getPlayerTool('drill')
    if not tName then VPChopNotify(L('notify_no_drill'), 'error'); return end
    JackstandBusy = true
    doAdvAction(veh, netId, tCfg, {
        action      = 'adv_engine',
        legacyEvent = 'vp_chopshop:adv:chopEngine',
        label       = L('adv_progress_engine'),
        ms          = (Config.AdvancedChop and Config.AdvancedChop.EngineProgressMs) or 8000,
        anim        = Config.AdvancedChop and Config.AdvancedChop.EngineAnim,
        dict        = 'mini@repair',
        clip        = 'fixing_a_player',
        flag        = 1,
        notifyOk    = 'adv_engine_removed',
        useEngineUx = true,  -- [UX-D] Motor usa o desacoplamento físico com parafusadeira
    })
end

local function doAdvChopCarcass(veh, netId)
    if JackstandBusy then return end
    -- [UX-E] Pré-requisito defensivo: o motor precisa ter sido removido primeiro (engine_first)
    if not advIsChopped(netId, 'adv_engine') then
        VPChopNotify(L('err_engine_first') or 'Remova o motor primeiro.', 'error')
        return
    end
    local welderRadius = (Config.AdvancedChop and Config.AdvancedChop.WelderRadius) or 8.0
    if not hasNearbyWelder(GetEntityCoords(veh), welderRadius) then
        VPChopNotify(L('err_no_welder_adv'), 'error'); return
    end
    -- [UX-E.1] Carcass tem toolClass = nil. Não exige serra no inventário. O gate é a máquina de solda física no chão.
    JackstandBusy = true
    doAdvAction(veh, netId, nil, {
        action       = 'adv_carcass',
        legacyEvent  = 'vp_chopshop:adv:chopCarcass',
        label        = L('adv_progress_carcass'),
        ms           = (Config.AdvancedChop and Config.AdvancedChop.CarcassProgressMs) or 10000,
        anim         = Config.AdvancedChop and Config.AdvancedChop.CarcassAnim,
        dict         = 'amb@world_human_welding@male@base',
        clip         = 'base',
        flag         = 1,
        notifyOk     = 'adv_carcass_done',
        useCarcassUx = true,  -- [UX-E] Carcaça usa o corte estrutural interativo
    })
end

-- ─────────────────────────────────────────────────────────────────────────────

local function addRaisedCarTargets(veh)
    local targets = {}
    targets[#targets + 1] = {
        name        = 'vp_chop_jack_lower_' .. tostring(veh),
        label       = L('jackstand_target_lower'),
        icon        = 'fa-solid fa-arrow-down',
        distance    = 3.5,
        canInteract = function() return JackstandData[veh] ~= nil and not JackstandBusy end,
        onSelect    = function() VPChopJackstandLowerCar(veh) end,
    }
    -- Fase 2/3/4: desmanche avançado (requer Config.AdvancedChop.Enable)
    if Config.AdvancedChop and Config.AdvancedChop.Enable then
        local netId = NetworkGetNetworkIdFromEntity(veh)

        -- Fase 2: portas / capô / porta-malas (bone-based, requer serra)
        -- Apenas adiciona o target se o bone existir no rig do veículo
        -- (carros de 2 portas não têm door_dside_r / door_pside_r)
        local advDoorParts = {
            { key = 'door_dside_f', bone = 'door_dside_f' },
            { key = 'door_pside_f', bone = 'door_pside_f' },
            { key = 'door_dside_r', bone = 'door_dside_r' },
            { key = 'door_pside_r', bone = 'door_pside_r' },
            { key = 'bonnet',       bone = 'bonnet'       },
            { key = 'boot',         bone = 'boot'         },
        }
        for _, ap in ipairs(advDoorParts) do
            local aKey  = ap.key
            local aBone = ap.bone
            -- Ignorar se o bone não existe neste veículo
            if GetEntityBoneIndexByName(veh, aBone) ~= -1 then
                local def = VPChopPartRegistry.get(aKey)
                local lbl = def and L(def.labelKey) or aKey
                targets[#targets + 1] = {
                    name     = 'vp_adv_chop_' .. aKey .. '_' .. tostring(veh),
                    label    = L('adv_target_door_fmt', lbl),
                    icon     = 'fa-solid fa-screwdriver-wrench',
                    bones    = { aBone },
                    distance = 2.5,
                    canInteract = function()
                        return JackstandData[veh] ~= nil
                            and not JackstandBusy
                            and not advIsChopped(netId, aKey)
                    end,
                    onSelect = function() doAdvChopPart(veh, netId, aKey) end,
                }
            end
        end

        -- Fase 3: motor (requer capô removido)
        -- Usa o bone 'bonnet' como âncora — engine fica sob o capô;
        -- 'engine' não existe em todos os rigs GTA V.
        targets[#targets + 1] = {
            name     = 'vp_adv_chop_engine_' .. tostring(veh),
            label    = L('adv_target_engine'),
            icon     = 'fa-solid fa-gear',
            bones    = { 'bonnet' },
            distance = 2.5,
            canInteract = function()
                return JackstandData[veh] ~= nil
                    and not JackstandBusy
                    and advIsChopped(netId, 'bonnet')
                    and not advIsChopped(netId, 'adv_engine')
            end,
            onSelect = function() doAdvChopEngine(veh, netId) end,
        }

        -- Fase 4: carcaça (requer motor removido + soldadora perto)
        targets[#targets + 1] = {
            name     = 'vp_adv_chop_carcass_' .. tostring(veh),
            label    = L('adv_target_carcass'),
            icon     = 'fa-solid fa-scissors',
            distance = 3.5,
            canInteract = function()
                return JackstandData[veh] ~= nil
                    and not JackstandBusy
                    and advIsChopped(netId, 'adv_engine')
                    and not advIsChopped(netId, 'adv_carcass')
            end,
            onSelect = function() doAdvChopCarcass(veh, netId) end,
        }
    end

    -- Fase 1: desmanche básico (peças do Config.CarPartRewards) via macaco
    targets[#targets + 1] = {
        name        = 'vp_chop_jack_dismantle_' .. tostring(veh),
        label       = L('target_dismantle'),
        icon        = 'fa-solid fa-screwdriver-wrench',
        distance    = 3.0,
        canInteract = function() return JackstandData[veh] ~= nil and not JackstandBusy end,
        onSelect    = function() openJackstandChopMenu(veh) end,
    }

    if Config.Discard and Config.Discard.Enable then
        targets[#targets + 1] = {
            name        = 'vp_chop_jack_discard_' .. tostring(veh),
            label       = L('target_discard_vehicle'),
            icon        = 'fa-solid fa-trash-can',
            distance    = 3.5,
            canInteract = function() return JackstandData[veh] ~= nil and not JackstandBusy end,
            onSelect    = function()
                local netId = NetworkGetNetworkIdFromEntity(veh)
                if not netId or netId == 0 then
                    VPChopNotify(L('notify_generic_error'), 'error')
                    return
                end
                local minParts = (Config.Discard and Config.Discard.MinPartsToDiscard) or 4
                local confirmed = lib.alertDialog({
                    header   = L('discard_confirm_title'),
                    content  = L('discard_confirm_body_fmt', minParts),
                    centered = true,
                    cancel   = true,
                })
                if confirmed ~= 'confirm' then return end
                local ok2 = lib.progressBar({
                    duration     = 5000,
                    label        = L('progress_discarding'),
                    useWhileDead = false,
                    canCancel    = true,
                    disable      = { move = true, car = true, combat = true },
                    anim         = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
                })
                if not ok2 then return end
                local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:discardVehicle', false, netId)
                if not cbOk then res = nil end
                if res and res.ok then
                    local msg = L('notify_discard_success_fmt', res.payout)
                    if res.bonus then msg = msg .. ' ' .. L('notify_discard_bonus') end
                    VPChopNotify(msg, 'success')
                elseif res and res.err == 'parts_min' then
                    VPChopNotify(L('notify_discard_parts_min_fmt', res.min or minParts), 'error')
                else
                    VPChopNotify(
                        (res and res.err) and L('notify_chop_failed_fmt', VPChopLocaleErr(res.err)) or L('notify_generic_error'),
                        'error'
                    )
                end
            end,
        }
    end

    -- Targets individuais por roda (ox_target mira no bone da roda)
    -- seqIdx 0-3 para SetVehicleWheelXOffset; partKey = nome do bone = chave em ChopParts
    local tyreSlots = {
        { key = 'wheel_lf', bone = 'wheel_lf', seqIdx = 0 },
        { key = 'wheel_rf', bone = 'wheel_rf', seqIdx = 1 },
        { key = 'wheel_lr', bone = 'wheel_lr', seqIdx = 2 },
        { key = 'wheel_rr', bone = 'wheel_rr', seqIdx = 3 },
    }
    for _, ts in ipairs(tyreSlots) do
        local tKey    = ts.key
        local tBone   = ts.bone
        local tSeqIdx = ts.seqIdx
        local def     = VPChopPartRegistry.get(tKey)
        if def then
            local lbl = L(def.labelKey)
            targets[#targets + 1] = {
                name     = 'vp_chop_tyre_' .. tKey .. '_' .. tostring(veh),
                label    = L('tyremission_steal_label') .. ' — ' .. lbl,
                icon     = 'fa-solid fa-circle-dot',
                bones    = { tBone },
                distance = 3.0,
                canInteract = function()
                    return JackstandData[veh] ~= nil
                        and not JackstandBusy
                        and math.abs(GetVehicleWheelXOffset(veh, tSeqIdx)) < 300.0
                end,
                onSelect = function()
                    doJackstandTyreSteal(veh, tSeqIdx, tKey)
                end,
            }
        end
    end

    exports.ox_target:addLocalEntity(veh, targets)
end

-- Minigame de parafusos (módulo inline — garante carregamento junto com main.lua)
-- Usa boii_minigames se disponível; lib.skillCheck como fallback.
function VPChopRunBoltMinigame(cfg)
    cfg = cfg or {}

    -- Verificar ferramenta obrigatória
    local tool = cfg.RequiredTool
    if tool and tool ~= '' then
        local count = exports.ox_inventory:Search('count', tool)
        if (count or 0) < 1 then
            VPChopNotify(L('jackstand_no_tool') .. ' (' .. tool .. ')', 'error')
            return false
        end
    end

    local rounds  = cfg.Rounds  or 4
    local timeout = cfg.Timeout or 30000
    local mgType  = cfg.Type    or 'skill_circle'
    local useBoii = GetResourceState('boii_minigames') == 'started'

    for i = 1, rounds do
        local passed

        if useBoii then
            local p        = promise.new()
            local resolved = false
            local function res(val)
                if not resolved then resolved = true; p:resolve(val) end
            end
            if mgType == 'button_mash' then
                exports['boii_minigames']:button_mash({
                    style = 'default', difficulty = cfg.Difficulty or 12,
                }, function(ok) res(ok == true) end)
            else
                exports['boii_minigames']:skill_circle({
                    style = 'default', area_size = cfg.AreaSize or 5, speed = cfg.Speed or 0.025,
                }, function(result) res(result ~= 'failed') end)
            end
            CreateThread(function() Wait(timeout); res(false) end)
            passed = Citizen.Await(p)
        else
            local diffs = cfg.SkillCheckDifficulties or { 'easy', 'medium', 'medium', 'hard' }
            local keys  = cfg.SkillCheckKeys         or { 'e', 'e', 'e', 'e' }
            passed = lib.skillCheck(diffs, keys)
        end

        -- Chance extra de falha (opcional)
        local fc = cfg.FailureChance or 0.0
        if passed and fc > 0.0 and math.random() <= fc then passed = false end

        if not passed then
            VPChopNotify(L('tyremission_minigame_fail'), 'error')
            return false
        end

        if i < rounds then Wait(300) end
    end

    return true
end

-- [LIMPEZA] VPChopJackstandStealTyre removida — função órfã (zero chamadas).
-- O fluxo vivo de roubo de pneu via jackstand é doJackstandTyreSteal (mais acima),
-- acionado pelo target de cada roda.

--- [v1.15 arch] Mapeia o err do callback de sessão do jackstand → locale existente.
function VPChopSessionErr(err)
    if err == 'no_item' then return L('jackstand_no_item') end
    if err == 'cooldown' then return L('jackstand_busy') end
    if err == 'already' or err == 'completed' then return L('jackstand_already_raised') end
    if err == 'class' then return 'Tipo de veículo incompatível com macaco.' end
    if err == 'range' then return 'Você está muito longe do veículo.' end
    if err == 'vehicle' or err == 'net' then return L('jackstand_no_car') end
    if err == 'carcass_consumed' then return 'Esta carcaça já foi consumida.' end
    if err == 'player' then return 'Jogador ainda não carregado no servidor.' end
    if err == 'disabled' then return 'Sistema de macaco desativado.' end
    if err == 'session' then return 'Falha ao registrar sessão no servidor.' end
    return (err and ('Erro: ' .. tostring(err))) or L('notify_generic_error')
end

function VPChopJackstandRaiseCar()
    local jcfg = Config.Jackstand
    if not jcfg or not jcfg.Enable then return end
    if JackstandBusy then VPChopNotify(L('jackstand_busy'), 'error'); return end
    local pCoords = GetEntityCoords(PlayerPedId())
    local maxDist = jcfg.MaxCarDistance or 5.0
    local best, bestDist
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        local vc    = GetVehicleClass(veh)
        local isCar = (vc >= 0 and vc <= 7) or (vc >= 9 and vc <= 12) or (vc >= 17 and vc <= 20)
        if isCar then
            local d = #(GetEntityCoords(veh) - pCoords)
            if d <= maxDist and (not bestDist or d < bestDist) then
                best = veh; bestDist = d
            end
        end
    end
    if not best then VPChopNotify(L('jackstand_no_car'), 'error'); return end
    if JackstandData[best] then VPChopNotify(L('jackstand_already_raised'), 'error'); return end
    JackstandBusy = true
    local ped = PlayerPedId()
    if TaskTurnPedToFaceEntity then
        TaskTurnPedToFaceEntity(ped, best, 800)
        Wait(300)
    end
    local raiseAnim = jcfg.RaiseAnim
    spawnToolProp(raiseAnim and raiseAnim.prop)
    local ok = lib.progressBar({
        duration = jcfg.LiftProgressMs or 8000, label = L('jackstand_progress_raise'),
        useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = {
            dict = (raiseAnim and raiseAnim.dict) or 'mini@repair',
            clip = (raiseAnim and raiseAnim.clip) or 'fixing_a_player',
            flag = (raiseAnim and raiseAnim.flag) or 1,
        },
    })
    destroyToolProp()
    if not ok then JackstandBusy = false; return end

    -- [v1.15 arch] AUTORIDADE: o servidor cria/atualiza a ChopSession e marca raised.
    -- Só aplicamos o visual (props + lift) se o servidor autorizar. O client deixa
    -- de ser a verdade de "veículo levantado".
    local netId = NetworkGetNetworkIdFromEntity(best)
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:session:requestRaise', false, netId)
    if not cbOk or not res or not res.ok then
        JackstandBusy = false
        print(('[vp_chopshop] requestRaise failed for netId %s: cbOk=%s err=%s'):format(tostring(netId), tostring(cbOk), tostring(res and res.err)))
        VPChopNotify(VPChopSessionErr(res and res.err), 'error')
        return
    end

    local props = spawnJackstandProps(best)
    local origZ = doLiftVehicle(best)
    Wait(950)   -- aguarda o levantamento completo (~900ms a 0.001/5ms) antes de fixar os cavaletes
    attachJackstandsToCar(best, props)
    JackstandData[best] = { props = props, originalZ = origZ, sessionId = res.sessionId, vsid = res.vsid }
    JackstandBusy = false
    addRaisedCarTargets(best)
    VPChopNotify(L('jackstand_raised'), 'success')
end

function VPChopJackstandLowerCar(veh)
    local data = JackstandData[veh]
    if not data then return end
    if JackstandBusy then VPChopNotify(L('jackstand_busy'), 'error'); return end
    JackstandBusy = true
    local ped = PlayerPedId()
    if TaskTurnPedToFaceEntity then
        TaskTurnPedToFaceEntity(ped, veh, 800)
        Wait(300)
    end
    local lowerAnim = Config.Jackstand and Config.Jackstand.LowerAnim
    spawnToolProp(lowerAnim and lowerAnim.prop)
    local ok = lib.progressBar({
        duration = (Config.Jackstand and Config.Jackstand.LowerProgressMs) or 5000,
        label = L('jackstand_progress_lower'), useWhileDead = false, canCancel = false,
        disable = { move = true, car = true, combat = true },
        anim = {
            dict = (lowerAnim and lowerAnim.dict) or 'mini@repair',
            clip = (lowerAnim and lowerAnim.clip) or 'fixing_a_player',
            flag = (lowerAnim and lowerAnim.flag) or 1,
        },
    })
    destroyToolProp()
    if not ok then JackstandBusy = false; return end

    -- [v1.15 #6] O servidor é autoridade: só baixa o visual se ok==true OU stale==true
    -- (sessão já sumiu). ok==false (ex.: não-participante) → mantém o visual + notifica.
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:session:requestLower', false,
        NetworkGetNetworkIdFromEntity(veh))
    if not cbOk or not res or (not res.ok and not res.stale) then
        JackstandBusy = false
        VPChopNotify(VPChopSessionErr(res and res.err), 'error')
        return
    end

    doLowerVehicle(veh, data.originalZ)
    for i = 1, #data.props do
        local prop = data.props[i]
        if DoesEntityExist(prop) then DeleteEntity(prop) end
    end
    exports.ox_target:removeLocalEntity(veh)
    JackstandData[veh] = nil
    JackstandBusy = false
    VPChopNotify(L('jackstand_lowered'), 'success')
end

-- ============================================================

exports('useBenchItem', function(_, _)
    VPChopStartBenchPlacement()
end)

exports('useWelderItem', function(_, _)
    VPChopStartWelderPlacement()
end)

exports('useJackstandItem', function(_, _)
    VPChopJackstandRaiseCar()
end)

-- ─── Tyre carry: keybind [G] para abrir menu de opções ──────────────────────

--- [v1.15 #1] Mapeia o err do callback loadToTruck para uma mensagem localizada
--- (usa apenas chaves de locale já existentes — sem tocar shared/locale.lua).
--- [v1.15 PR-F] Mapa de erro dos callbacks vp_chopshop:action:*
function VPChopActionErr(err)
    if err == nil then return L('notify_generic_error') end
    if err == 'not_raised'      then return L('jackstand_no_car') end
    if err == 'not_participant' then return L('err_not_participant') end
    if err == 'no_tool'         then return L('notify_no_saw') end
    if err == 'distance'        then return L('err_distance') end
    if err == 'done'            then return L('err_done') end
    if err == 'discarding'      then return L('err_discarding') end
    if err == 'expired'         then return L('action_expired') end
    if err == 'too_fast'        then return L('action_too_fast') end
    if err == 'processing' or err == 'closed' then return L('err_cooldown') end
    if err == 'action_required' then return L('action_required') end
    return L('err_' .. tostring(err))   -- no_session / vehicle / owner / invalid / disabled …
end

function VPChopTyreLoadErr(err)
    if err == 'truck_full' then return L('tyre_truck_full') end
    if err == 'no_truck' or err == 'range' or err == 'bad_truck' then return L('tyre_no_truck_nearby') end
    if err == 'cooldown' or err == 'processing' or err == 'truck_busy' then return L('err_cooldown') end
    if err == 'already_stored' then return L('tyre_already_stored') end
    if err == 'owner' or err == 'entitlement' or err == 'bad_state' then return L('tyre_entitlement_invalid') end
    if err == 'storage_identity' then return L('tyre_storage_identity') end
    return L('notify_generic_error')  -- net / disabled / invalid
end

--- Coloca o prop da mão no chão: desanexa, raycast para Z correto, congela.
--- Adiciona target ox_target no prop resultante para carregar no truck.
local function placeTyreHandPropOnGround()
    if not VPChopCarryingPart or not VPChopCarryingPart.isTyre then return end

    local handProp = VPChopCarryingPart.propHandle
    -- [PR-E] capturar o entitlementId ANTES de limpar o carry — segue com o prop de chão.
    local groundEntitlementId = VPChopCarryingPart.entitlementId
    -- Anular propHandle ANTES de chamar VPChopDropCarryPart para que a função
    -- não delete o prop — queremos reutilizá-lo como prop de chão.
    VPChopCarryingPart.propHandle = nil
    VPChopDropCarryPart()   -- limpa carry state, para animação, esconde TextUI

    if not handProp or not DoesEntityExist(handProp) then return end

    -- Desancorar, posicionar à frente do jogador e deitar horizontalmente no chão
    DetachEntity(handProp, false, false)

    local ped  = PlayerPedId()
    local fwd  = GetEntityForwardVector(ped)
    local px, py, pz = table.unpack(GetEntityCoords(ped))
    local dropX = px + (fwd.x * 0.75)
    local dropY = py + (fwd.y * 0.75)
    local found, gz = GetGroundZFor_3dCoord(dropX, dropY, pz + 2.0, false)
    local finalZ = (found and (gz + 0.12)) or (pz - 0.85)

    SetEntityCoordsNoOffset(handProp, dropX, dropY, finalZ, false, false, false)
    -- Rotação plana (90 graus em X para deitar o pneu no chão como uma roda deitada)
    SetEntityRotation(handProp, 90.0, 0.0, GetEntityHeading(ped), 2, true)
    if PlaceObjectOnGroundProperly then
        pcall(PlaceObjectOnGroundProperly, handProp)
    end
    FreezeEntityPosition(handProp, true)

    registerGroundTyreTarget(handProp, groundEntitlementId)
    VPChopNotify(L('tyre_dropped'), 'inform')
end

local function openTyreOptionsMenu()
    if not VPChopCarryingPart or not VPChopCarryingPart.isTyre then return end

    local max = (Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4

    local menuOptions = {
        {
            title    = L('tyre_option_drop'),
            icon     = 'circle-down',
            onSelect = function() placeTyreHandPropOnGround() end,
        },
    }

    local truck = VPChopFindNearestTruck(5.0)
    if truck then
        local cur = math.floor(tonumber(Entity(truck).state.chopTyreCount) or 0)
        menuOptions[#menuOptions + 1] = {
            title       = L('tyre_option_truck'),
            icon        = 'truck-pickup',
            disabled    = cur >= max,
            description = cur >= max and L('tyre_truck_full') or nil,
            onSelect    = function()
                if not VPChopCarryingPart or not VPChopCarryingPart.isTyre then return end
                local t2 = VPChopFindNearestTruck(5.0)
                if not t2 then VPChopNotify(L('tyre_no_truck_nearby'), 'error'); return end
                local carryEntId = VPChopCarryingPart.entitlementId
                -- [v1.15 #1/PR-E] Request/response: encerra o carry só se o servidor confirmou.
                local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:tyre:loadToTruck', false,
                    NetworkGetNetworkIdFromEntity(t2), carryEntId)
                if not cbOk or not res or not res.ok then
                    VPChopNotify(VPChopTyreLoadErr(res and res.err), 'error')
                    return
                end
                VPChopDropCarryPart()
                VPChopNotify(L('tyre_stored_fmt', res.count, res.max or max), 'success')
            end,
        }
    end

    lib.registerContext({ id = 'vp_tyre_carry_menu', title = L('tyre_carry_menu_title'), options = menuOptions })
    lib.showContext('vp_tyre_carry_menu')
end

-- Keymapping e comandos
RegisterKeyMapping('+vp_tyre_options', 'Opções do pneu carregado', 'keyboard', 'g')
RegisterCommand('+vp_tyre_options', openTyreOptionsMenu, false)
RegisterCommand('-vp_tyre_options', function() end, false)
RegisterCommand('soltarpneu', placeTyreHandPropOnGround, false)
RegisterCommand('droptyre', placeTyreHandPropOnGround, false)

-- Loop de escuta de controles enquanto transporta o pneu (100% responsivo)
CreateThread(function()
    while true do
        if VPChopCarryingPart and VPChopCarryingPart.isTyre then
            -- 47 = INPUT_DETONATE (G a pé)
            if IsControlJustPressed(0, 47) or IsDisabledControlJustPressed(0, 47) then
                openTyreOptionsMenu()
            -- 38 = INPUT_PICKUP / INPUT_CONTEXT (E a pé) -> solta direto no chão
            elseif IsControlJustPressed(0, 38) or IsDisabledControlJustPressed(0, 38) then
                placeTyreHandPropOnGround()
            -- 73 = INPUT_VEH_DUCK (X a pé) -> solta no chão
            elseif IsControlJustPressed(0, 73) or IsDisabledControlJustPressed(0, 73) then
                placeTyreHandPropOnGround()
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)
