--- Hostile encounter at a lift (pistol / dog / bat): random per dismantle and/or **NPC mission** (next dismantle forced).
--- [REMOVED] lift-based validation: substituída por validação via NetworkGetEntityFromNetworkId(netId).

local LastAmbushAt = {} ---@type table<string, number>
local AmbushPeds = {} ---@type table<number, integer[]>
--- Foreman mission: next dismantle triggers ambush once before this unix time (key = ServerChopPlayerKey).
local MissionAmbushPendingUntil = {} ---@type table<string, number>
local LastNpcMissionAccept = {} ---@type table<string, number>

---@param src number
---@return boolean
local function ambushPedsAlive(src)
    local list = AmbushPeds[src]
    if not list then return false end
    for _, h in ipairs(list) do
        if h and h ~= 0 and DoesEntityExist(h) then return true end
    end
    return false
end

---@param src number
local function clearAmbushList(src)
    AmbushPeds[src] = nil
end

---@param src number
---@param peds integer[]
local function rememberPeds(src, peds)
    AmbushPeds[src] = peds
    local despawn = (Config.Ambush and Config.Ambush.DespawnMs) or 180000
    CreateThread(function()
        Wait(despawn)
        local list = AmbushPeds[src]
        if not list then return end
        for _, h in ipairs(list) do
            if h and h ~= 0 and DoesEntityExist(h) then
                DeleteEntity(h)
            end
        end
        if AmbushPeds[src] == list then AmbushPeds[src] = nil end
    end)
end

---@param modelHash integer
---@param x number
---@param y number
---@param z number
---@param heading number
---@return integer|nil
local function spawnHostile(modelHash, x, y, z, heading)
    local ped = CreatePed(4, modelHash, x, y, z, heading, true, true)
    if not ped or ped == 0 then return nil end
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedCanRagdoll(ped, true)
    SetPedArmour(ped, 0)
    SetPedAccuracy(ped, (Config.Ambush and Config.Ambush.ShooterAccuracy) or 35)
    SetPedCombatMovement(ped, 2)
    SetPedCombatAbility(ped, 1)
    return ped
end

---@param cfg table
---@return 'pistol'|'dog'|'bat'
local function pickAmbushKind(cfg)
    local w = cfg.KindWeights
    if type(w) ~= 'table' then
        local roll = math.random(1, 3)
        if roll == 1 then return 'pistol' elseif roll == 2 then return 'dog' else return 'bat' end
    end
    local p = math.max(0.0, tonumber(w.pistol) or 0.0)
    local d = math.max(0.0, tonumber(w.dog) or 0.0)
    local b = math.max(0.0, tonumber(w.bat) or 0.0)
    local sum = p + d + b
    if sum < 1e-6 then
        local roll = math.random(1, 3)
        if roll == 1 then return 'pistol' elseif roll == 2 then return 'dog' else return 'bat' end
    end
    local r = math.random() * sum
    if r < p then return 'pistol' end
    r = r - p
    if r < d then return 'dog' end
    return 'bat'
end

