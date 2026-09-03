-- client/minigame/profiles/catalytic.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [PR-2 / FIX-1.2] Catalytic Profile — Furto de Catalisador em veículo parado
--  Fluxo autoral em close-up no escapamento (implementação própria; primitives
--  reaproveitadas, sem cópia de script de terceiros):
--    4 pontos 'rotate' — desparafusar as porcas da flange (gira o mouse em círculo)
--    2 pontos 'strike' — soltar o catalisador batendo na junta (clique no ritmo)
--  Câmera fechada, atrás/abaixo do escapamento (fallback de bone exhaust → _2 →
--  _3 → _4 → chassis → offset; só a câmera usa chassis, o locator de ox_target não).
--  Usado por doStealCatalytic (client/main.lua). O gate de tempo mínimo continua
--  sendo o token temporal de `vp_chopshop:catalytic:start` (server).
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}
local Proj = _G.VPChopProjection

local CatalyticProfile = {}

--- Resolve o centro do escapamento + vetores locais do veículo.
--- [FIX-1.1] Fallback de CÂMERA (só do profile — NÃO é o locator de interação, que
--- continua sem `chassis`): exhaust → exhaust_2 → exhaust_3 → exhaust_4 → chassis →
--- offset geométrico traseiro. O `chassis` aqui é aceitável porque só posiciona a
--- câmera; a opção de ox_target nunca ancora nele.
local EXHAUST_BONES = { 'exhaust', 'exhaust_2', 'exhaust_3', 'exhaust_4' }

local function resolveExhaustData(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return -1, vector3(0, 0, 0), 1.0, vector3(0, 1, 0), vector3(1, 0, 0), vector3(0, 0, 1)
    end

    local boneId, bonePos, sideSign, fwd, rightV, up = -1, nil, nil, nil, nil, nil
    for _, boneName in ipairs(EXHAUST_BONES) do
        boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, boneName)
        if boneId ~= -1 then break end
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

-- [FIX-1.2] Config do fluxo: 4 porcas + 2 golpes. Ajuste fino aqui.
local BOLT_COUNT     = 4
local BOLT_NEEDED_DEG = 720.0   -- giro por porca (mesmo "peso" do parafuso de roda)
local KNOCK_COUNT    = 2
local KNOCK_HITS     = 3        -- golpes de marreta por ponto

local function calculateCatalyticCamera(vehicle, boneKey)
    local _, exPos, _, fwd, rightV, up = resolveExhaustData(vehicle)
    -- Close-up: câmera logo atrás/abaixo da flange do catalisador, olhando o
    -- jogador agachado na traseira desparafusar as porcas.
    local camPos = exPos - (fwd * 0.78) - (up * 0.06) + (rightV * 0.16)
    local lookAt = exPos + (up * 0.04)
    return camPos, lookAt
end

local function generateCatalyticPoints(vehicle, boneKey)
    local _, exPos, _, fwd, rightV, up = resolveExhaustData(vehicle)

    -- A flange fica na junta dianteira do corpo do catalisador. As porcas ficam
    -- distribuídas num pequeno círculo no plano perpendicular ao tubo (rightV/up).
    local flange = exPos + (fwd * 0.16)
    local radius = 0.055
    local pts = {}

    for i = 1, BOLT_COUNT do
        local ang = (math.pi * 2.0) * ((i - 1) / BOLT_COUNT) + (math.pi / 4.0)
        local off = (rightV * (math.cos(ang) * radius)) + (up * (math.sin(ang) * radius))
        pts[#pts + 1] = {
            id        = ('cat_bolt_%d'):format(i),
            primitive = 'rotate',
            neededDeg = BOLT_NEEDED_DEG,
            worldPos  = flange + off,
            label     = ('%s %d'):format(L('mg_catalytic_bolt'), i),
        }
    end

    -- Golpes de marreta na junta traseira para soltar o catalisador do resto do tubo.
    for i = 1, KNOCK_COUNT do
        pts[#pts + 1] = {
            id        = ('cat_knock_%d'):format(i),
            primitive = 'strike',
            hitsNeeded = KNOCK_HITS,
            worldPos  = exPos - (fwd * 0.20) + (up * ((i == 1) and 0.03 or -0.03)),
            label     = ('%s %d'):format(L('mg_catalytic_knock'), i),
        }
    end

    return pts
end

Profiles.list.catalytic = {
    title    = L('mg_catalytic_title'),
    helpText = L('mg_catalytic_help'),
    toolClass = 'cut',   -- [FIX-1.2] mantém o gate de ferramenta de corte no inventário (sem mudança de balanço)
    fov = 38.0,          -- close-up mais fechado na flange
    minUxMs = 5000,
    reserveMs = 3000,
    calculateCamera = calculateCatalyticCamera,
    generatePoints  = generateCatalyticPoints,
}

CatalyticProfile.resolveExhaustData = resolveExhaustData
CatalyticProfile.EXHAUST_BONES = EXHAUST_BONES
_G.VPChopCatalyticProfile = CatalyticProfile  -- [FIX-1.1] acesso p/ specs de bone parity
return CatalyticProfile
