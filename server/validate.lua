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

-- ─── Resolução e Validação Centralizada de Entidades de Rede (Server Authority) ──

--- Normaliza e valida estritamente um netId
---@param netId any
---@return integer|nil
function VPChopNormalizeNetId(netId)
    local n = tonumber(netId)
    if not n or n ~= math.floor(n) or n <= 0 or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    return n
end

--- Retorna a entidade se e somente se o netId for válido, existir na rede e for uma entidade FiveM existente.
--- Previne 100% de warnings de console [entity] GetNetworkObject: no object by ID.
---@param netId any
---@return integer|nil entity
function VPChopGetEntityFromNetId(netId)
    local n = VPChopNormalizeNetId(netId)
    if not n then return nil end
    if NetworkDoesEntityExistWithNetworkId and not NetworkDoesEntityExistWithNetworkId(n) then
        return nil
    end
    if not NetworkGetEntityFromNetworkId then return nil end
    local ent = NetworkGetEntityFromNetworkId(n)
    if not ent or ent == 0 or not DoesEntityExist or not DoesEntityExist(ent) then
        return nil
    end
    return ent
end

--- Retorna a entidade se e somente se for um veículo válido no servidor.
---@param netId any
---@return integer|nil vehEntity
function VPChopGetVehicleFromNetId(netId)
    local ent = VPChopGetEntityFromNetId(netId)
    if not ent then return nil end
    if GetEntityType and GetEntityType(ent) ~= 2 then
        return nil
    end
    return ent
end

