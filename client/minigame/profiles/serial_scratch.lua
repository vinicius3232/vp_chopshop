-- client/minigame/profiles/serial_scratch.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [PR-3] Serial Scratch Profile — lixar o número de série de uma car_parts
--  A peça é um ITEM de inventário (não um prop no mundo) → "modo peça": passamos o
--  PED como âncora e a câmera enquadra as mãos do jogador na bancada.
--  [FIX-1.3] Usa a primitive NOVA 'sand' — o jogador esfrega o mouse pra frente e
--  pra trás sobre cada zona do número; cada inversão de direção conta 1 passada.
--  2 zonas em sequência (a 2ª só libera depois da 1ª — `unlockAfter`).
--  Gate real = proximidade de bancada + item `sandpaper` (callback
--  vp_chopshop:serial:scratch, server).
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
Profiles.list = Profiles.list or {}

local SerialScratchProfile = {}

--- [FIX-1.3] Âncora: PED → nas mãos; qualquer outro entity (prop na bancada) →
--- sobre ele, câmera de cima.
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
    if isProp then return pos + (up * 0.04) end
    return pos + (fwd * 0.45) + (up * 0.95)
end

-- [FIX-1.3] Ajuste fino do lixamento aqui.
local STROKES_ETCH    = 9   -- passadas na zona da gravação (mais fundo)
local STROKES_RESIDUE = 6   -- passadas na zona do resíduo

local function calculateCamera(ent)
    local _, fwd, _, up, isProp = pedAnchor(ent)
    local work = workPoint(ent)
    if isProp then return work - (fwd * 0.24) + (up * 0.44), work end
    return work + (fwd * 0.26) + (up * 0.22), work
end

--- Câmera fecha ainda mais em cada zona quando o jogador começa a lixar.
local function focusPoint(ent, pointId)
    local _, fwd, rightV, up, isProp = pedAnchor(ent)
    local work = workPoint(ent)
    local lateral = (pointId == 'serial_grind_2') and 0.045 or -0.045
    local target  = work + (rightV * lateral)
    local behind  = isProp and -1.0 or 1.0
    local camPos  = target + (fwd * 0.17 * behind) + (up * (isProp and 0.30 or 0.13))
    return camPos, target, 30.0
end

local function generatePoints(ped)
    local _, _, rightV = pedAnchor(ped)
    local work = workPoint(ped)
    return {
        {
            id        = 'serial_grind_1',
            primitive = 'sand',
            strokesNeeded = STROKES_ETCH,
            worldPos  = work + (rightV * -0.045),
            label     = L('mg_serial_engraving'),
        },
        {
            id        = 'serial_grind_2',
            primitive = 'sand',
            strokesNeeded = STROKES_RESIDUE,
            -- [VISUAL-01C] sem lock: lixamento livre no painel (passe a lixa sobre o número)
            worldPos  = work + (rightV * 0.045),
            label     = L('mg_serial_residue'),
        },
    }
end

Profiles.list.serial_scratch = {
    title    = L('mg_serial_title'),
    helpText = L('mg_serial_help'),
    toolClass = nil,  -- gate é bancada + item sandpaper (server), não uma tool do registry
    panel = 'serial', -- [FIX-1.3] NUI renderiza uma "peça na bancada" com o nº de série
    fov = 34.0,
    minUxMs = 4000,
    reserveMs = 2000,
    calculateCamera = calculateCamera,
    focusPoint      = focusPoint,
    generatePoints  = generatePoints,
}

SerialScratchProfile.pedAnchor  = pedAnchor
SerialScratchProfile.workPoint  = workPoint
return SerialScratchProfile
