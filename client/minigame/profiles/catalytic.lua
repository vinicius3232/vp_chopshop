-- client/minigame/profiles/catalytic.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [PR-2] Catalytic Profile — Furto de Catalisador em veículo parado
--  Mistura de primitives num só minigame (inspirado no fluxo "chapa com parafusos
--  + corte" de scripts do gênero — implementação autoral):
--    2 pontos 'drill' — braçadeiras de fixação do catalisador
--    2 pontos 'cut'   — seccionamento dos tubos dianteiro e traseiro
--  Câmera por baixo/atrás no bone `exhaust` (fallback exhaust_2 → chassis → offset).
--  Usado por doStealCatalytic (client/main.lua). O gate de tempo mínimo continua
--  sendo o token temporal de `vp_chopshop:catalytic:start` (server).
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}
local Proj = _G.VPChopProjection

local CatalyticProfile = {}

--- Resolve o centro do escapamento + vetores locais do veículo.
--- Ordem de fallback do bone: exhaust → exhaust_2 → chassis → offset geométrico traseiro.
local function resolveExhaustData(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return -1, vector3(0, 0, 0), 1.0, vector3(0, 1, 0), vector3(1, 0, 0), vector3(0, 0, 1)
    end

    local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, 'exhaust')
    if boneId == -1 then
        boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, 'exhaust_2')
    end
    if boneId == -1 then
        -- 'chassis' existe em praticamente todo veículo, mas fica no centro — puxa
        -- para a traseira-baixa onde o escapamento realmente está.
        local _, chassisPos, ss, f, r, u = Proj.GetBoneData(vehicle, 'chassis')
        sideSign, fwd, rightV, up = ss, f, r, u
        bonePos = chassisPos
        if type(GetOffsetFromEntityInWorldCoords) == 'function' then
            local ok, off = pcall(GetOffsetFromEntityInWorldCoords, vehicle, 0.0, -2.0, 0.15)
            if ok and off then bonePos = off end
        end
        boneId = 0
    end

    return boneId, bonePos, sideSign, fwd, rightV, up
end

local function calculateCatalyticCamera(vehicle, boneKey)
    local _, exPos, _, fwd, rightV, up = resolveExhaustData(vehicle)
    -- Câmera atrás e um pouco abaixo do plano do escapamento, olhando de baixo para
    -- cima (o jogador está agachado na traseira do carro).
    local camPos = exPos - (fwd * 1.15) - (up * 0.10) + (rightV * (0.25))
    local lookAt = exPos + (up * 0.10)
    return camPos, lookAt
end

local function generateCatalyticPoints(vehicle, boneKey)
    local _, exPos, _, fwd, rightV, up = resolveExhaustData(vehicle)

    -- Eixo longitudinal do escapamento = forward do veículo. As braçadeiras ficam
    -- perto do corpo do catalisador; os cortes de tubo, um pouco mais afastados.
    return {
        {
            id        = 'cat_clamp_f',
            primitive = 'drill',
            worldPos  = exPos + (fwd * 0.14) + (up * 0.02),
            label     = 'BRAÇADEIRA DIANT.',
            holdTimeMs = 1800.0,
        },
        {
            id        = 'cat_clamp_r',
            primitive = 'drill',
            worldPos  = exPos - (fwd * 0.14) + (up * 0.02),
            label     = 'BRAÇADEIRA TRAS.',
            holdTimeMs = 1800.0,
        },
        {
            id        = 'cat_pipe_f',
            primitive = 'cut',
            worldPos  = exPos + (fwd * 0.32) - (up * 0.01),
            label     = 'TUBO DIANTEIRO',
            holdTimeMs = 1900.0,
        },
        {
            id        = 'cat_pipe_r',
            primitive = 'cut',
            worldPos  = exPos - (fwd * 0.32) - (up * 0.01),
            label     = 'TUBO TRASEIRO',
            holdTimeMs = 1900.0,
        },
    }
end

Profiles.list.catalytic = {
    title    = 'FURTO DE CATALISADOR',
    helpText = 'Solte as braçadeiras e corte os tubos do catalisador',
    toolClass = 'cut',
    fov = 44.0,
    minUxMs = 4500,
    reserveMs = 3000,
    calculateCamera = calculateCatalyticCamera,
    generatePoints  = generateCatalyticPoints,
}

CatalyticProfile.resolveExhaustData = resolveExhaustData
return CatalyticProfile
