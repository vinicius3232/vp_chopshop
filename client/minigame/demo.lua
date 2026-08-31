-- client/minigame/demo.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-A] Controlled Technical Demo Command
--  Permite validar a interação de câmera, projeção, NUI e cancelamento in-game.
--  Comando: /chopdemo [profile] [bone]   (default: demo wheel_lf)
-- ═══════════════════════════════════════════════════════════════════════════════

local Core = _G.VPChopDismantleMinigame

RegisterCommand('chopdemo', function(_, args)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local profileName = args[1] or 'demo'
    local boneKey = args[2] or 'wheel_lf'

    -- Encontrar veículo mais próximo
    local veh = GetClosestVehicle(coords.x, coords.y, coords.z, 5.0, 0, 71)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        VPChopNotify('Nenhum veículo próximo encontrado para a demo.', 'error')
        return
    end

    VPChopNotify(('Iniciando demo [%s] no bone [%s]...'):format(profileName, boneKey), 'inform')

    CreateThread(function()
        local success = Core.Start(veh, profileName, {
            boneKey = boneKey,
            uxSpeed = 1.0,
            timeout = 45000,
        })

        if success then
            VPChopNotify('Demo concluída com SUCESSO (100% dos pontos removidos).', 'success')
        else
            VPChopNotify('Demo CANCELADA ou encerrada.', 'inform')
        end
    end)
end, false)
