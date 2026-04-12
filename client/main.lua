-- [FIX L-4] Declarar AdvChopState antes do handler onResourceStop que o referencia (linha ~95).
-- Em Lua 5.4, 'local' não tem forward scope: sem esta declaração antecipada, a atribuição
-- em onResourceStop teria acessado _G.AdvChopState (global) em vez da local abaixo.
local AdvChopState = {}

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
    local def = ChopParts[partKey]
    if not def then return end
    if def.kind == 'door' then
        SetVehicleDoorBroken(veh, def.index, true)
    else
        SetVehicleTyreBurst(veh, def.index, true, 1000.0)
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
    for veh, data in pairs(JackstandData) do
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

local _toolProp = nil

local function spawnToolProp(propCfg)
    local cfg = propCfg or (Config.ChopTool and Config.ChopTool.HandProp)
    if not cfg or not cfg.model then return end
    local ok = pcall(lib.requestModel, cfg.model, 5000)
    if not ok then return end
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local prop = CreateObject(cfg.model, pos.x, pos.y, pos.z, true, true, false)
    SetModelAsNoLongerNeeded(cfg.model)
    if not prop or prop == 0 then return end
    local handBone = GetPedBoneIndex(ped, 28422)
    local off = cfg.offset   or { 0.0, 0.0, 0.0 }
    local rot = cfg.rotation or { 0, 0, 0 }
    AttachEntityToEntity(prop, ped, handBone,
        off[1], off[2], off[3], rot[1], rot[2], rot[3],
        true, true, false, true, 1, true)
    _toolProp = prop
end

local function destroyToolProp()
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
    local def = ChopParts[partKey]
    local cfg  = Config.ChopAnimations or {}
    local defaultAnim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 49 }
    if partKey == 'bonnet' or partKey == 'boot' then
        return cfg.grinder or defaultAnim, 'grinder'
    end
    if def and def.kind == 'tyre' then
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
    if GetResourceState('qbx_vehiclekeys') == 'started' then
        return exports.qbx_vehiclekeys:HasKeys(vehicle)
    end
    if GetResourceState('qb-vehiclekeys') == 'started' then
        local plate = trimPlate(GetVehicleNumberPlateText(vehicle))
        return exports['qb-vehiclekeys']:HasKeys(plate)
    end
    return true
end

local function isPartMissing(vehicle, def)
    if def.kind == 'door' then
        return IsVehicleDoorDamaged(vehicle, def.index)
    end
    return IsVehicleTyreBurst(vehicle, def.index, false)
end

