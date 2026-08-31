-- client/minigame/camera.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-A] CameraController — Gerenciador de Câmera Scriptada para Desmanche
--  Responsável por:
--   1) Criar e interpolar suavemente a câmera até o ponto de foco (bone/peça);
--   2) Evitar clipping e manter orientação consistente (esquerda/direita);
--   3) Cleanup garantido e idempotente em qualquer cenário de saída (ESC, morte,
--      perda de entidade, stop de resource).
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopCamera = _G.VPChopCamera or {}
local CamCtrl = _G.VPChopCamera

local activeCam = nil
local isTransitioning = false

--- Cria e ativa uma câmera scriptada interpolada suavemente.
---@param camCoords vector3  Posição global da câmera
---@param lookAtCoords vector3  Ponto para onde a câmera deve olhar
---@param fov number|nil  Field of View (default 45.0)
---@param easeTimeMs number|nil  Tempo de interpolação em ms (default 600)
---@return boolean success
function CamCtrl.Create(camCoords, lookAtCoords, fov, easeTimeMs)
    if not camCoords or not lookAtCoords then return false end
    CamCtrl.ForceCleanup()

    fov = tonumber(fov) or 45.0
    easeTimeMs = tonumber(easeTimeMs) or 600

    local cam = CreateCamWithParams(
        'DEFAULT_SCRIPTED_CAMERA',
        camCoords.x, camCoords.y, camCoords.z,
        0.0, 0.0, 0.0,
        fov, false, 0
    )

    if not cam or cam == 0 or cam == -1 then
        return false
    end

    PointCamAtCoord(cam, lookAtCoords.x, lookAtCoords.y, lookAtCoords.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, easeTimeMs, true, true)

    activeCam = cam
    isTransitioning = true

    CreateThread(function()
        Wait(easeTimeMs)
        isTransitioning = false
    end)

    return true
end

--- Retorna a câmera suavemente para a visualização padrão do jogador e destrói o handle.
---@param easeTimeMs number|nil  Tempo de retorno em ms (default 400)
function CamCtrl.Destroy(easeTimeMs)
    if not activeCam then return end
    easeTimeMs = tonumber(easeTimeMs) or 400

    RenderScriptCams(false, true, easeTimeMs, true, true)
    if DoesCamExist(activeCam) then
        SetCamActive(activeCam, false)
        DestroyCam(activeCam, false)
    end

    activeCam = nil
    isTransitioning = false
end

--- Destruição imediata e síncrona (usada em interrupções críticas / cleanup de emergência).
function CamCtrl.ForceCleanup()
    if activeCam then
        if DoesCamExist(activeCam) then
            SetCamActive(activeCam, false)
            DestroyCam(activeCam, false)
        end
        RenderScriptCams(false, false, 0, true, true)
        activeCam = nil
        isTransitioning = false
    end
end

--- Verifica se há uma câmera scriptada ativa.
---@return boolean
function CamCtrl.IsActive()
    return activeCam ~= nil and DoesCamExist(activeCam)
end

-- Limpeza defensiva global
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        CamCtrl.ForceCleanup()
    end
end)

return CamCtrl
