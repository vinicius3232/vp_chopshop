-- [REMOVED] Sistema de elevador (nacelle prop, zonas de detecção, sistema de parceiros,
-- animação de subida/descida, refuel, targets de desmanche por elevador).
-- O desmanche é feito exclusivamente com o macaco (jackstand) — ver client/main.lua.

--- Peça carregada pelo jogador: { partKey, propHandle }
VPChopCarryingPart = nil

--- Solta e elimina o prop carregado.
function VPChopDropCarryPart()
    if not VPChopCarryingPart then return end
    local prop = VPChopCarryingPart.propHandle
    if prop and DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        DeleteEntity(prop)
    end
    VPChopCarryingPart = nil
end

RegisterNetEvent('vp_chopshop:client:sawBroke', function()
    VPChopNotify(L('notify_saw_broke'), 'error')
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    VPChopDropCarryPart()
end)
