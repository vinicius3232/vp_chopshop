-- server/session/deliver_car_util.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-H] Utilitários TESTÁVEIS do terminal hardening de fence:deliverCar.
--  Sem estado próprio, sem MySQL. Só toca natives de entidade + BridgeDeleteWorldVehicle.
--  Carregado pelo harness (tools/run_spec.lua) e por server/fence.lua.
--
--  O marcador `vpChopDeliveredMark` é um statebag SERVER-LOCAL (não replicado):
--  é a AUTORIDADE de identidade da entidade viva já entregue. Sobrevive a um
--  resource restart enquanto a entidade não sumir do mundo — impede que outro
--  jogador revenda a mesma carcaça enquanto o cleanup de mundo está pendente.
-- ═══════════════════════════════════════════════════════════════════════════════

VPChopDeliverCar = {}

--- Lê o marcador server-local de entrega. Resultado DISTINGUÍVEL:
---   ok=false            → leitura FALHOU (fail-closed: tratar como identidade não provada)
---   ok=true,  value=nil → confirmado SEM marcador (entidade limpa)
---   ok=true,  value=str → marcador presente (já entregue)
---@param veh integer
---@return boolean ok, string|nil value
function VPChopDeliverCar.readMark(veh)
    local ok, value = pcall(function() return Entity(veh).state.vpChopDeliveredMark end)
    if not ok then return false end
    return true, value
end

--- Escreve o marcador e RELÊ p/ confirmar o valor exato.
--- false ⇒ escrita não confirmada — NÃO confiar (o chamador faz rollback).
---@param veh integer
---@param mark string
---@return boolean confirmed
function VPChopDeliverCar.writeMark(veh, mark)
    local wok = pcall(function() Entity(veh).state:set('vpChopDeliveredMark', mark, false) end)
    if not wok then return false end
    local rok, v = VPChopDeliverCar.readMark(veh)
    return rok and v == mark
end

--- Limpa o marcador (rollback de pagamento). Best-effort.
--- false ⇒ remoção não confirmada (o chamador loga; sem perda monetária no fluxo novo).
---@param veh integer
---@return boolean cleared
function VPChopDeliverCar.clearMark(veh)
    local wok = pcall(function() Entity(veh).state:set('vpChopDeliveredMark', nil, false) end)
    if not wok then return false end
    local rok, v = VPChopDeliverCar.readMark(veh)
    return rok and v == nil
end

--- UMA tentativa de deleção de mundo com IDENTIDADE ESTRITA por marcador.
--- Não usa timer — testável direto. `scheduleCarDeleteRetry` só a agenda.
---@param tomb table|nil   DeliveredTombstone[netId] (nil ⇒ já coletado por entityRemoved)
---@param netId integer
---@param mark string       marcador esperado nesta entidade
---@param expectedFw string|nil
---@return { done:boolean|nil, aborted:boolean|nil, retryable:boolean|nil, method:string|nil, reason:string|nil }
function VPChopDeliverCar.tryDeleteCleanupOnce(tomb, netId, mark, expectedFw)
    if not tomb then return { aborted = true, reason = 'no_tombstone' } end
    local v = NetworkGetEntityFromNetworkId(netId)
    if not v or v == 0 or not DoesEntityExist(v) then return { done = true, reason = 'gone' } end
    local rok, cur = VPChopDeliverCar.readMark(v)
    if not rok then return { aborted = true, reason = 'mark_unreadable' } end
    if cur ~= mark then return { aborted = true, reason = 'mark_mismatch' } end
    local d = BridgeDeleteWorldVehicle(v, { expectedFramework = expectedFw })
    if not d.existsAfter then return { done = true, method = d.method } end
    return { done = false, retryable = d.retryable, method = d.method }
end
