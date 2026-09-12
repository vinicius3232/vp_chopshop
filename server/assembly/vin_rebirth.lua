-- server/assembly/vin_rebirth.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.21 P7.7] VIN REBIRTH & CIVIL REGISTRATION CONNECTOR
--  Emissão de nova identidade civil limpa (placa e VIN) para veículos montados
--  a partir de chassi salvage. Registra o veículo como entidade legalizada no
--  banco de dados do framework (qbx_vehicles / player_vehicles).
-- ═══════════════════════════════════════════════════════════════════════════════

VINRebirth = VINRebirth or {}

local _mock = nil

local CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' -- Sem O/I/0/1 para legibilidade forense

local function randChar()
    local idx = math.random(1, #CHARS)
    return CHARS:sub(idx, idx)
end

--- Gera uma nova placa limpa de 8 caracteres
---@return string plate
function VINRebirth.GenerateCleanPlate()
    if _mock and _mock.GenerateCleanPlate then
        return _mock.GenerateCleanPlate()
    end

    local p = {}
    for i = 1, 8 do
        p[i] = randChar()
    end
    return table.concat(p)
end

--- Gera um novo VIN limpo de 17 caracteres no padrão ISO
---@return string vin
function VINRebirth.GenerateCleanVIN()
    if _mock and _mock.GenerateCleanVIN then
        return _mock.GenerateCleanVIN()
    end

    local prefix = (Config and Config.Rebuild and Config.Rebuild.VinPrefix) or '1G4VP'
    local needed = 17 - #prefix
    local s = { prefix }
    for i = 1, needed do
        table.insert(s, randChar())
    end
    return table.concat(s)
end

--- Registra o veículo montado como propriedade legalizada do jogador no framework
---@param src number
---@param project table { chassisModel: string, chassisSerial: string, installedParts: table }
---@return table { ok: boolean, err?: string, plate?: string, vin?: string, model?: string }
function VINRebirth.RegisterVehicle(src, project)
    if not src or type(src) ~= 'number' or src <= 0 then
        return { ok = false, err = 'invalid_source' }
    end
    if not project or not project.chassisModel then
        return { ok = false, err = 'invalid_project' }
    end

    if _mock and _mock.RegisterVehicle then
        return _mock.RegisterVehicle(src, project)
    end

    local citizenid = (type(ServerChopPlayerKey) == 'function' and ServerChopPlayerKey(src)) or tostring(src)
    local plate = VINRebirth.GenerateCleanPlate()
    local vin = VINRebirth.GenerateCleanVIN()

    local defaultProps = {
        plate        = plate,
        model        = project.chassisModel,
        engineHealth = 1000.0,
        bodyHealth   = 1000.0,
        fuelLevel    = 100.0,
    }

    -- Delega à bridge veicular para inserção no qbx_vehicles / player_vehicles
    local okReg, errReg, vehId = false, 'bridge_unavailable', nil
    if type(BridgeRegisterCivilVehicle) == 'function' then
        okReg, errReg, vehId = BridgeRegisterCivilVehicle(citizenid, project.chassisModel, plate, vin, defaultProps)
    end

    if not okReg then
        return { ok = false, err = errReg or 'civil_registration_failed' }
    end

    -- Notifica via smartphone se disponível
    local PB = rawget(_G, 'PhoneBridge')
    if PB and PB.IsAvailable and PB.IsAvailable() then
        local msg = ('Seu projeto de montagem veicular foi homologado! Veículo %s registrado com a placa %s.'):format(project.chassisModel:upper(), plate)
        PB.SendNotification(src, 'Detran / Emissão Civil', msg, {
            icon = 'certificate',
            duration = 10000,
        })
    end

    return {
        ok        = true,
        plate     = plate,
        vin       = vin,
        model     = project.chassisModel,
        citizenid = citizenid,
        vehicleId = vehId,
    }
end

function VINRebirth.__setMock(mock)
    _mock = mock
end

return VINRebirth
