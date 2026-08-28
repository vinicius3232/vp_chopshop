-- client/carry.lua
-- Estado de peça carregada pelo jogador (prop na mão) e utilitário de drop.
-- Usado por client/main.lua (jackstand tyre steal, chop part prop, dismantle menu).

--- Peça carregada pelo jogador: { partKey, propHandle, isTyre?, entitlementId? }
--- [v1.15 PR-E] `entitlementId` (só p/ tyres) vem da RESPOSTA do servidor ao chop —
--- NUNCA gerado no client. É enviado de volta em `vp_chopshop:tyre:loadToTruck`.
VPChopCarryingPart = nil

--- Solta e elimina o prop carregado.
--- Se era um pneu do macaco, limpa animação carry e esconde TextUI.
function VPChopDropCarryPart()
    if not VPChopCarryingPart then return end
    local wasTyre = VPChopCarryingPart.isTyre
    local prop    = VPChopCarryingPart.propHandle
    if prop and DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        DeleteEntity(prop)
    end
    VPChopCarryingPart = nil
    if wasTyre then
        ClearPedTasksImmediately(PlayerPedId())
        lib.hideTextUI()
    end
end

RegisterNetEvent('vp_chopshop:client:sawBroke', function()
    VPChopNotify(L('notify_saw_broke'), 'error')
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    VPChopDropCarryPart()
end)
