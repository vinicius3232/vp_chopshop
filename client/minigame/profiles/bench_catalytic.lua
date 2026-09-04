-- client/minigame/profiles/bench_catalytic.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [FIX-1.3] Bench Catalytic Profile — desmontar o catalisador roubado NA BANCADA
--  antes de reciclar em matérias-primas.
--  "Modo peça": a peça está nos braços do jogador → o PED é a âncora e a câmera
--  enquadra as mãos na bancada (mesmo padrão de bench_teardown / serial_scratch).
--  Fluxo autoral (primitives reaproveitadas, sem cópia de script de terceiros):
--    1 ponto 'trace' — contornar a peça com o maçarico (corte da carcaça).
--    O painel de NUI desenha o contorno sobre a foto; a tocha segue o cursor.
--  Gate real = proximidade de bancada + item `hammer` + token de
--  vp_chopshop:bench:teardownStart (server) + at-most-once do PartEntitlement.
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}

local BenchCatalyticProfile = {}

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

local function calculateCamera(ent)
    local _, fwd, _, up, isProp = pedAnchor(ent)
    local work = workPoint(ent)
    if isProp then return work - (fwd * 0.34) + (up * 0.50), work end
    return work + (fwd * 0.34) + (up * 0.26), work
end

--- Câmera: enquadra a peça inteira na bancada (contorno é feito no painel de NUI).
local function focusPoint(ent, _pointId)
    local _, fwd, _, up, isProp = pedAnchor(ent)
    local work   = workPoint(ent)
    local behind = isProp and -1.0 or 1.0
    return work + (fwd * 0.30 * behind) + (up * (isProp and 0.24 or 0.14)), work, 40.0
end

local function generatePoints(ped)
    local work = workPoint(ped)
    return {
        {
            id        = 'bcat_cut',
            primitive = 'trace',   -- contorno da peça com o maçarico (painel desenha a linha)
            worldPos  = work,
            label     = L('mg_benchcat_cut'),
        },
    }
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
