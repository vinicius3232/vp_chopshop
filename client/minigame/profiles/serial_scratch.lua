-- client/minigame/profiles/serial_scratch.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [PR-3] Serial Scratch Profile — lixar o número de série de uma car_parts
--  A peça é um ITEM de inventário (não um prop no mundo) → "modo peça": passamos o
--  PED como âncora e a câmera enquadra as mãos do jogador na bancada.
--  Reusa a primitive 'rotate' (segura o clique + gira o mouse em círculo = lixar).
--  Zero mudança de NUI. Gate real = proximidade de bancada + item `sandpaper`
--  (checados no callback vp_chopshop:serial:scratch, server).
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

local function calculateCamera(ped)
    local _, fwd, _, up = pedAnchor(ped)
    local work   = workPoint(ped)
    local camPos = work + (fwd * 0.32) + (up * 0.28)
    return camPos, work
end

local function generatePoints(ped)
    local _, _, rightV = pedAnchor(ped)
    local work = workPoint(ped)
    return {
        {
            id        = 'serial_grind_1',
            primitive = 'rotate',
            neededDeg = 900.0,
            worldPos  = work + (rightV * -0.05),
            label     = 'GRAVAÇÃO',
        },
        {
            id        = 'serial_grind_2',
            primitive = 'rotate',
            neededDeg = 720.0,
            worldPos  = work + (rightV * 0.05),
            label     = 'RESÍDUO',
        },
    }
end

Profiles.list.serial_scratch = {
    title    = 'ADULTERAR NÚMERO DE SÉRIE',
    helpText = 'Segure o clique e faça movimentos circulares para lixar o número',
    toolClass = nil,  -- gate é bancada + item sandpaper (server), não uma tool do registry
    fov = 38.0,
    minUxMs = 4000,
    reserveMs = 2000,
    calculateCamera = calculateCamera,
    generatePoints  = generatePoints,
}

SerialScratchProfile.pedAnchor  = pedAnchor
SerialScratchProfile.workPoint  = workPoint
return SerialScratchProfile
