-- bridge/mdt.lua
-- Bridge plugável para integração com qualquer MDT (ps-mdt, shot-spotter, próprio).
-- Para integrar: implementar as 3 funções abaixo com a lógica do seu MDT.
-- Sem implementação: sistema funciona de forma autossuficiente (sem dados externos).

-- shared/events.lua corre no env proxy do ox_lib e não propaga para server_scripts.
-- Definimos VPChopEvt aqui (primeiro server_script) para garantir visibilidade global.
VPChopEvt = VPChopEvt or {
    PART_CHOPPED   = 'vp_chopshop:evt:partChopped',
    CAR_DISCARDED  = 'vp_chopshop:evt:carDiscard',
    FENCE_DELIVERY = 'vp_chopshop:evt:fenceDelivery',
    HEAT_CHANGED   = 'vp_chopshop:evt:heatChanged',
}

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

-- ─── [FASE2 placas] Disfarce de placa: resolver visível → real ────────────────
-- A consulta normal do MDT continua "enganada" de graça (placa visível = falsa).
-- O CRIME, porém, segue a placa REAL: server/heat.lua roteia toda leitura de placa
-- por VPChopMDT.GetRealPlate antes de calcular heat / contar peças / ler VIN scratch.
--
-- VPChopDbResolveRealPlate vive em server/db.lua (carregado depois deste arquivo no
-- fxmanifest), então resolvemos a referência em runtime, não no load.

--- Resolve a placa REAL por trás de uma placa VISÍVEL (que pode ser falsa).
--- Se não houver disfarce mapeado, devolve a própria visível.
---@param visiblePlate string
---@return string realPlate
function VPChopMDT.GetRealPlate(visiblePlate)
    if not visiblePlate or visiblePlate == '' then return visiblePlate end
    -- VPChopDbResolveRealPlate definida em server/db.lua; checagem de existência por segurança.
    if VPChopDbResolveRealPlate then
        return VPChopDbResolveRealPlate(visiblePlate)
    end
    return visiblePlate
end

-- Escuta mudanças de heat e reporta ao MDT quando escala para quente/queimando.
AddEventHandler(VPChopEvt.HEAT_CHANGED, function(plate, newLevel)
    if newLevel == 'quente' or newLevel == 'queimando' then
        VPChopMDT.ReportActivity(plate, nil, 'heat_escalated')
    end
end)
