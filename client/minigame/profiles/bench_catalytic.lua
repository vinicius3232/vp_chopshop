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

--- [FIX-1.3] Âncora: PED do jogador → nas mãos; qualquer outro entity (prop da peça
--- na bancada) → sobre ele, câmera de cima.
local function pedAnchor(ent)
    if not ent or ent == 0 or not DoesEntityExist(ent) then
        return vector3(0, 0, 0), vector3(0, 1, 0), vector3(1, 0, 0), vector3(0, 0, 1), false
    end
    local up = vector3(0.0, 0.0, 1.0)
    if ent ~= PlayerPedId() then
        local target = GetEntityCoords(ent)
        local pc     = GetEntityCoords(PlayerPedId())
        local dir    = target - pc
        local fwd    = vector3(dir.x, dir.y, 0.0)
        local flen   = #fwd
        if flen > 0.1 then fwd = fwd / flen else fwd = GetEntityForwardVector(PlayerPedId()) end
        return target, fwd, vector3(fwd.y, -fwd.x, 0.0), up, true
    end
    local pos    = GetEntityCoords(ent)
    local fwd    = GetEntityForwardVector(ent)
    local rightV = vector3(fwd.y, -fwd.x, 0.0)
    local rlen   = #rightV
    if rlen > 0.0 then rightV = rightV / rlen end
    return pos, fwd, rightV, up, false
end

--- Ponto de trabalho: sobre o prop na bancada, ou à frente do peito (mãos).
local function workPoint(ent)
    local pos, fwd, _, up, isProp = pedAnchor(ent)
    if isProp then return pos + (up * 0.05) end
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

local function calculateCamera(ent)
    local _, fwd, _, up, isProp = pedAnchor(ent)
    local work = workPoint(ent)
    if isProp then return work - (fwd * 0.34) + (up * 0.50), work end
    return work + (fwd * 0.34) + (up * 0.26), work
end

--- Câmera empurra pra cada ponto ativo (porca a porca, depois a junta).
local function focusPoint(ent, pointId)
    local _, fwd, rightV, up, isProp = pedAnchor(ent)
    local work   = workPoint(ent)
    local target = work + pointOffset(pointId, rightV, up, fwd)
    local behind = isProp and -1.0 or 1.0   -- prop: câmera do lado de cá; mãos: à frente
    if pointId:find('^bcat_knock_') then
        return work + (fwd * 0.24 * behind) + (up * (isProp and 0.30 or 0.16)), work, 34.0
    end
    return target + (fwd * 0.16 * behind) + (up * (isProp and 0.16 or 0.10)), target, 27.0
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
            visualType  = 'exhaust_bolt',  -- [VISUAL-01] overlay fotorrealista de fixação
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
    panel = 'catalytic', -- [VISUAL-02] NUI renderiza um painel de "catalisador na bancada"
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
