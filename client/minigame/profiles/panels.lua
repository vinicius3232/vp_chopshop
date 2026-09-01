-- client/minigame/profiles/panels.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-C] Panel Profiles — Perfis de Desmanche Físico de Painéis da Carroceria
--  Define câmeras e pontos de corte/fixação estruturados para:
--    - bonnet (Capô)
--    - boot (Porta-malas)
--    - door_dside_f / door_pside_f (Portas dianteiras)
--    - door_dside_r / door_pside_r (Portas traseiras)
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}
local Proj = _G.VPChopProjection

local PanelProfiles = {}

--- Helper para obter dados de bone ou fallback genérico se bone não existir
local function resolvePanelBoneData(vehicle, boneKey)
    local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, boneKey)
    if boneId == -1 then
        -- Generic fallback position com base no tipo de peça
        local vCoords = GetEntityCoords(vehicle)
        if boneKey == 'bonnet' then
            bonePos = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 1.5, 0.5)
        elseif boneKey == 'boot' then
            bonePos = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -1.8, 0.5)
        elseif boneKey:find('door') then
            local isRear = boneKey:find('_r') ~= nil
            local yOff = isRear and -0.4 or 0.2
            bonePos = GetOffsetFromEntityInWorldCoords(vehicle, sideSign * 0.9, yOff, 0.0)
        else
            bonePos = vCoords
        end
    end
    return boneId, bonePos, sideSign, fwd, rightV, up
end

-- ─── 1) Portas Dianteiras e Traseiras ──────────────────────────────────────────
local function calculateDoorCamera(vehicle, boneKey)
    local _, bonePos, sideSign, fwd, rightV, up = resolvePanelBoneData(vehicle, boneKey)
    local isRear = boneKey and boneKey:find('_r') ~= nil
    -- Câmera enquadrada mostrando ped com a serra na mão e as dobradiças da porta
    local camPos = bonePos + (rightV * (sideSign * 1.7)) + (up * 0.25) + (fwd * (isRear and -0.15 or 0.15))
    return camPos, bonePos
end

local function generateDoorPoints(vehicle, boneKey)
    local _, bonePos, sideSign, fwd, rightV, up = resolvePanelBoneData(vehicle, boneKey)
    local isRear = boneKey and boneKey:find('_r') ~= nil
    local points = {}

    -- 1: Dobradiça Superior (Corte de sustentação)
    points[#points + 1] = {
        id = 'door_hinge_upper',
        primitive = 'cut',
        worldPos = bonePos + (up * 0.22) + (rightV * (sideSign * 0.04)),
        label = 'DOBRADIÇA SUP',
        holdTimeMs = 2000.0,
    }

    -- 2: Dobradiça Inferior (Corte de sustentação)
    points[#points + 1] = {
        id = 'door_hinge_lower',
        primitive = 'cut',
        worldPos = bonePos - (up * 0.22) + (rightV * (sideSign * 0.04)),
        label = 'DOBRADIÇA INF',
        holdTimeMs = 2000.0,
    }

    -- 3: Trava / Fechadura (Desacoplamento do fecho)
    local latchOffset = isRear and -0.40 or -0.48
    points[#points + 1] = {
        id = 'door_latch',
        primitive = 'cut',
        worldPos = bonePos + (fwd * latchOffset) + (rightV * (sideSign * 0.04)),
        label = 'TRAVA FECHADURA',
        holdTimeMs = 1800.0,
    }

    return points
end

-- ─── 2) Capô (Bonnet) ────────────────────────────────────────────────────────
local function calculateBonnetCamera(vehicle, boneKey)
    local _, bonePos, _, fwd, _, up = resolvePanelBoneData(vehicle, 'bonnet')
    -- Câmera frontal elevada olhando para o capô e o ped trabalhando
    local camPos = bonePos + (fwd * 1.85) + (up * 0.70)
    return camPos, bonePos
end

local function generateBonnetPoints(vehicle, boneKey)
    local _, bonePos, _, fwd, rightV, up = resolvePanelBoneData(vehicle, 'bonnet')
    local points = {}

    -- 1: Dobradiça / Calço Esquerdo
    points[#points + 1] = {
        id = 'bonnet_hinge_l',
        primitive = 'cut',
        worldPos = bonePos - (fwd * 0.25) - (rightV * 0.35) + (up * 0.05),
        label = 'DOBRADIÇA ESQ',
        holdTimeMs = 2200.0,
    }

    -- 2: Dobradiça / Calço Direito
    points[#points + 1] = {
        id = 'bonnet_hinge_r',
        primitive = 'cut',
        worldPos = bonePos - (fwd * 0.25) + (rightV * 0.35) + (up * 0.05),
        label = 'DOBRADIÇA DIR',
        holdTimeMs = 2200.0,
    }

    -- 3: Trava Frontal do Capô
    points[#points + 1] = {
        id = 'bonnet_latch',
        primitive = 'cut',
        worldPos = bonePos + (fwd * 0.45) + (up * 0.02),
        label = 'TRAVA CENTRAL',
        holdTimeMs = 1800.0,
    }

    return points