---@param src number
---@param netId integer
---@param cfg table
---@return 'pistol'|'dog'|'bat'|nil kind
---@return integer|nil ped
local function ambushSpawnOne(src, netId, cfg)
    netId = tonumber(netId)
    if not netId then return nil, nil end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) then return nil, nil end

    local victimPed = GetPlayerPed(src)
    if not victimPed or victimPed == 0 then return nil, nil end

    local maxDist = (Config.VehicleNearLiftRadius or 5.0) + 2.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then return nil, nil end

    if ambushPedsAlive(src) then return nil, nil end

    local kind = pickAmbushKind(cfg) ---@type 'pistol'|'dog'|'bat'

    local vc = GetEntityCoords(victimPed)
    local vx, vy, vz = vc.x, vc.y, vc.z
    local heading = GetEntityHeading(victimPed)
    local rad = math.rad(heading)
    local back = (cfg.SpawnBehindM or 7.0) + 0.0
    local sx = vx - math.sin(rad) * back
    local sy = vy + math.cos(rad) * back
    local sz = vz + 0.85
    local _, gz = GetGroundZFor_3dCoord(sx, sy, sz + 3.0, false)
    if gz then sz = gz + 1.0 end

    local spawnHeading = (heading + 180.0) % 360.0
    local modelHash ---@type integer
    local ped ---@type integer|nil

    if kind == 'dog' then
        local dogs = cfg.DogModels or { `a_c_chop` }
        modelHash = dogs[math.random(1, #dogs)]
        ped = spawnHostile(modelHash, sx, sy, sz, spawnHeading)
        if ped then TaskCombatPed(ped, victimPed, 0, 16) end
    else
        local humans = cfg.HumanModels or { `g_m_y_mexgoon_03` }
        modelHash = humans[math.random(1, #humans)]
        ped = spawnHostile(modelHash, sx, sy, sz, spawnHeading)
        if ped then
            if kind == 'pistol' then
                GiveWeaponToPed(ped, joaat('WEAPON_PISTOL'), 80, false, true)
                SetCurrentPedWeapon(ped, joaat('WEAPON_PISTOL'), true)
            else
                GiveWeaponToPed(ped, joaat('WEAPON_BAT'), 1, false, true)
                SetCurrentPedWeapon(ped, joaat('WEAPON_BAT'), true)
            end
            TaskCombatPed(ped, victimPed, 0, 16)
        end
    end

    if ped and ped ~= 0 then
        rememberPeds(src, { ped })
        TriggerClientEvent('vp_chopshop:client:ambushWarn', src, kind)

        -- Chance de dropar fence_referral ao matar o ped de emboscada
        local dropChance = tonumber(cfg.ReferralDropChance) or 0.0
        if dropChance > 0 and math.random() <= dropChance then
            CreateThread(function()
                local despawnMs = tonumber(cfg.DespawnMs) or 180000
                local elapsed   = 0
                while elapsed < despawnMs do
                    Wait(2000)
                    elapsed = elapsed + 2000
                    if ped and ped ~= 0 and DoesEntityExist(ped) and IsEntityDead(ped) then
                        if not GetPlayerName(src) then return end
                        exports.ox_inventory:AddItem(src, 'fence_referral', 1)
                        TriggerClientEvent('ox_lib:notify', src, {
                            title='Dica', description='Encontrou algo no bolso do cara. Verifique o inventário.', type='inform', duration=5000
                        })
                        return
                    end
                end
            end)
        end

        return kind, ped
    end
    return nil, nil
end

---@param src number
---@return table ok: boolean, err?: string, wait?: number
function VPChopNpcMissionAccept(src)
    local m = Config.NPC and Config.NPC.Mission
    if not m or not m.Enable then return { ok = false, err = 'disabled' } end
    if not Config.NPC or not Config.NPC.Enable then return { ok = false, err = 'disabled' } end

    local amb = Config.Ambush
    if not amb or not amb.Enable then return { ok = false, err = 'ambush_off' } end

    local c = Config.NPC.Coords
    local npos = vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0)
    if not ValidatePlayerNearPoint(src, npos, 3.0) then return { ok = false, err = 'distance' } end

    local key = ServerChopPlayerKey(src)
    local now = os.time()
    local pendingUntil = MissionAmbushPendingUntil[key]
    if pendingUntil and now < pendingUntil then return { ok = false, err = 'active' } end

    local cdM = math.floor(tonumber(m.CooldownSeconds) or 600)
    if cdM > 0 and LastNpcMissionAccept[key] and (now - LastNpcMissionAccept[key]) < cdM then
        return { ok = false, err = 'cooldown', wait = cdM - (now - LastNpcMissionAccept[key]) }
    end

    local ttl = math.floor(tonumber(m.PendingExpireSeconds) or 900)
    if ttl < 60 then ttl = 60 end

    MissionAmbushPendingUntil[key] = now + ttl
    LastNpcMissionAccept[key] = now
    return { ok = true }
end

--- Dispara emboscada baseada no netId e placa do veículo.
--- plate usado para multiplicar chance via sistema de heat.
---@param src number
---@param netId integer
---@param plate string
function VPChopAmbushMaybe(src, netId, plate)
    local cfg = Config.Ambush
    if not cfg or not cfg.Enable then return end

    -- Multiplicador de heat: veículos quentes = mais emboscadas
    local heatMult = (plate and plate ~= '') and VPChopHeatGetMultiplier(plate) or 1.0

    netId = tonumber(netId)
    if not netId then return end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) then return end

    local maxDist = (Config.VehicleNearLiftRadius or 5.0) + 2.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then return end

    if ambushPedsAlive(src) then return end

    local key = ServerChopPlayerKey(src)
    local now = os.time()
    local pendingUntil = MissionAmbushPendingUntil[key]

    if pendingUntil then
        if now >= pendingUntil then
            MissionAmbushPendingUntil[key] = nil
        else
            MissionAmbushPendingUntil[key] = nil
            local m = Config.NPC and Config.NPC.Mission
            local mChance = m and tonumber(m.AmbushChance)
            if mChance == nil then mChance = 1.0 end
            if mChance < 0.0 then mChance = 0.0 elseif mChance > 1.0 then mChance = 1.0 end
            if math.random() <= mChance then
                LastAmbushAt[key] = now
                ambushSpawnOne(src, netId, cfg)
            end
            return
        end
    end

    if not cfg.RandomOnDismantle then return end

    local cd = tonumber(cfg.CooldownSeconds) or 300
    if LastAmbushAt[key] and (now - LastAmbushAt[key]) < cd then return end

    local chance = (tonumber(cfg.Chance) or 0.07) * heatMult
    if chance < 0.001 or math.random() > chance then return end

    LastAmbushAt[key] = now
    ambushSpawnOne(src, netId, cfg)
end

AddEventHandler('playerDropped', function()
    local src = source
    local list = AmbushPeds[src]
    if list then
        for _, h in ipairs(list) do
            if h and h ~= 0 and DoesEntityExist(h) then
                DeleteEntity(h)
            end
        end
    end
    clearAmbushList(src)
    local key = ServerChopPlayerKey(src)
    MissionAmbushPendingUntil[key] = nil
    -- [FIX W-03] LastNpcMissionAccept nunca era limpo no disconnect — memory leak
    LastNpcMissionAccept[key] = nil
    -- [FIX W-04] LastAmbushAt também nunca era limpo no disconnect pelo mesmo motivo
    LastAmbushAt[key] = nil
end)
