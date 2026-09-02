-- client/tracker.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.2.1] GPS Tracker & LoJack Client Interaction & Police Beacon
--  Handles target options on vehicles, removal minigame/progress with tokens,
--  cancel cleanup, and receiving periodic police tracking beacons.
-- ═══════════════════════════════════════════════════════════════════════════════

local function isPlayerPolice()
    local cfg = Config.Tracker or {}
    local policeJobs = cfg.PoliceJobs or { 'police', 'sheriff', 'bcso', 'state' }

    if type(IsPoliceJob) == 'function' then
        return IsPoliceJob()
    end

    if exports and exports.qbx_core and exports.qbx_core.GetPlayerData then
        local player = exports.qbx_core:GetPlayerData()
        if player and player.job then
            for _, job in ipairs(policeJobs) do
                if player.job.name == job and (player.job.onduty == nil or player.job.onduty == true) then
                    return true
                end
            end
        end
    end

    return false
end

--- Executa o fluxo de busca e remoção do rastreador GPS
---@param vehicle number entity handle
local function doTrackerRemoval(vehicle)
    if not DoesEntityExist(vehicle) then return end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)

    -- Client envia SOMENTE o netId para autorização server-side
    lib.callback('vp_chopshop:tracker:startRemoval', false, function(res)
        if not res or not res.ok then
            local err = (res and res.err) or 'unknown'
            if err == 'not_found' then
                lib.notify({ type = 'inform', description = L('tracker_not_found') })
            elseif err == 'already_removed' then
                lib.notify({ type = 'inform', description = L('tracker_already_removed') })
            elseif err == 'no_tool' then
                lib.notify({ type = 'error', description = L('tracker_no_tool') })
            elseif err == 'distance' then
                lib.notify({ type = 'error', description = L('err_distance') })
            else
                lib.notify({ type = 'error', description = VPChopLocaleErr(err) })
            end
            return
        end

        local removalToken = res.removalToken
        lib.notify({ type = 'inform', description = L('tracker_found') })

        local duration = res.minDurationMs or 7000
        local success = lib.progressBar({
            duration = duration,
            label = L('tracker_searching'),
            useWhileDead = false,
            canCancel = true,
            disable = {
                car = true,
                move = true,
                combat = true,
            },
            anim = {
                dict = 'mini@repair',
                clip = 'fixing_a_ped',
                flag = 1,
            },
        })

        if not success then
            -- Notifica o servidor para limpar a sessão ativa
            lib.callback('vp_chopshop:tracker:cancelRemoval', false, function() end, removalToken)
            lib.notify({ type = 'error', description = L('tracker_removal_failed') })
            return
        end

        -- Minigame de precisão para desarmar o circuito
        local skillPassed = lib.skillCheck({ 'easy', 'medium', 'medium' }, { 'w', 'a', 's', 'd' })
        if not skillPassed then
            lib.callback('vp_chopshop:tracker:cancelRemoval', false, function() end, removalToken)
            lib.notify({ type = 'error', description = L('tracker_removal_failed') })
            return
        end

        -- Conclui enviando estritamente netId e o token de autorização
        lib.callback('vp_chopshop:tracker:completeRemoval', false, function(resComp)
            if resComp and resComp.ok then
                lib.notify({ type = 'success', description = L('tracker_removed') })
            else
                local errComp = (resComp and resComp.err) or 'failed'
                lib.notify({ type = 'error', description = VPChopLocaleErr(errComp) })
            end
        end, netId, removalToken)
    end, netId)
end

-- ─── Registro ox_target ───────────────────────────────────────────────────────
CreateThread(function()
    local cfg = Config.Tracker or {}
    if not cfg.Enable then return end

    if exports and exports.ox_target then
        exports.ox_target:addGlobalVehicle({
            {
                name = 'vp_chopshop_search_tracker',
                icon = 'fa-solid fa-satellite-dish',
                label = L('target_search_tracker'),
                distance = cfg.MaxDistance or 2.5,
                canInteract = function(entity, distance, coords, name)
                    if not Config.Tracker or not Config.Tracker.Enable then return false end
                    if IsPedInAnyVehicle(PlayerPedId(), false) then return false end
                    return true
                end,
                onSelect = function(data)
                    doTrackerRemoval(data.entity)
                end,
            }
        })
    end
end)

-- ─── Recebimento de Beacon Policial (Server-Filtered) ─────────────────────────
RegisterNetEvent('vp_chopshop:client:trackerPing', function(coords, plate)
    if not isPlayerPolice() then return end
    if not coords or type(coords.x) ~= 'number' then return end

    local cfg = Config.Tracker or {}
    local blipTtl = cfg.BlipDurationSeconds or 10

    -- Notificação policial com título localizado
    lib.notify({
        title = L('tracker_police_title'),
        description = L('tracker_police_alert', plate or 'UNKNOWN'),
        type = 'error',
    })

    -- Blip visual no mapa policial
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 161) -- Radar ping sprite
    SetBlipColour(blip, 1)   -- Red
    SetBlipScale(blip, 1.3)
    SetBlipAsShortRange(blip, false)
    SetBlipAlpha(blip, 250)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(L('tracker_police_blip'))
    EndTextCommandSetBlipName(blip)

    CreateThread(function()
        local elapsed = 0
        while elapsed < (blipTtl * 1000) do
            Wait(1000)
            elapsed = elapsed + 1000
            local alpha = math.max(50, math.floor(250 * (1.0 - (elapsed / (blipTtl * 1000)))))
            SetBlipAlpha(blip, alpha)
        end
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end)
end)
