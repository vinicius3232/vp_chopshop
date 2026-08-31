-- client/minigame/profiles/engine.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-D] Engine Profile — Perfil de Desmanche Físico do Bloco do Motor
--  Define câmera contextual focada no cofre e 4 pontos de desacoplamento mecânico
--  (calços e suportes estruturais do motor) usando a parafusadeira (mechanic_drill).
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}
local Proj = _G.VPChopProjection

local EngineProfile = {}

--- Helper para obter o centro do cofre do motor e vetores locais
local function resolveEngineData(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return -1, vector3(0, 0, 0), 1.0, vector3(0, 1, 0), vector3(1, 0, 0), vector3(0, 0, 1)
    end

    local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, 'engine')
    if boneId == -1 then
        -- Tenta o bone 'bonnet' como âncora alternativa
        local bonnetId = GetEntityBoneIndexByName(vehicle, 'bonnet')
        if bonnetId ~= -1 then
            bonePos = GetWorldPositionOfEntityBone(vehicle, bonnetId) - (up * 0.20)
            boneId = bonnetId
        else
            -- Generic geometry fallback
            bonePos = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 1.4, 0.4)
        end
    end

    return boneId, bonePos, sideSign, fwd, rightV, up
end

local function calculateEngineCamera(vehicle, boneKey)
    local _, bayCenter, _, fwd, rightV, up = resolveEngineData(vehicle)
    -- Câmera elevada frontal/lateral olhando para o interior do cofre,
    -- enquadrando o ped inclinado sobre a grade com a parafusadeira na mão
    local camPos = bayCenter + (up * 1.10) + (fwd * 0.40) - (rightV * 0.35)
    local lookAt = bayCenter - (up * 0.05)
    return camPos, lookAt
end

local function generateEnginePoints(vehicle, boneKey)
    local _, bayCenter, _, fwd, rightV, up = resolveEngineData(vehicle)
    local points = {}

    -- 1: Calço Dianteiro Esquerdo (Fixação ao subchassi / longarina esq)
    points[#points + 1] = {
        id = 'eng_mount_fl',
        primitive = 'drill',
        worldPos = bayCenter + (rightV * -0.30) + (fwd * 0.25) + (up * 0.04),
        label = 'CALÇO DIANT. ESQ',
        holdTimeMs = 1600.0,
    }

    -- 2: Calço Dianteiro Direito (Fixação ao subchassi / longarina dir)
    points[#points + 1] = {
        id = 'eng_mount_fr',
        primitive = 'drill',
        worldPos = bayCenter + (rightV * 0.30) + (fwd * 0.25) + (up * 0.04),
        label = 'CALÇO DIANT. DIR',
        holdTimeMs = 1600.0,
    }

    -- 3: Suporte Traseiro Esquerdo / Transmissão
    points[#points + 1] = {
        id = 'eng_mount_rl',
        primitive = 'drill',
        worldPos = bayCenter + (rightV * -0.26) - (fwd * 0.28) - (up * 0.02),
        label = 'SUPORTE TRAS. ESQ',
        holdTimeMs = 1600.0,
    }

    -- 4: Suporte Traseiro Direito / Transmissão
    points[#points + 1] = {
        id = 'eng_mount_rr',
        primitive = 'drill',
        worldPos = bayCenter + (rightV * 0.26) - (fwd * 0.28) - (up * 0.02),
        label = 'SUPORTE TRAS. DIR',
        holdTimeMs = 1600.0,
    }

    return points
end

Profiles.list.engine = {
    title = 'DESACOPLAMENTO DO MOTOR',
    helpText = 'Solte os calços estruturais e suportes com a parafusadeira',
    toolClass = 'screw',
    fov = 44.0,
    minUxMs = 3500,
    reserveMs = 3500,
    calculateCamera = calculateEngineCamera,
    generatePoints = generateEnginePoints,
}

Profiles.list.adv_engine = Profiles.list.engine

EngineProfile.resolveEngineData = resolveEngineData
return EngineProfile
