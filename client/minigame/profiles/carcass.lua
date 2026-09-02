-- client/minigame/profiles/carcass.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-E] Carcass Profile — Perfil de Corte Estrutural da Carcaça
--  Define câmera enquadrando a estrutura geral do veículo e 5 linhas de corte
--  estrutural do chassi (polylines com primitive 'trace') utilizando maçarico/solda.
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}

local CarcassProfile = {}

--- Helper para obter dimensões do modelo e centros do veículo
local function resolveCarcassData(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return vector3(-1.0, -2.5, -0.5), vector3(1.0, 2.5, 1.0), 2.0, 5.0, 1.5, vector3(0, 0, 0)
    end

    local minDim, maxDim = nil, nil
    if type(GetModelDimensions) == 'function' then
        local model = GetEntityModel(vehicle)
        minDim, maxDim = GetModelDimensions(model)
    end
    if not minDim or not maxDim then
        minDim = vector3(-1.0, -2.5, -0.5)
        maxDim = vector3(1.0, 2.5, 1.0)
    end

    local w   = maxDim.x - minDim.x
    local len = maxDim.y - minDim.y
    local h   = maxDim.z - minDim.z
    local cLocal = (minDim + maxDim) * 0.5

    return minDim, maxDim, w, len, h, cLocal
end

local function getOffset(vehicle, x, y, z)
    if type(GetOffsetFromEntityInWorldCoords) == 'function' then
        return GetOffsetFromEntityInWorldCoords(vehicle, x, y, z)
    end
    return vector3(x or 0, y or 0, z or 0)
end

local function calculateCarcassCamera(vehicle, boneKey)
    local minDim, maxDim, w, len, h, cLocal = resolveCarcassData(vehicle)
    -- Câmera em perspectiva três-quartos elevada, enquadrando o chassi e o ped trabalhando
    local camPos = getOffset(vehicle, -w * 0.95, -len * 0.45, maxDim.z + 1.25)
    local lookAt = getOffset(vehicle, 0.0, 0.0, minDim.z + (h * 0.35))
    return camPos, lookAt
end

local function generateCarcassPoints(vehicle, boneKey)
    local minDim, maxDim, w, len, h, cLocal = resolveCarcassData(vehicle)
    local sections = {}

    -- 1: Travessa Dianteira (Radiador e Longarinas Frontais)
    sections[#sections + 1] = {
        id = 'carcass_crossmember_f',
        primitive = 'trace',
        label = '1. TRAVESSA DIANT.',
        points = {
            getOffset(vehicle, -w * 0.35, maxDim.y - 0.20, minDim.z + 0.35),
            getOffset(vehicle, 0.0, maxDim.y - 0.10, minDim.z + 0.38),
            getOffset(vehicle, w * 0.35, maxDim.y - 0.20, minDim.z + 0.35),
        }
    }

    -- 2: Colunas e Caixa de Ar Esquerda (Soleira e Coluna A/B)
    sections[#sections + 1] = {
        id = 'carcass_pillar_l',
        primitive = 'trace',
        label = '2. COLUNA LATERAL ESQ.',
        points = {
            getOffset(vehicle, -w * 0.45, cLocal.y + (len * 0.22), minDim.z + 0.45),
            getOffset(vehicle, -w * 0.47, cLocal.y - (len * 0.04), minDim.z + 0.48),
            getOffset(vehicle, -w * 0.45, cLocal.y - (len * 0.28), minDim.z + 0.48),
        }
    }

    -- 3: Colunas e Caixa de Ar Direita (Soleira e Coluna A/B)
    sections[#sections + 1] = {
        id = 'carcass_pillar_r',
        primitive = 'trace',
        label = '3. COLUNA LATERAL DIR.',
        points = {
            getOffset(vehicle, w * 0.45, cLocal.y + (len * 0.22), minDim.z + 0.45),
            getOffset(vehicle, w * 0.47, cLocal.y - (len * 0.04), minDim.z + 0.48),
            getOffset(vehicle, w * 0.45, cLocal.y - (len * 0.28), minDim.z + 0.48),
        }
    }

    -- 4: Túnel Central / Assoalho do Chassi
    sections[#sections + 1] = {
        id = 'carcass_floor_cross',
        primitive = 'trace',
        label = '4. TÚNEL DO ASSOALHO',
        points = {
            getOffset(vehicle, -w * 0.32, cLocal.y - (len * 0.05), minDim.z + 0.28),
            getOffset(vehicle, 0.0, cLocal.y - (len * 0.06), minDim.z + 0.34),
            getOffset(vehicle, w * 0.32, cLocal.y - (len * 0.05), minDim.z + 0.28),
        }
    }

    -- 5: Longarina Traseira e Caixa de Roda
    sections[#sections + 1] = {
        id = 'carcass_crossmember_r',
        primitive = 'trace',
        label = '5. LONGARINA TRAS.',
        points = {
            getOffset(vehicle, -w * 0.36, minDim.y + 0.25, minDim.z + 0.38),
            getOffset(vehicle, 0.0, minDim.y + 0.15, minDim.z + 0.40),
            getOffset(vehicle, w * 0.36, minDim.y + 0.25, minDim.z + 0.38),
        }
    }

    return sections
end

local function focusCarcassPoint(vehicle, pointId)
    local minDim, maxDim, w, len, h, cLocal = resolveCarcassData(vehicle)
    local camPos, lookAt, fov = nil, nil, 42.0

    if pointId == 'carcass_crossmember_f' then
        -- 1. Travessa Dianteira: enquadramento frontal elevado
        camPos = getOffset(vehicle, -w * 0.90, maxDim.y + 1.10, maxDim.z + 1.15)
        lookAt = getOffset(vehicle, 0.0, maxDim.y - 0.10, minDim.z + 0.35)
        fov = 44.0
    elseif pointId == 'carcass_pillar_l' then
        -- 2. Coluna Lateral Esq: enquadramento lateral esquerdo elevado
        camPos = getOffset(vehicle, -w * 1.45, cLocal.y - (len * 0.05), maxDim.z + 1.05)
        lookAt = getOffset(vehicle, -w * 0.45, cLocal.y - (len * 0.04), minDim.z + 0.45)
        fov = 44.0
    elseif pointId == 'carcass_pillar_r' then
        -- 3. Coluna Lateral Dir: enquadramento lateral direito elevado
        camPos = getOffset(vehicle, w * 1.45, cLocal.y - (len * 0.05), maxDim.z + 1.05)
        lookAt = getOffset(vehicle, w * 0.45, cLocal.y - (len * 0.04), minDim.z + 0.45)
        fov = 44.0
    elseif pointId == 'carcass_floor_cross' then
        -- 4. Túnel do Assoalho: enquadramento superior do interior do assoalho
        camPos = getOffset(vehicle, -w * 1.05, cLocal.y - (len * 0.15), maxDim.z + 1.35)
        lookAt = getOffset(vehicle, 0.0, cLocal.y - (len * 0.06), minDim.z + 0.30)
        fov = 42.0
    elseif pointId == 'carcass_crossmember_r' then
        -- 5. Longarina Traseira: enquadramento traseiro elevado
        camPos = getOffset(vehicle, -w * 0.90, minDim.y - 1.10, maxDim.z + 1.15)
        lookAt = getOffset(vehicle, 0.0, minDim.y + 0.15, minDim.z + 0.38)
        fov = 44.0
    else
        camPos, lookAt = calculateCarcassCamera(vehicle)
        fov = 48.0
    end

    return camPos, lookAt, fov
end

Profiles.list.carcass = {
    title = 'CORTE ESTRUTURAL DA CARCAÇA',
    helpText = 'Segure e acompanhe com o maçarico o traçado das linhas estruturais do chassi',
    toolClass = nil, -- [UX-E.1] Carcaça não exige ferramenta de inventário (gate é a máquina de solda física)
    traceSpeed = 1.0,
    traceTolerance = 55.0,
    fov = 48.0,
    minUxMs = 6000,
    reserveMs = 4000,
    calculateCamera = calculateCarcassCamera,
    focusPoint = focusCarcassPoint,
    generatePoints = generateCarcassPoints,
}

Profiles.list.adv_carcass = Profiles.list.carcass

CarcassProfile.resolveCarcassData = resolveCarcassData
CarcassProfile.focusCarcassPoint = focusCarcassPoint
return CarcassProfile
