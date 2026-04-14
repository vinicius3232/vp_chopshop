---@param src number
---@param coords vector3
---@param maxDist number
---@return boolean
function ValidatePlayerNearPoint(src, coords, maxDist)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local pcoords = GetEntityCoords(ped)
    return #(pcoords - coords) <= maxDist
end

---@param src number
---@param coords vector3
---@return boolean
function ValidatePlayerNearCoords(src, coords)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local pcoords = GetEntityCoords(ped)
    -- Margem extra: jogador trabalha a pé ao lado do carro, pode ficar até ~5m do centro do elevador
    return #(pcoords - coords) <= (Config.VehicleNearLiftRadius + 1.0)
end

---@param src number
---@param coords vector3
---@return boolean
function ValidatePlayerPlacementRange(src, coords)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local pcoords = GetEntityCoords(ped)
    return #(pcoords - coords) <= Config.MaxPlaceDistance
end

-- [M3 FIX] ValidateVehicleNearLift removida — lift system removido; função nunca chamada.

---@param src number
---@param vehicleEntity integer
---@param maxDist number
---@return boolean
function ValidatePlayerNearVehicle(src, vehicleEntity, maxDist)
    if not vehicleEntity or vehicleEntity == 0 or not DoesEntityExist(vehicleEntity) then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local pcoords = GetEntityCoords(ped)
    local vcoords = GetEntityCoords(vehicleEntity)
    return #(pcoords - vcoords) <= maxDist
end
