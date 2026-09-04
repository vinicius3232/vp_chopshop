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

--- Âncora relativa ao PED (recebido no lugar de `vehicle`). Retorna posição + vetores.
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

--- Ponto de trabalho ~0.45 m à frente do peito do jogador (onde as "mãos" seguram a peça).
local function workPoint(ped)
    local pos, fwd, _, up = pedAnchor(ped)
    return pos + (fwd * 0.45) + (up * 0.95)
end

-- [FIX-1.3] Ajuste fino do lixamento aqui.
local STROKES_ETCH    = 9   -- passadas na zona da gravação (mais fundo)
local STROKES_RESIDUE = 6   -- passadas na zona do resíduo

local function calculateCamera(ped)
    local _, fwd, _, up = pedAnchor(ped)
    local work   = workPoint(ped)
    local camPos = work + (fwd * 0.26) + (up * 0.22)
    return camPos, work
end

--- Câmera fecha ainda mais em cada zona quando o jogador começa a lixar.
local function focusPoint(ped, pointId)
    local _, fwd, rightV, up = pedAnchor(ped)
    local work = workPoint(ped)
    local lateral = (pointId == 'serial_grind_2') and 0.045 or -0.045
    local target  = work + (rightV * lateral)
    local camPos  = target + (fwd * 0.17) + (up * 0.13)
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
            unlockAfter = 1,   -- só depois de apagar a gravação
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
