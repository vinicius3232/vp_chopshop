-- client/minigame/projection.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-A] ProjectionHelper — Funções Matemáticas de Projeção World -> Screen
--  Responsável por:
--   1) Converter coordenadas 3D para espaço normalizado de tela (0.0 - 1.0);
--   2) Derivar vetores locais (Forward, Right, Up) e orientação de bones (LF/RF/LR/RR);
--   3) Cachear buscas de bones por sessão de desmanche.
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProjection = _G.VPChopProjection or {}
local Proj = _G.VPChopProjection

--- Converte coordenadas de mundo 3D em coordenadas normalizadas de tela (0.0 a 1.0).
---@param worldPos vector3
---@return boolean onScreen, number screenX, number screenY
function Proj.WorldToScreen(worldPos)
    if not worldPos then return false, 0.0, 0.0 end
    local ok, sx, sy = GetScreenCoordFromWorldCoord(worldPos.x, worldPos.y, worldPos.z)
    if not ok then return false, 0.0, 0.0 end
    -- Validação de bounds da viewport
    if sx < 0.0 or sx > 1.0 or sy < 0.0 or sy > 1.0 then
        return false, sx or 0.0, sy or 0.0
    end
    return true, sx or 0.0, sy or 0.0
end

--- Deriva os vetores normalizados e a posição de um bone no veículo.
---@param vehicle integer
---@param boneName string
---@return integer boneId, vector3 bonePos, number sideSign, vector3 fwd, vector3 rightV, vector3 up
function Proj.GetBoneData(vehicle, boneName)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return -1, vector3(0, 0, 0), 1.0, vector3(0, 1, 0), vector3(1, 0, 0), vector3(0, 0, 1)
    end

    local boneId = GetEntityBoneIndexByName(vehicle, boneName)
    local bonePos = (boneId ~= -1) and GetWorldPositionOfEntityBone(vehicle, boneId) or GetEntityCoords(vehicle)

    local isLeft = (boneName:find('_lf') or boneName:find('_lr') or boneName:find('_dside') or boneName:find('door_dside')) ~= nil
    local sideSign = isLeft and -1.0 or 1.0

    local fwd = GetEntityForwardVector(vehicle)
    local up = vector3(0.0, 0.0, 1.0)
    local rightV = vector3(fwd.y, -fwd.x, 0.0)
    local rlen = #rightV
    if rlen > 0.0 then rightV = rightV / rlen end

    return boneId, bonePos, sideSign, fwd, rightV, up
end

return Proj
