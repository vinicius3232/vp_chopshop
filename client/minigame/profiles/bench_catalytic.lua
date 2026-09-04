-- client/minigame/profiles/bench_catalytic.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [FIX-1.3] Bench Catalytic Profile — desmontar o catalisador roubado NA BANCADA
--  antes de reciclar em matérias-primas.
--  "Modo peça": a peça está nos braços do jogador → o PED é a âncora e a câmera
--  enquadra as mãos na bancada (mesmo padrão de bench_teardown / serial_scratch).
--  Fluxo autoral (primitives reaproveitadas, sem cópia de script de terceiros):
--    4 pontos 'rotate' — desparafusar as porcas da flange (EM SEQUÊNCIA)
--    2 pontos 'strike' — abrir a carcaça na marreta (só após as 4 porcas)
--  Gate real = proximidade de bancada + item `hammer` + token de
--  vp_chopshop:bench:teardownStart (server) + at-most-once do PartEntitlement.
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}

local BenchCatalyticProfile = {}

local BOLT_COUNT      = 4
local BOLT_NEEDED_DEG = 900.0
local KNOCK_COUNT     = 2
local KNOCK_HITS      = 4

local function pedAnchor(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return vector3(0, 0, 0), vector3(0, 1, 0), vector3(1, 0, 0), vector3(0, 0, 1)
    end
    local pos    = GetEntityCoords(ped)
    local fwd    = GetEntityForwardVector(ped)
    local up     = vector3(0.0, 0.0, 1.0)
    local rightV = vector3(fwd.y, -fwd.x, 0.0)
    local rlen   = #rightV
    if rlen > 0.0 then rightV = rightV / rlen end
    return pos, fwd, rightV, up
end

--- Ponto de trabalho ~0.5 m à frente do peito, altura da bancada.
local function workPoint(ped)
    local pos, fwd, _, up = pedAnchor(ped)
    return pos + (fwd * 0.50) + (up * 0.92)
end

--- Offset local de cada ponto (usado pelos pontos E pela câmera).
local function pointOffset(id, rightV, up, fwd)
    local boltN = id:match('^bcat_bolt_(%d)$')
    if boltN then
        boltN = tonumber(boltN)
        local ang = (math.pi * 2.0) * ((boltN - 1) / BOLT_COUNT) + (math.pi / 4.0)
        return (rightV * (math.cos(ang) * 0.06)) + (up * (math.sin(ang) * 0.06)) + (fwd * 0.05)
    end
    local knockN = id:match('^bcat_knock_(%d)$')
    if knockN then
        return -(fwd * 0.05) + (rightV * ((tonumber(knockN) == 1) and -0.07 or 0.07)) + (up * 0.02)
    end
    return vector3(0, 0, 0)
end

local function calculateCamera(ped)
    local _, fwd, _, up = pedAnchor(ped)
    local work   = workPoint(ped)
    local camPos = work + (fwd * 0.34) + (up * 0.26)
    return camPos, work
end

--- Câmera empurra pra cada ponto ativo (porca a porca, depois a junta).
local function focusPoint(ped, pointId)
    local _, fwd, rightV, up = pedAnchor(ped)
    local work   = workPoint(ped)
    local target = work + pointOffset(pointId, rightV, up, fwd)
    if pointId:find('^bcat_knock_') then
        return work + (fwd * 0.24) + (up * 0.16), work, 34.0
    end
    return target + (fwd * 0.16) + (up * 0.10), target, 27.0
end

local function generatePoints(ped)
    local _, fwd, rightV, up = pedAnchor(ped)
    local work = workPoint(ped)
    local pts = {}

    for i = 1, BOLT_COUNT do
        local id = ('bcat_bolt_%d'):format(i)
        pts[#pts + 1] = {
            id          = id,
            primitive   = 'rotate',
            neededDeg   = BOLT_NEEDED_DEG,
            unlockAfter = i - 1,
            worldPos    = work + pointOffset(id, rightV, up, fwd),
            label       = ('%s %d'):format(L('mg_benchcat_bolt'), i),
        }
    end

    for i = 1, KNOCK_COUNT do
        local id = ('bcat_knock_%d'):format(i)
        pts[#pts + 1] = {
            id          = id,
            primitive   = 'strike',
            hitsNeeded  = KNOCK_HITS,
            unlockAfter = BOLT_COUNT,
            worldPos    = work + pointOffset(id, rightV, up, fwd),
            label       = ('%s %d'):format(L('mg_benchcat_open'), i),
        }
    end

    return pts
end

Profiles.list.bench_catalytic = {
    title    = L('mg_benchcat_title'),
    helpText = L('mg_benchcat_help'),
    toolClass = nil,  -- gate = bancada + hammer + token (server)
    fov = 40.0,
    minUxMs = 6000,
    reserveMs = 3000,
    calculateCamera = calculateCamera,
    focusPoint      = focusPoint,
    generatePoints  = generatePoints,
}

BenchCatalyticProfile.pedAnchor = pedAnchor
BenchCatalyticProfile.workPoint = workPoint
return BenchCatalyticProfile