local function openJackstandChopMenu(veh)
    local ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) ~= 0 then
        VPChopNotify(L('notify_exit_vehicle'), 'error')
        return
    end
    if not hasVehicleKeys(veh) then
        VPChopNotify(L('notify_no_keys'), 'error')
        return
    end
    if Config.ChopTool and Config.ChopTool.Item then
        if exports.ox_inventory:Search('count', Config.ChopTool.Item) < 1 then
            VPChopNotify(L('notify_no_saw'), 'error')
            return
        end
    end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local options = {}
    for _, partKey in ipairs(ChopPartOrder) do
        local def = ChopParts[partKey]
        if def and not isPartMissing(veh, def) then
            local partLabel = L(def.labelKey)
            options[#options + 1] = {
                title = partLabel,
                icon  = 'wrench',
                onSelect = function()
                    if not tryChopSkillCheck() then return end
                    if Config.Ambush and Config.Ambush.Enable then
                        pcall(lib.callback.await, 'vp_chopshop:maybeAmbush', false, netId)
                    end
                    local animCfg, soundType = getPartAnimAndSound(partKey)
                    playChopSound(soundType)
                    spawnToolProp()
                    local ok = lib.progressBar({
                        duration     = Config.ChopProgressMs,
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

local JackstandData = {}
local JackstandBusy = false

-- [STRUCT-07] Convertido para local: usado apenas em VPChopJackstandStealTyre
-- neste mesmo arquivo. Global desnecessária exposta ao ambiente compartilhado.
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
    SetModelAsNoLongerNeeded(modelName)
    if not prop or prop == 0 then return nil end
    local bone = GetPedBoneIndex(ped, 4089)
    AttachEntityToEntity(prop, ped, bone,
        0.1, 0.08, 0.25,
        190.0, 0.0, 0.0,
        true, false, false, false, 2, true)
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
        -- [FIX W-09] Guard de existência: sem isso, se o veículo for deletado durante a
        -- animação (despawn, destruição, saída da OneSync bubble) GetEntityCoords retorna
        -- {0,0,0} e nz nunca alcança targetZ — loop infinito consumindo CPU para sempre.
        while DoesEntityExist(veh) do
            local cur = GetEntityCoords(veh)
            local nz  = math.min(targetZ, cur.z + 0.009)
            SetEntityCoordsNoOffset(veh, cur.x, cur.y, nz, true, true, true)
            if nz >= targetZ then break end
            Wait(16)
        end
    end)
    return origZ
end

local function doLowerVehicle(veh, originalZ)
    local done = false
    CreateThread(function()
        -- [FIX W-08] Guard de existência: mesmo motivo que doLiftVehicle — loop infinito
        -- se o veículo sumir durante a descida.
        while DoesEntityExist(veh) do
            local cur = GetEntityCoords(veh)
            local nz  = math.max(originalZ, cur.z - 0.013)
            SetEntityCoordsNoOffset(veh, cur.x, cur.y, nz, true, true, true)
            if nz <= originalZ then
                FreezeEntityPosition(veh, false)
                done = true
                break
            end
            Wait(16)
        end
        done = true -- garante que o while externo saia mesmo se o veh sumiu
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

-- Broadcast do servidor: porta/capô/porta-malas removida visualmente + atualiza estado local
RegisterNetEvent('vp_chopshop:adv:breakDoor', function(netId, partKey, doorIndex)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehicleDoorBroken(veh, doorIndex, true)
    end
    advMarkChopped(netId, partKey)
end)

local function doAdvChopPart(veh, netId, partKey)
    if JackstandBusy then return end
    JackstandBusy = true
    local ms      = (Config.AdvancedChop and Config.AdvancedChop.DoorProgressMs) or 6000
    local sawAnim = Config.AdvancedChop and Config.AdvancedChop.SawAnim
    spawnToolProp(sawAnim and sawAnim.prop)
    local ok = lib.progressBar({
        duration = ms, label = L('adv_progress_door'),
        useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = {
            dict = (sawAnim and sawAnim.dict) or 'anim@scripted@heist@ig16_glass_cut@male@',
            clip = (sawAnim and sawAnim.clip) or 'cutting_loop',
            flag = (sawAnim and sawAnim.flag) or 1,
        },
    })
    destroyToolProp()
    if not ok then JackstandBusy = false; return end
    local cbOk, result = pcall(lib.callback.await, 'vp_chopshop:adv:chopPart', false, netId, partKey)
    JackstandBusy = false
    if not cbOk or not result then VPChopNotify(L('notify_generic_error'), 'error'); return end
    if not result.ok then VPChopNotify(VPChopLocaleErr(result.err), 'error'); return end
    -- state is also updated via the breakDoor broadcast, but mark locally for instant canInteract
    advMarkChopped(netId, partKey)
    VPChopNotify(L('adv_part_removed'), 'success')
end

local function doAdvChopEngine(veh, netId)
    if JackstandBusy then return end
    JackstandBusy = true
    local ms      = (Config.AdvancedChop and Config.AdvancedChop.EngineProgressMs) or 8000
    local engAnim = Config.AdvancedChop and Config.AdvancedChop.EngineAnim
    spawnToolProp(engAnim and engAnim.prop)
    local ok = lib.progressBar({
        duration = ms, label = L('adv_progress_engine'),
        useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = {
            dict = (engAnim and engAnim.dict) or 'mini@repair',
            clip = (engAnim and engAnim.clip) or 'fixing_a_player',
            flag = (engAnim and engAnim.flag) or 1,
        },
    })
    destroyToolProp()
    if not ok then JackstandBusy = false; return end
    local cbOk, result = pcall(lib.callback.await, 'vp_chopshop:adv:chopEngine', false, netId)
    JackstandBusy = false
    if not cbOk or not result then VPChopNotify(L('notify_generic_error'), 'error'); return end
    if not result.ok then VPChopNotify(VPChopLocaleErr(result.err), 'error'); return end
    advMarkChopped(netId, 'adv_engine')
    VPChopNotify(L('adv_engine_removed'), 'success')
end

local function doAdvChopCarcass(veh, netId)
    if JackstandBusy then return end
    local welderRadius = (Config.AdvancedChop and Config.AdvancedChop.WelderRadius) or 8.0
    if not hasNearbyWelder(GetEntityCoords(veh), welderRadius) then
        VPChopNotify(L('err_no_welder_adv'), 'error')
        return
    end
    JackstandBusy = true
    local ms       = (Config.AdvancedChop and Config.AdvancedChop.CarcassProgressMs) or 10000
    local carcAnim = Config.AdvancedChop and Config.AdvancedChop.CarcassAnim
    spawnToolProp(carcAnim and carcAnim.prop)
    local ok = lib.progressBar({
        duration = ms, label = L('adv_progress_carcass'),
        useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = {
            dict = (carcAnim and carcAnim.dict) or 'mini@repair',
            clip = (carcAnim and carcAnim.clip) or 'fixing_a_player',
            flag = (carcAnim and carcAnim.flag) or 49,
        },
    })
    destroyToolProp()
    if not ok then JackstandBusy = false; return end
    local cbOk, result = pcall(lib.callback.await, 'vp_chopshop:adv:chopCarcass', false, netId)
    JackstandBusy = false
    if not cbOk or not result then VPChopNotify(L('notify_generic_error'), 'error'); return end
    if not result.ok then VPChopNotify(VPChopLocaleErr(result.err), 'error'); return end
    advMarkChopped(netId, 'adv_carcass')
    VPChopNotify(L('adv_carcass_done'), 'success')
end

-- ─────────────────────────────────────────────────────────────────────────────

local function addRaisedCarTargets(veh)
    -- SetVehicleWheelXOffset uses sequential indices 0-3 (not GTA tyre burst slots 0,1,4,5)
    local wheelSlots = {
        { key = 'wheel_lf', idx = 0 },
        { key = 'wheel_rf', idx = 1 },
        { key = 'wheel_lr', idx = 2 },
        { key = 'wheel_rr', idx = 3 },
    }
    local targets = {}
    targets[#targets + 1] = {
        name        = 'vp_chop_jack_lower_' .. tostring(veh),
        label       = L('jackstand_target_lower'),
        icon        = 'fa-solid fa-arrow-down',
        distance    = 3.5,
        canInteract = function() return JackstandData[veh] ~= nil and not JackstandBusy end,
        onSelect    = function() VPChopJackstandLowerCar(veh) end,
    }
    for i = 1, #wheelSlots do
        local w   = wheelSlots[i]
        local wKey = w.key
        local wIdx = w.idx
        local def  = ChopParts and ChopParts[wKey]
        local lbl  = (def and L(def.labelKey)) or wKey
        targets[#targets + 1] = {
            name        = 'vp_chop_jack_tyre_' .. wKey .. '_' .. tostring(veh),
            label       = L('tyremission_steal_label') .. ' - ' .. lbl,
            icon        = 'fa-solid fa-circle',
            distance    = 2.5,
            canInteract = function()
                -- wheel already removed when offset > 300 (we set 9999999.0)
                return JackstandData[veh] ~= nil
                    and not JackstandBusy
                    and GetVehicleWheelXOffset(veh, wIdx) < 300
            end,
            onSelect = function() VPChopJackstandStealTyre(veh, wKey, wIdx) end,
        }
    end

    -- Fase 2/3/4: desmanche avançado (requer Config.AdvancedChop.Enable)
    if Config.AdvancedChop and Config.AdvancedChop.Enable then
        local netId = NetworkGetNetworkIdFromEntity(veh)

        -- Fase 2: portas / capô / porta-malas (bone-based, requer serra)
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
            local def   = ChopParts[aKey]
            local lbl   = def and L(def.labelKey) or aKey
            targets[#targets + 1] = {
                name     = 'vp_adv_chop_' .. aKey .. '_' .. tostring(veh),
                label    = L('adv_target_door_fmt', lbl),
                icon     = 'fa-solid fa-screwdriver-wrench',
                bones    = { aBone },
                distance = 2.0,
                canInteract = function()
                    return JackstandData[veh] ~= nil and not advIsChopped(netId, aKey)
                end,
                onSelect = function() doAdvChopPart(veh, netId, aKey) end,
            }
        end

        -- Fase 3: motor (requer capô removido + chave de fenda)
        targets[#targets + 1] = {
            name     = 'vp_adv_chop_engine_' .. tostring(veh),
            label    = L('adv_target_engine'),
            icon     = 'fa-solid fa-gear',
            bones    = { 'engine' },
            distance = 2.0,
            canInteract = function()
                return JackstandData[veh] ~= nil
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
            distance = 3.0,
            canInteract = function()
                return JackstandData[veh] ~= nil
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
                    anim         = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 49 },
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

function VPChopJackstandStealTyre(veh, partKey, tyreIdx)
    if JackstandBusy then return end
    JackstandBusy = true
    -- Explicit CreateThread: função contém Wait() via VPChopSpawnTyreProp + VPTyreSpawnWheelPropInHand.
    -- Garante coroutine context independente de como ox_target dispatcha onSelect.
    CreateThread(function()
        local jmg    = Config.Jackstand and Config.Jackstand.Minigame
        local passed = VPChopRunBoltMinigame(jmg)
        if not passed then JackstandBusy = false; return end
        local okp = lib.progressBar({
            duration = 4000, label = L('tyremission_pulling_tyre'),
            useWhileDead = false, canCancel = true,
            disable = { move = true, car = true, combat = true },
            anim = { dict = 'anim@heists@box_carry@', clip = 'idle', flag = 49 },
        })
        -- [FIX H-4] Mover o reset do mutex para DEPOIS das operações assíncronas.
        -- O reset antecipado aqui permitia que uma segunda chamada entrasse enquanto
        -- VPChopSpawnTyreProp / VPTyreSpawnWheelPropInHand ainda estavam em execução.
        if not okp then JackstandBusy = false; return end
        -- visually remove the wheel (same as wheel_theft resource)
        SetVehicleWheelXOffset(veh, tyreIdx, 9999999.0)
        -- give tyre item to player inventory
        TriggerServerEvent('vp_chopshop:tyres:jackstandTyreStolen')
        -- Spawnar prop de pneu no chão na posição da roda (para truck loading via ox_target)
        local boneIdx = GetEntityBoneIndexByName(veh, partKey)
        if boneIdx and boneIdx >= 0 then
            local wheelPos = GetWorldPositionOfEntityBone(veh, boneIdx)
            VPChopSpawnTyreProp(wheelPos)
        end
        JackstandBusy = false
    end)
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
    local ok = lib.progressBar({
        duration = jcfg.LiftProgressMs or 8000, label = L('jackstand_progress_raise'),
        useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 49 },
    })
    if not ok then JackstandBusy = false; return end
    local props = spawnJackstandProps(best)
    local origZ = doLiftVehicle(best)
    Wait(350)
    attachJackstandsToCar(best, props)
    JackstandData[best] = { props = props, originalZ = origZ }
    JackstandBusy = false
    addRaisedCarTargets(best)
    VPChopNotify(L('jackstand_raised'), 'success')
end

function VPChopJackstandLowerCar(veh)
    local data = JackstandData[veh]
    if not data then return end
    if JackstandBusy then VPChopNotify(L('jackstand_busy'), 'error'); return end
    JackstandBusy = true
    local ok = lib.progressBar({
        duration = (Config.Jackstand and Config.Jackstand.LowerProgressMs) or 5000,
        label = L('jackstand_progress_lower'), useWhileDead = false, canCancel = false,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 49 },
    })
    if not ok then JackstandBusy = false; return end
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
