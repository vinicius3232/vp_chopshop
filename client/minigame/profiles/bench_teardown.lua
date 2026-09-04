-- client/minigame/profiles/bench_teardown.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [PR-4] Bench Teardown Profile — "desmonte na marreta" da peça roubada
--  A peça é carregada nos braços do jogador na bancada → "modo peça": passamos o
--  PED como âncora e a câmera enquadra as mãos.
--  Usa a primitive NOVA 'strike' (clique no ritmo, quando o anel entra na zona;
--  N golpes por ponto; erro não pune progresso). Ver html/app.js.
--  Gate real = proximidade de bancada + item `hammer` + token de
--  vp_chopshop:bench:teardownStart (server).
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}

local BenchTeardownProfile = {}

--- [FIX-1.3] Âncora: se `ent` for o PED do jogador → trabalha nas mãos (fluxo antigo).
--- Se for outro entity (prop da peça na bancada) → trabalha SOBRE ele, câmera de cima.
local function pedAnchor(ent)
    if not ent or ent == 0 or not DoesEntityExist(ent) then
        return vector3(0, 0, 0), vector3(0, 1, 0), vector3(1, 0, 0), vector3(0, 0, 1), false
    end
    local isProp = (ent ~= PlayerPedId())
    local up = vector3(0.0, 0.0, 1.0)
    if isProp then
        local target = GetEntityCoords(ent)
        local pc     = GetEntityCoords(PlayerPedId())
        local dir    = target - pc
        local fwd    = vector3(dir.x, dir.y, 0.0)
        local flen   = #fwd
        if flen > 0.1 then fwd = fwd / flen else fwd = GetEntityForwardVector(PlayerPedId()) end
        local rightV = vector3(fwd.y, -fwd.x, 0.0)
        return target, fwd, rightV, up, true
    end
    local pos    = GetEntityCoords(ent)
    local fwd    = GetEntityForwardVector(ent)
    local rightV = vector3(fwd.y, -fwd.x, 0.0)
    local rlen   = #rightV
    if rlen > 0.0 then rightV = rightV / rlen end
    return pos, fwd, rightV, up, false
end

local function workPoint(ent)
    local pos, fwd, _, up, isProp = pedAnchor(ent)
    if isProp then return pos + (up * 0.05) end
    return pos + (fwd * 0.50) + (up * 0.90)
end

local function calculateCamera(ent)
    local _, fwd, _, up, isProp = pedAnchor(ent)
    local work = workPoint(ent)
    if isProp then
        -- de cima, levemente atrás (jogador debruçado na bancada)
        return work - (fwd * 0.42) + (up * 0.52), work
    end
    return work + (fwd * 0.38) + (up * 0.34), work
end

local function generatePoints(ped)
    local _, _, rightV, up = pedAnchor(ped)
    local work = workPoint(ped)
    return {
        {
            id        = 'strike_seam_1',
            primitive = 'strike',
            hitsNeeded = 4,
            worldPos  = work + (rightV * -0.09) + (up * 0.04),
            label     = L('mg_teardown_seam1'),
        },
        {
            id        = 'strike_seam_2',
            primitive = 'strike',
            hitsNeeded = 4,
            worldPos  = work + (rightV * 0.09) + (up * 0.04),
            label     = L('mg_teardown_seam2'),
        },
        {
            id        = 'strike_open',
            primitive = 'strike',
            hitsNeeded = 5,
            worldPos  = work - (up * 0.06),
            label     = L('mg_teardown_open'),
        },
    }
end

Profiles.list.bench_teardown = {
    title    = L('mg_teardown_title'),
    helpText = L('mg_teardown_help'),
    toolClass = nil,  -- gate é bancada + item hammer + token (server)
    fov = 42.0,
    minUxMs = 5000,
    reserveMs = 3000,
    calculateCamera = calculateCamera,
    generatePoints  = generatePoints,
}

BenchTeardownProfile.pedAnchor = pedAnchor
BenchTeardownProfile.workPoint = workPoint
return BenchTeardownProfile
