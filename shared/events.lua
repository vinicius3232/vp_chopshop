-- shared/events.lua
-- Barramento de eventos interno. Nenhum módulo chama outro diretamente:
-- publicar com TriggerEvent(VPChopEvt.XXX, ...) / escutar com AddEventHandler.

VPChopEvt = {
    --- Emitido por server/chop.lua e server/advanced_chop.lua após cada peça.
    --- params: src (number), netId (integer), partKey (string), phase (integer 1-4)
    PART_CHOPPED   = 'vp_chopshop:evt:partChopped',

    --- Emitido por server/main.lua após discard bem-sucedido.
    --- params: src (number), netId (integer), plate (string), cash (number)
    CAR_DISCARDED  = 'vp_chopshop:evt:carDiscard',

    --- Emitido por server/fence.lua após entrega de itens ao fence.
    --- params: src (number), items (table), totalValue (number)
    FENCE_DELIVERY = 'vp_chopshop:evt:fenceDelivery',

    --- Emitido por server/heat.lua quando o nível de heat muda de faixa.
    --- params: plate (string), newLevel (string) 'frio'|'morno'|'quente'|'queimando'
    --- Consumido por bridge/mdt.lua para notificar MDT externo.
    HEAT_CHANGED   = 'vp_chopshop:evt:heatChanged',
}