end

-- ─── 3) Porta-malas (Boot) ───────────────────────────────────────────────────
local function calculateBootCamera(vehicle, boneKey)
    local _, bonePos, _, fwd, _, up = resolvePanelBoneData(vehicle, 'boot')
    -- Câmera traseira elevada enquadrando tampa traseira e o ped
    local camPos = bonePos - (fwd * 1.85) + (up * 0.65)
    return camPos, bonePos
end

local function generateBootPoints(vehicle, boneKey)
    local _, bonePos, _, fwd, rightV, up = resolvePanelBoneData(vehicle, 'boot')
    local points = {}

    -- 1: Dobradiça Esquerda
    points[#points + 1] = {
        id = 'boot_hinge_l',
        primitive = 'cut',
        worldPos = bonePos + (fwd * 0.25) - (rightV * 0.30) + (up * 0.05),
        label = 'DOBRADIÇA ESQ',
        holdTimeMs = 2200.0,
    }

    -- 2: Dobradiça Direita
    points[#points + 1] = {
        id = 'boot_hinge_r',
        primitive = 'cut',
        worldPos = bonePos + (fwd * 0.25) + (rightV * 0.30) + (up * 0.05),
        label = 'DOBRADIÇA DIR',
        holdTimeMs = 2200.0,
    }

    -- 3: Fechadura Traseira
    points[#points + 1] = {
        id = 'boot_latch',
        primitive = 'cut',
        worldPos = bonePos - (fwd * 0.40) + (up * 0.02),
        label = 'FECHADURA',
        holdTimeMs = 1800.0,
    }

    return points
end

-- ─── Definições Individuais Registradas ───────────────────────────────────────
Profiles.list.panel_door_dside_f = {
    title = 'PORTA DIANT. ESQUERDA',
    helpText = 'Corte os fixadores e solte a trava para remover a porta',
    toolClass = 'cut',
    fov = 48.0,
    minUxMs = 3500,
    reserveMs = 3500,
    calculateCamera = calculateDoorCamera,
    generatePoints = generateDoorPoints,
}

Profiles.list.panel_door_pside_f = {
    title = 'PORTA DIANT. DIREITA',
    helpText = 'Corte os fixadores e solte a trava para remover a porta',
    toolClass = 'cut',
    fov = 48.0,
    minUxMs = 3500,
    reserveMs = 3500,
    calculateCamera = calculateDoorCamera,
    generatePoints = generateDoorPoints,
}

Profiles.list.panel_door_dside_r = {
    title = 'PORTA TRAS. ESQUERDA',
    helpText = 'Corte os fixadores e solte a trava para remover a porta',
    toolClass = 'cut',
    fov = 48.0,
    minUxMs = 3500,
    reserveMs = 3500,
    calculateCamera = calculateDoorCamera,
    generatePoints = generateDoorPoints,
}

Profiles.list.panel_door_pside_r = {
    title = 'PORTA TRAS. DIREITA',
    helpText = 'Corte os fixadores e solte a trava para remover a porta',
    toolClass = 'cut',
    fov = 48.0,
    minUxMs = 3500,
    reserveMs = 3500,
    calculateCamera = calculateDoorCamera,
    generatePoints = generateDoorPoints,
}

Profiles.list.panel_bonnet = {
    title = 'DESACOPLAMENTO DO CAPÔ',
    helpText = 'Corte as dobradiças traseiras e destrave o fecho central',
    toolClass = 'cut',
    fov = 46.0,
    minUxMs = 3500,
    reserveMs = 3500,
    calculateCamera = calculateBonnetCamera,
    generatePoints = generateBonnetPoints,
}

Profiles.list.panel_boot = {
    title = 'DESACOPLAMENTO DO PORTA-MALAS',
    helpText = 'Corte as dobradiças e destrave a fechadura traseira',
    toolClass = 'cut',
    fov = 46.0,
    minUxMs = 3500,
    reserveMs = 3500,
    calculateCamera = calculateBootCamera,
    generatePoints = generateBootPoints,
}

-- Profile genérico 'panel' que roteia conforme o boneKey
Profiles.list.panel = {
    title = 'CORTE DE PAINEL E DOBRADIÇAS',
    helpText = 'Corte os pontos de fixação da chapa',
    toolClass = 'cut',
    fov = 48.0,
    minUxMs = 3500,
    reserveMs = 3500,
    calculateCamera = function(vehicle, boneKey)
        if boneKey == 'bonnet' then return calculateBonnetCamera(vehicle, boneKey)
        elseif boneKey == 'boot' then return calculateBootCamera(vehicle, boneKey)
        else return calculateDoorCamera(vehicle, boneKey) end
    end,
    generatePoints = function(vehicle, boneKey)
        if boneKey == 'bonnet' then return generateBonnetPoints(vehicle, boneKey)
        elseif boneKey == 'boot' then return generateBootPoints(vehicle, boneKey)
        else return generateDoorPoints(vehicle, boneKey) end
    end,
}

PanelProfiles.resolvePanelBoneData = resolvePanelBoneData
return PanelProfiles
