-- ─── Validação de coordenadas do mapa GTA V ──────────────────────────────────
-- Rejeita coords fora dos limites do mapa para prevenir exploits de teleporte.
local GTA_MAP_X_MIN, GTA_MAP_X_MAX = -4500.0,  4500.0
local GTA_MAP_Y_MIN, GTA_MAP_Y_MAX = -4500.0,  8500.0
local GTA_MAP_Z_MIN, GTA_MAP_Z_MAX = -300.0,   2500.0

---@param coords vector3
---@return boolean
function ValidateMapCoords(coords)
    if type(coords) ~= 'vector3' then return false end
    return coords.x >= GTA_MAP_X_MIN and coords.x <= GTA_MAP_X_MAX
       and coords.y >= GTA_MAP_Y_MIN and coords.y <= GTA_MAP_Y_MAX
       and coords.z >= GTA_MAP_Z_MIN and coords.z <= GTA_MAP_Z_MAX
end

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
    return #(pcoords - coords) <= ((tonumber(Config.VehicleNearLiftRadius) or 4.2) + 1.0)
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
