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

local function workPoint(ped)
    local pos, fwd, _, up = pedAnchor(ped)
    return pos + (fwd * 0.50) + (up * 0.90)
end

local function calculateCamera(ped)
    local _, fwd, _, up = pedAnchor(ped)
    local work   = workPoint(ped)
    local camPos = work + (fwd * 0.38) + (up * 0.34)
    return camPos, work
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
            label     = 'SOLDA 1',
        },
        {
            id        = 'strike_seam_2',
            primitive = 'strike',
            hitsNeeded = 4,
            worldPos  = work + (rightV * 0.09) + (up * 0.04),
            label     = 'SOLDA 2',
        },
        {
            id        = 'strike_open',
            primitive = 'strike',
            hitsNeeded = 5,
            worldPos  = work - (up * 0.06),
            label     = 'ABERTURA',
        },
    }
end

Profiles.list.bench_teardown = {
    title    = 'DESMONTE NA MARRETA',
    helpText = 'Clique quando o anel entrar na zona verde',
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
