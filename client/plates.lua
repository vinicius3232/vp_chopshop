-- client/plates.lua
-- [FASE1 placas] Roubo de placa física (lado cliente).
-- Adiciona um ox_target GLOBAL em veículos com a opção "Arrancar placa":
--   canInteract → tem chave de fenda E não é o veículo em que o próprio jogador está dirigindo.
--   onSelect    → lib.skillCheck (padrão do resource) → callback server 'vp_chopshop:stealPlate'.
-- A VERDADE (distância, placa real, item, cooldown) é toda validada no servidor (server/plates.lua).
-- Também escuta os eventos de broadcast para apagar a placa visível e disparar dispatch.

CreateThread(function()
    -- Respeitar o toggle da feature e a presença do ox_target.
    if not Config.Plates or not Config.Plates.Enable then return end

    -- Esperar o ox_target subir (mesmo padrão de espera de client/main.lua).
    local tries = 0
    while GetResourceState('ox_target') ~= 'started' and tries < 120 do
        Wait(250)
        tries = tries + 1
    end
    if GetResourceState('ox_target') ~= 'started' then return end

    local tool = Config.Plates.ToolItem or 'screwdriver'

    exports.ox_target:addGlobalVehicle({
        {
            name     = 'vp_chopshop:stealPlate',
            label    = L('plate_target_steal'),
            icon     = 'fa-solid fa-screwdriver',
            -- distância de interação do alvo (~2.0); a distância "real" é checada no servidor
            distance = 2.0,
            canInteract = function(entity)
                -- 1) precisa da chave de fenda (UX — servidor revalida)
                local count = exports.ox_inventory:Search('count', tool) or 0
                if count < 1 then return false end
                -- 2) não pode ser o próprio veículo do jogador (UX — servidor não bloqueia ainda
                --    por ownership na Fase 1, mas evitamos roubar a placa do carro que dirigimos)
                -- PlayerPedId() em vez de cache.ped: espelha o padrão usado no resto do resource;
                -- canInteract roda sob demanda (não por frame), sem custo relevante.
                local myVeh = GetVehiclePedIsIn(PlayerPedId(), false)
                if myVeh ~= 0 and myVeh == entity then return false end
                return true
            end,
            onSelect = function(data)
                local veh = data and data.entity
                if not veh or veh == 0 or not DoesEntityExist(veh) then
                    VPChopNotify(L('notify_generic_error'), 'error')
                    return
                end

                -- Minigame (mesmo formato de Config.Alarm.DisarmSkillCheck → lib.skillCheck)
                local sc = Config.Plates.SkillCheck
                if sc then
                    local passed = lib.skillCheck(sc.difficulties, sc.keys)
                    if not passed then
                        VPChopNotify(L('notify_skill_fail'), 'error')
                        return
                    end
                end

                local netId = NetworkGetNetworkIdFromEntity(veh)
                if not netId or netId == 0 then
                    VPChopNotify(L('notify_generic_error'), 'error')
                    return
                end

                local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:stealPlate', false, netId)
                if not cbOk or not res then
                    VPChopNotify(L('notify_generic_error'), 'error')
                    return
                end

                if res.ok then
                    VPChopNotify(L('plate_stolen_success'), 'success')
                else
                    -- Mapear erros do servidor para mensagens amigáveis (pt-BR via locale).
                    local errKey = ({
                        no_tool   = 'plate_no_tool',
                        range     = 'plate_too_far',
                        own       = 'plate_own_vehicle',
                        cooldown  = 'plate_cooldown',
                        no_plate  = 'plate_generic_error',
                        inventory = 'plate_generic_error',
                        done      = 'plate_generic_error',
                    })[res.err] or 'plate_generic_error'
                    VPChopNotify(L(errKey), 'error')
                end
            end,
        },
    })
end)

-- ─── Broadcast: apagar a placa visível nos clientes próximos ──────────────────
RegisterNetEvent('vp_chopshop:client:plateCleared', function(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    -- Placa em branco — o item físico saiu do carro.
    SetVehicleNumberPlateText(veh, '')
end)

-- ─── Dispatch: servidor manda o autor do roubo chamar a polícia ───────────────
-- Reutiliza o MESMO mecanismo do alarme (VPChopTriggerDispatch, definida em client/main.lua).
RegisterNetEvent('vp_chopshop:client:plateDispatch', function(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        VPChopTriggerDispatch(veh)
    end
end)
