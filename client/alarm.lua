-- client/alarm.lua
-- Sistema de alarme veicular.
-- Escuta vp_chopshop:client:alarmTriggered do servidor, exibe aviso,
-- adiciona ox_target de desarme no veículo e chama dispatch se o tempo expirar.

--- Estado do alarme ativo neste cliente. Apenas um por vez.
local ActiveAlarm = nil -- { netId=integer, veh=entity }

--- Remove o ox_target do veículo e limpa o estado local.
local function clearAlarm()
    if not ActiveAlarm then return end
    if ActiveAlarm.veh and DoesEntityExist(ActiveAlarm.veh) then
        pcall(function()
            exports.ox_target:removeLocalEntity(ActiveAlarm.veh, { 'vp_chopshop:disarmAlarm' })
        end)
    end
    ActiveAlarm = nil
end

--- Disparado pelo servidor quando o alarme de um veículo é ativado.
RegisterNetEvent('vp_chopshop:client:alarmTriggered', function(netId)
    clearAlarm()
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    -- Acionar alarme sonoro/visual GTA
    SetVehicleAlarm(veh, true)
    StartVehicleAlarm(veh)

    lib.notify({
        title       = L('alarm_title'),
        description = L('alarm_triggered'),
        type        = 'error',
        duration    = 6000,
        position    = 'top-right',
    })

    -- Adicionar ox_target de desarme no veículo
    local alarmCfg   = Config.Alarm or {}
    local disarmDist = alarmCfg.DisarmDistance or 6.0
    local disarmItem = alarmCfg.DisarmItem or 'screwdriver'
    local skillCfg   = alarmCfg.DisarmSkillCheck  -- tabela ou false

    exports.ox_target:addLocalEntity(veh, {
        {
            name     = 'vp_chopshop:disarmAlarm',
            label    = L('alarm_disarm_label'),
            icon     = 'fas fa-screwdriver',
            distance = disarmDist,
            onSelect = function()
                -- 1. Verificar item (client-side, confirma server-side também)
                local count = exports.ox_inventory:Search('count', disarmItem) or 0
                if count < 1 then
                    lib.notify({ description = L('alarm_no_item'), type = 'error', duration = 4000 })
                    return
                end

                -- 2. Minigame de desarme (opcional)
                if skillCfg then
                    local passed = lib.skillCheck(skillCfg.difficulties, skillCfg.keys)
                    if not passed then
                        lib.notify({ description = L('alarm_skill_fail'), type = 'error', duration = 3000 })
                        return  -- alarme continua ativo; jogador pode tentar de novo
                    end
                end

                -- 3. Informar servidor e silenciar alarme localmente
                TriggerServerEvent('vp_chopshop:server:alarmDisarmed', netId)
                SetVehicleAlarm(veh, false)
                clearAlarm()
                lib.notify({ description = L('alarm_disarmed'), type = 'success', duration = 4000 })
            end,
        },
    })

    ActiveAlarm = { netId = netId, veh = veh }
end)

--- Disparado pelo servidor quando a janela de desarme expira sem resposta.
--- Chama dispatch se o veículo ainda existir.
RegisterNetEvent('vp_chopshop:client:alarmExpired', function(netId)
    clearAlarm()

    lib.notify({
        title       = L('alarm_title'),
        description = L('alarm_expired'),
        type        = 'error',
        duration    = 6000,
    })

    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        -- Reutiliza a função de dispatch existente em client/main.lua
        VPChopTriggerDispatch(veh)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        clearAlarm()
    end
end)
