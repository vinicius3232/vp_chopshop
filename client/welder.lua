WelderEntities = WelderEntities or {}

local function clearWelder(id)
    local ent = WelderEntities[id]
    if ent and DoesEntityExist(ent) then
        exports.ox_target:removeLocalEntity(ent)
        DeleteEntity(ent)
    end
    WelderEntities[id] = nil
end

local function resolveModel(modelName, fallback)
    local hash = type(modelName) == 'number' and modelName or GetHashKey(modelName)
    if type(IsModelInCdimage) == 'function' and not IsModelInCdimage(hash) then
        return type(fallback) == 'number' and fallback or GetHashKey(fallback)
    end
    return hash
end

---@param welder { id: integer, x: number, y: number, z: number, heading: number }
function VPChopUpsertWelder(welder)
    clearWelder(welder.id)
    CreateThread(function()
        local hash = resolveModel(Config.WelderModel, 'prop_compressor_02')
        lib.requestModel(hash, 8000)

        local x, y, z = welder.x, welder.y, welder.z
        local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 50.0, false)
        local spawnZ = found and groundZ or z

        local ent = CreateObject(hash, x, y, spawnZ, false, false, false)
        if not ent or ent == 0 then
            SetModelAsNoLongerNeeded(hash)
            return
        end
        SetEntityHeading(ent, welder.heading + 0.0)
        FreezeEntityPosition(ent, true)
        SetEntityAsMissionEntity(ent, true, true)
        WelderEntities[welder.id] = ent
        SetModelAsNoLongerNeeded(hash)

        exports.ox_target:addLocalEntity(ent, {
            {
                name = ('vp_chop_welder_pickup_%s'):format(welder.id),
                label = L('target_pickup_welder'),
                icon = 'fa-solid fa-hand',
                distance = Config.InteractDistance,
                canInteract = function()
                    return GetVehiclePedIsIn(cache.ped, false) == 0
                end,
                onSelect = function()
                    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:pickupWelder', false, welder.id)
                    if not cbOk then res = nil end
                    if res and res.ok then
                        VPChopNotify(L('notify_installed'), 'success')
                    else
                        VPChopNotify(
                            (res and res.err) and L('notify_chop_failed_fmt', VPChopLocaleErr(res.err)) or L('notify_generic_error'),
                            'error'
                        )
                    end
                end,
            },
        })
    end)
end

function VPChopRemoveWelder(id)
    clearWelder(id)
end
