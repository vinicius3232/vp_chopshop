-- client/minigame/core.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-A] VPChopDismantleMinigame — Núcleo de Interação Física e NUI Bridge
--  Responsável por:
--   1) Orquestrar o ciclo de vida do minigame (Start -> NUI -> Projeção -> Stop);
--   2) Sincronizar coordenadas 3D para 2D na NUI em tempo real;
--   3) Blindagem total de cancelamento (ESC, morte, distância, perda de entidade);
--   4) Garantir liberação de cursor, foco NUI e restauração de câmera.
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopDismantleMinigame = _G.VPChopDismantleMinigame or {}
local Core = _G.VPChopDismantleMinigame

local CamCtrl  = _G.VPChopCamera
local Proj     = _G.VPChopProjection
local Profiles = _G.VPChopProfiles

local isRunning = false
local currentSession = nil

--- Registra os NUI callbacks que comunicam o estado do JS para o Lua.
local function setupNuiCallbacks()
    RegisterNUICallback('minigamePointComplete', function(data, cb)
        if currentSession and data and data.id then
            PlaySoundFrontend(-1, 'Pin_Good', 'DLC_HEIST_FLEECA_SOUNDSET', true)
        end
        cb({ ok = true })
    end)

    RegisterNUICallback('minigameCancel', function(data, cb)
        if currentSession then
            currentSession.result = false
            currentSession.cancelReason = data and data.reason or 'cancel'
        end
        cb({ ok = true })
    end)

    RegisterNUICallback('minigameFinish', function(data, cb)
        if currentSession then
            currentSession.result = (data and data.success == true)
        end
        cb({ ok = true })
    end)
end

setupNuiCallbacks()

--- Força o encerramento seguro de qualquer sessão ativa do minigame.
---@param reason string|nil
function Core.Stop(reason)
    if not isRunning then return end
    if currentSession then
        currentSession.result = false
        currentSession.cancelReason = reason or 'forced_stop'
    end
end

--- Verifica se há um minigame em execução.
---@return boolean
function Core.IsActive()
    return isRunning
end

--- Inicia uma sessão de desmanche físico interativo.
---@param vehicle integer  Handle da entidade do veículo
---@param profileName string  Nome do profile registrado em VPChopProfiles
---@param opts table|nil  Opções adicionais (boneKey, uxSpeed, title, helpText)
---@return boolean success  true se completou 100%, false se cancelou ou falhou
function Core.Start(vehicle, profileName, opts)
    if isRunning then return false end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return false
    end

    opts = opts or {}
    local profile = Profiles.Get(profileName)
    if not profile then
        return _G.VPChopMinigameFallback(vehicle, opts.boneKey, 'profile_not_found')
    end

    isRunning = true
    currentSession = {
        vehicle = vehicle,
        profile = profile,
        boneKey = opts.boneKey or 'wheel_lf',
        result = nil,
        cancelReason = nil,
        startMs = GetGameTimer()
    }

    -- 1) Configurar câmera scriptada
    local camPos, lookAt = profile.calculateCamera(vehicle, currentSession.boneKey)
    local camOk = CamCtrl.Create(camPos, lookAt, profile.fov or 45.0, 500)
    if not camOk then
        isRunning = false
        currentSession = nil
        return _G.VPChopMinigameFallback(vehicle, opts.boneKey, 'camera_creation_failed')
    end

    -- 2) Gerar pontos e projetar estado inicial
    local points = profile.generatePoints(vehicle, currentSession.boneKey)
    if not points or #points == 0 then
        CamCtrl.Destroy(200)
        isRunning = false
        currentSession = nil
        return _G.VPChopMinigameFallback(vehicle, opts.boneKey, 'no_points_generated')
    end

    local nuiPoints = {}
    for _, pt in ipairs(points) do
        local onScreen, sx, sy = Proj.WorldToScreen(pt.worldPos)
        nuiPoints[#nuiPoints + 1] = {
            id = pt.id,
            label = pt.label,
            x = sx,
            y = sy,
            neededDeg = pt.neededDeg or 720.0,
            visible = onScreen
        }
    end

    -- 3) Animação inicial do jogador
    local ped = PlayerPedId()
    RequestAnimDict('mini@repair')
    local t0 = GetGameTimer()
    while not HasAnimDictLoaded('mini@repair') and (GetGameTimer() - t0 < 1000) do
        Wait(10)
    end
    if HasAnimDictLoaded('mini@repair') then
        TaskPlayAnim(ped, 'mini@repair', 'fixing_a_player', 8.0, -1.0, -1, 49, 0.0, false, false, false)
    end

    -- 4) Abrir NUI
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'minigame:start',
        data = {
            title = opts.title or profile.title,
            helpText = opts.helpText or profile.helpText,
            toolClass = profile.toolClass,
            uxSpeed = opts.uxSpeed or 1.0,
            points = nuiPoints
        }
    })

    -- 5) Loop de atualização e acompanhamento
    local timeoutMs = opts.timeout or 30000
    while currentSession and currentSession.result == nil do
        Wait(0)

        -- Condições de cancelamento de segurança
        if not DoesEntityExist(vehicle) then
            currentSession.result = false
            currentSession.cancelReason = 'vehicle_lost'
            break
        end

        if IsPedDeadOrDying(ped, true) then
            currentSession.result = false
            currentSession.cancelReason = 'player_died'
            break
        end

        local pCoords = GetEntityCoords(ped)
        local vCoords = GetEntityCoords(vehicle)
        if #(pCoords - vCoords) > 6.0 then
            currentSession.result = false
            currentSession.cancelReason = 'distance'
            break
        end

        if GetGameTimer() - currentSession.startMs > timeoutMs then
            currentSession.result = false
            currentSession.cancelReason = 'timeout'
            break
        end

        -- Atualizar coordenadas dos pontos projetados na tela
        local updatedPoints = {}
        for _, pt in ipairs(points) do
            local onScreen, sx, sy = Proj.WorldToScreen(pt.worldPos)
            updatedPoints[#updatedPoints + 1] = {
                id = pt.id,
                x = sx,
                y = sy,
                visible = onScreen
            }
        end

        SendNUIMessage({
            action = 'minigame:updatePoints',
            data = { points = updatedPoints }
        })
    end

    -- 6) Teardown garantido
    local finalResult = (currentSession and currentSession.result == true)

    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'minigame:stop' })
    ClearPedTasks(ped)
    CamCtrl.Destroy(400)

    isRunning = false
    currentSession = nil

    return finalResult
end

-- Limpeza defensiva global
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if isRunning then
            SetNuiFocus(false, false)
            SendNUIMessage({ action = 'minigame:stop' })
            CamCtrl.ForceCleanup()
            ClearPedTasks(PlayerPedId())
            isRunning = false
            currentSession = nil
        end
    end
end)

return Core
