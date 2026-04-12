-- bridge/mdt.lua
-- Bridge plugável para integração com qualquer MDT (ps-mdt, shot-spotter, próprio).
-- Para integrar: implementar as 3 funções abaixo com a lógica do seu MDT.
-- Sem implementação: sistema funciona de forma autossuficiente (sem dados externos).

VPChopMDT = {}

--- Retorna true se o veículo com esta placa está marcado como roubado no MDT.
---@param plate string
---@return boolean
function VPChopMDT.IsVehicleStolen(plate)
    -- Exemplo ps-mdt:
    -- return exports['ps-mdt']:isVehicleStolen(plate)
    return false
end

--- Retorna um modificador externo de heat (0.0 = nenhum, 1.0 = máximo).
--- Use para adicionar heat baseado em dados do MDT (ex: veículo marcado BOLO).
---@param plate string
---@return number 0.0..1.0
function VPChopMDT.GetHeatModifier(plate)
    -- Exemplo: veículo roubado = +50% do modificador externo
    -- if VPChopMDT.IsVehicleStolen(plate) then return 1.0 end
    return 0.0
end

--- Notifica o MDT de atividade de desmanche.
---@param plate string
---@param src number|nil  source do jogador (nil se evento do servidor)
---@param action string  'chop_started'|'part_removed'|'vin_scratched'|'heat_escalated'
function VPChopMDT.ReportActivity(plate, src, action)
    -- Exemplo ps-mdt:
    -- exports['ps-mdt']:addReport({ plate=plate, action=action, src=src })
    -- No-op por padrão.
end

-- Escuta mudanças de heat e reporta ao MDT quando escala para quente/queimando.
AddEventHandler(VPChopEvt.HEAT_CHANGED, function(plate, newLevel)
    if newLevel == 'quente' or newLevel == 'queimando' then
        VPChopMDT.ReportActivity(plate, nil, 'heat_escalated')
    end
end)
