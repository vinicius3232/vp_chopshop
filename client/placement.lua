local function rotationToDirection(rot)
    local z = math.rad(rot.z)
    local x = math.rad(rot.x)
    local num = math.abs(math.cos(x))
    return vector3(-math.sin(z) * num, math.cos(z) * num, math.sin(x))
end

local function raycastFromCamera(dist)
    local camRot = GetGameplayCamRot(2)
    local camPos = GetGameplayCamCoord()
    local dir = rotationToDirection(camRot)
    local dest = camPos + dir * dist
    local handle = StartShapeTestRay(camPos.x, camPos.y, camPos.z, dest.x, dest.y, dest.z, 1 + 16, PlayerPedId(), 7)
    local _, hit, endCoords = GetShapeTestResult(handle)
    return hit == 1, endCoords
end

---@param modelHash integer|string
---@param callbackName string
---@return boolean
local function ghostPlace(modelHash, callbackName)
    local loaded = lib.requestModel(modelHash, 8000)
    if not loaded then
        VPChopNotify(L('notify_model_unavailable'), 'error')
        SetModelAsNoLongerNeeded(modelHash)
        return false
    end
    local preview ---@type integer|nil
    local heading = GetEntityHeading(PlayerPedId())
    lib.showTextUI(L('placement_textui'))

    local function cleanup()
        lib.hideTextUI()
        if preview and DoesEntityExist(preview) then
            DeleteObject(preview)
        end
        SetModelAsNoLongerNeeded(modelHash)
    end

    while true do
        Wait(16)
        local hit, pos = raycastFromCamera(14.0)
        if hit and pos then
            if not preview or not DoesEntityExist(preview) then
                preview = CreateObject(modelHash, pos.x, pos.y, pos.z, false, false, false)
                SetEntityAlpha(preview, 150, false)
                SetEntityCollision(preview, false, false)
                FreezeEntityPosition(preview, true)
            else
                SetEntityCoords(preview, pos.x, pos.y, pos.z, false, false, false, false)
                SetEntityHeading(preview, heading)
            end
        end
        if IsControlPressed(0, 14) then heading = heading + 2.0 end
        if IsControlPressed(0, 15) then heading = heading - 2.0 end
        if IsControlJustPressed(0, 38) then
            if preview and DoesEntityExist(preview) then
                local c = GetEntityCoords(preview)
                cleanup()
                local cbOk, res = pcall(lib.callback.await, callbackName, false, { x = c.x, y = c.y, z = c.z, heading = heading })
                if not cbOk then res = nil end
                if res and res.ok then
                    VPChopNotify(L('notify_installed'), 'success')
                    return true
                end
                VPChopNotify(
                    (res and res.err) and L('notify_place_failed_fmt', VPChopLocaleErr(res.err)) or L('notify_unauthorized'),
                    'error'
                )
                return false
            end
        end
        -- [FIX M-4] Só cancela o placement com X se o jogador NÃO estiver carregando uma peça
        -- (VPChopCarryingPart está definido em client/main.lua como global).
        -- Sem este guard, o X key era consumido por ambas as loops simultaneamente.
        if IsControlJustPressed(0, 73) and not VPChopCarryingPart then
            cleanup()
            return false
        end
    end
end

-- [M2 FIX] VPChopStartLiftPlacement removida — elevador removido do sistema (Config.LiftBaseModel = nil).

function VPChopStartBenchPlacement()
    return ghostPlace(Config.BenchModel, 'vp_chopshop:placeBench')
end

function VPChopStartWelderPlacement()
    return ghostPlace(Config.WelderModel, 'vp_chopshop:placeWelder')
end
