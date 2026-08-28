-- server/session/deliver_car_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-H] Self-test do TERMINAL HARDENING de vp_chopshop:fence:deliverCar.
--  NÃO roda em produção (self-gated na convar vp_chopshop_selftest 1).
--
--  `simDeliverCarFlow` espelha o commit-point do callback (server/fence.lua) na
--  ORDEM NOVA (a reserva de cooldown é a autoridade e vem ANTES do dinheiro):
--    guards → entity → marcador(barreira) → ownership → cooldown SELECT →
--    RESERVA condicional (affected==1) → marcador write+readback → PAY →
--    tombstone → BridgeDeleteWorldVehicle → FENCE_DELIVERY 1×.
--  `VPChopDeliverCar.*` (marcador + retry) é código REAL — testado direto,
--  sem timer. Trust/tier/heat/DB reais + multiplayer ficam no TEST_PLAN de servidor.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[deliver_car/spec] PASS  ' .. name)
    else fail = fail + 1; print('[deliver_car/spec] FAIL  ' .. name) end
end

-- estado controlável
local PAY_OK, RESERVE_AFFECTED, RESERVE_THROWS, ROLLBACK_OK, MARK_WRITE_OK
local ROLLBACK_AFFECTED, CLEARMARK_OK   -- [RC-FIX-1a/1b]
local FENCE_EVENTS, netCash, cooldownReservedAt, _markSeq
local rollbackConfirmed, markClearFailLogged   -- test seams de observabilidade
local ORDER = {}
local DeliveryBusy, DeliverCarBusy, DeliveredTombstone = {}, {}, {}
local REG_BY_ID, REG_BY_PLATE = {}, {}
local function spawnCar(netId, model) FAKE_VEH[netId] = { model = model or 111 } end

local function fresh()
    for k in pairs(FAKE_VEH) do FAKE_VEH[k] = nil end
    for _, t in ipairs({ DeliveryBusy, DeliverCarBusy, DeliveredTombstone, REG_BY_ID, REG_BY_PLATE }) do
        for k in pairs(t) do t[k] = nil end
    end
    for i = #ORDER, 1, -1 do ORDER[i] = nil end
    for i = #_TRIGGERED, 1, -1 do _TRIGGERED[i] = nil end
    PAY_OK, RESERVE_AFFECTED, RESERVE_THROWS, ROLLBACK_OK, MARK_WRITE_OK = true, 1, false, true, true
    ROLLBACK_AFFECTED, CLEARMARK_OK = 1, true
    FENCE_EVENTS, netCash, cooldownReservedAt, _markSeq = 0, 0, nil, 0
    rollbackConfirmed, markClearFailLogged = nil, 0
    FAKE_RESOURCES.qbx_core, FAKE_RESOURCES.qbx_vehicles = 'started', 'started'
    _G.VPChopDBReady = true
    FAKE_EXPORTS.qbx_vehicles = {
        GetPlayerVehicle    = function(_, id) return REG_BY_ID[id] end,
        GetVehicleIdByPlate = function(_, plate) return REG_BY_PLATE[plate] end,
    }
    FAKE_EXPORTS.qbx_core = { DisablePersistence = function() end }
end

--- Espelha server/fence.lua deliverCar (trust/tier/heat/dist/plate já OK).
local function simDeliverCarFlow(playerKey, netId)
    if DeliveryBusy[playerKey] then return { ok = false, err = 'processing' } end
    DeliveryBusy[playerKey] = true
    local function release(r) DeliveryBusy[playerKey] = nil; return r end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return release({ ok = false, err = 'vehicle' }) end

    if DeliverCarBusy[netId] then return release({ ok = false, err = 'processing' }) end
    DeliverCarBusy[netId] = playerKey
    local function releaseAll(r) DeliverCarBusy[netId] = nil; return release(r) end

    -- marcador = barreira de entrada (função REAL)
    local mrok, curMark = VPChopDeliverCar.readMark(veh)
    if not mrok then return releaseAll({ ok = false, err = 'identity' }) end
    if curMark ~= nil then return releaseAll({ ok = false, err = 'already_delivered' }) end

    local persistence = BridgeResolveVehiclePersistence(veh, 'deliver_car')
    if persistence.status ~= 'not_owned' then
        return releaseAll({ ok = false, err = 'owned', persistence = persistence.status })
    end

    local payout = 8000
    local prevReserved = cooldownReservedAt

    -- 1) RESERVA de cooldown condicional — autoridade terminal, ANTES do dinheiro
    if RESERVE_THROWS then return releaseAll({ ok = false, err = 'db' }) end
    if RESERVE_AFFECTED ~= 1 then return releaseAll({ ok = false, err = 'cooldown_race' }) end
    cooldownReservedAt = os.time()
    ORDER[#ORDER + 1] = 'reserve'
    -- [RC-FIX-1a] só CONFIRMA com affectedRows==1
    local function rollbackCooldown()
        local ok = (ROLLBACK_OK == true) and (ROLLBACK_AFFECTED == 1)
        rollbackConfirmed = ok
        if ok then cooldownReservedAt = prevReserved end
        return ok
    end

    -- 2) marcador write+readback (função REAL, gate MARK_WRITE_OK simula falha de statebag)
    _markSeq = _markSeq + 1
    local mark = ('dcm:%d'):format(_markSeq)
    local wrote = MARK_WRITE_OK and VPChopDeliverCar.writeMark(veh, mark)
    if not wrote then
        rollbackCooldown()
        return releaseAll({ ok = false, err = 'identity' })
    end

    -- 3) PAGAR
    if not PAY_OK then
        -- [RC-FIX-1b] clearMark pode falhar → observável, marcador permanece fail-closed
        local markCleared = CLEARMARK_OK and VPChopDeliverCar.clearMark(veh)
        if not markCleared then markClearFailLogged = markClearFailLogged + 1 end
        rollbackCooldown()
        return releaseAll({ ok = false, err = 'payment' })
    end
    netCash = netCash + payout
    ORDER[#ORDER + 1] = 'pay'

    -- 4) tombstone + deleção de mundo
    DeliveredTombstone[netId] = { model = GetEntityModel(veh), mark = mark, at = os.time() }
    local del = BridgeDeleteWorldVehicle(veh, { expectedFramework = persistence.framework })
    ORDER[#ORDER + 1] = 'delete'
    FENCE_EVENTS = FENCE_EVENTS + 1
    _TRIGGERED[#_TRIGGERED + 1] = { evt = VPChopEvt.FENCE_DELIVERY, args = { playerKey, {}, payout, 'car' } }

    if del.existsAfter then
        return releaseAll({ ok = true, payout = payout, cleanupPending = true, mark = mark })
    end
    return releaseAll({ ok = true, payout = payout, mark = mark })
end

local function idxOf(list, v) for i, x in ipairs(list) do if x == v then return i end end end

CreateThread(function()
    Wait(1000)

    -- DCAR1 · not_owned → entrega ok, carro deletado, FENCE_DELIVERY 'car' 1×
    fresh(); spawnCar(50, 111)
    local r1 = simDeliverCarFlow('key:1', 50)
    check('DCAR1 not_owned → ok + payout', r1.ok == true and r1.payout == 8000)
    check('DCAR1 carro removido do mundo', FAKE_VEH[50] == nil)
    check('DCAR1 FENCE_DELIVERY car 1×', FENCE_EVENTS == 1)
    check('DCAR1 dinheiro = 8000', netCash == 8000)

    -- DCAR2 · owned (state.vehicleid) → DENY, sem pagar/deletar/evento
    fresh(); spawnCar(51, 111); FAKE_VEH[51].vehicleid = 900; REG_BY_ID[900] = { citizenid = 'X' }
    local r2 = simDeliverCarFlow('key:1', 51)
    check('DCAR2 owned → err=owned', r2.err == 'owned')
    check('DCAR2 carro intacto + nada pago + sem evento', FAKE_VEH[51] ~= nil and netCash == 0 and FENCE_EVENTS == 0)

    -- DCAR3 · unknown (export falha) → DENY fail-closed
    fresh(); spawnCar(52, 111)
    FAKE_EXPORTS.qbx_vehicles.GetVehicleIdByPlate = function() error('boom') end
    check('DCAR3 unknown → err=owned (fail-closed)', simDeliverCarFlow('key:1', 52).err == 'owned')

    -- DCAR4 · pagamento falha → nada perdido, carro intacto, sem evento
    fresh(); spawnCar(53, 111); PAY_OK = false
    local r4 = simDeliverCarFlow('key:1', 53)
    check('DCAR4 payment fail → err=payment', r4.err == 'payment')
    check('DCAR4 carro intacto + nada pago + sem evento', FAKE_VEH[53] ~= nil and netCash == 0 and FENCE_EVENTS == 0)

    -- DCAR6 · delete falha pós-pagamento → cleanupPending, jogador pago, tombstone
    fresh(); spawnCar(55, 111)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() error('qbx down') end
    local r6 = simDeliverCarFlow('key:1', 55)
    check('DCAR6 delete falha → ok + cleanupPending', r6.ok == true and r6.cleanupPending == true)
    check('DCAR6 jogador pago mesmo assim', netCash == 8000)
    check('DCAR6 carro AINDA no mundo + tombstone gravado', FAKE_VEH[55] ~= nil and DeliveredTombstone[55] ~= nil)
    check('DCAR6 re-entrega do MESMO carro → already_delivered (marcador)', simDeliverCarFlow('key:1', 55).err == 'already_delivered')

    -- DCAR7 · netId reciclado (modelo diferente, sem marcador) → entrega prossegue
    fresh(); spawnCar(56, 111)
    DeliveredTombstone[56] = { model = 111, mark = 'dcm:old', at = os.time() }
    FAKE_VEH[56] = { model = 222 }
    check('DCAR7 netId reciclado (sem marcador) → entrega prossegue', simDeliverCarFlow('key:2', 56).ok == true)

    -- DCAR8 · dois jogadores, MESMO carro → no máximo 1 entrega/payout
    fresh(); spawnCar(57, 111)
    local a = simDeliverCarFlow('key:1', 57)
    local b = simDeliverCarFlow('key:2', 57)
    check('DCAR8 1 entrega, 1 payout, 1 evento', a.ok == true and b.ok ~= true and netCash == 8000 and FENCE_EVENTS == 1)

    -- DCAR9 · DeliverCarBusy trava concorrência no mesmo netId
    fresh(); spawnCar(58, 111); DeliverCarBusy[58] = 'key:1'
    check('DCAR9 carro travado → processing', simDeliverCarFlow('key:2', 58).err == 'processing')

    -- DCAR10 · não-QBox → ownership unknown → DENY (fail-closed)
    fresh(); spawnCar(59, 111)
    FAKE_RESOURCES.qbx_core, FAKE_RESOURCES.qbx_vehicles = 'missing', 'missing'
    check('DCAR10 sem QBox → unknown → err=owned', simDeliverCarFlow('key:1', 59).err == 'owned')
    check('DCAR10 carro intacto, nada pago', FAKE_VEH[59] ~= nil and netCash == 0)

    -- DCAR11 · BridgeDeleteWorldVehicle direto: framework race → NÃO deleta
    fresh(); spawnCar(60, 111); FAKE_RESOURCES.qbx_core = 'missing'
    local d11 = BridgeDeleteWorldVehicle(60 + 70000, { expectedFramework = 'qbox' })
    check('DCAR11 framework race → method=framework_race, não deleta', d11.method == 'framework_race' and FAKE_VEH[60] ~= nil)

    -- DCAR12 · retry identidade estrita: mark gravado na entidade + no tombstone
    fresh(); spawnCar(61, 111)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() error('down') end
    local r12 = simDeliverCarFlow('key:1', 61)
    check('DCAR12 delete falha → mark no tombstone', DeliveredTombstone[61] and DeliveredTombstone[61].mark == r12.mark)
    check('DCAR12 mark está na entidade', FAKE_VEH[61].vpChopDeliveredMark == r12.mark)

    -- ── PR-H review: reserva de cooldown ANTES do payout ──────────────────────

    -- DCAR13 · reserva condicional affectedRows=0 → NÃO paga, carro intacto, evento 0
    fresh(); spawnCar(62, 111); RESERVE_AFFECTED = 0
    local r13 = simDeliverCarFlow('key:1', 62)
    check('DCAR13 affected=0 → err=cooldown_race', r13.err == 'cooldown_race')
    check('DCAR13 nada pago, carro intacto, sem evento, sem marcador',
        netCash == 0 and FAKE_VEH[62] ~= nil and FENCE_EVENTS == 0 and FAKE_VEH[62].vpChopDeliveredMark == nil)

    -- DCAR13b · query da reserva lança erro → err=db, nada pago
    fresh(); spawnCar(62, 111); RESERVE_THROWS = true
    local r13b = simDeliverCarFlow('key:1', 62)
    check('DCAR13b reserve throw → err=db, nada pago', r13b.err == 'db' and netCash == 0 and FENCE_EVENTS == 0)

    -- DCAR14 · DURABLE RESERVATION: reserva vem ANTES de qualquer pagamento
    fresh(); spawnCar(63, 111)
    local r14 = simDeliverCarFlow('key:1', 63)
    check('DCAR14 entrega ok', r14.ok == true)
    check('DCAR14 ORDER = reserve → pay → delete', ORDER[1] == 'reserve' and ORDER[2] == 'pay' and ORDER[3] == 'delete')
    check('DCAR14 reserve estritamente antes de pay', idxOf(ORDER, 'reserve') < idxOf(ORDER, 'pay'))

    -- DCAR15 · pagamento falha APÓS a reserva → sem dinheiro, cooldown restaurado,
    --          marcador limpo, carro intacto, FENCE_DELIVERY 0
    fresh(); spawnCar(64, 111); PAY_OK = false
    local r15 = simDeliverCarFlow('key:1', 64)
    check('DCAR15 err=payment', r15.err == 'payment')
    check('DCAR15 sem dinheiro', netCash == 0)
    check('DCAR15 cooldown restaurado ao valor anterior (nil)', cooldownReservedAt == nil)
    check('DCAR15 marcador limpo da entidade', FAKE_VEH[64].vpChopDeliveredMark == nil)
    check('DCAR15 carro intacto + evento 0', FAKE_VEH[64] ~= nil and FENCE_EVENTS == 0)

    -- DCAR16 · marcador write/readback falha → payout 0, cooldown rollback, delete 0, evento 0
    fresh(); spawnCar(65, 111); MARK_WRITE_OK = false
    local r16 = simDeliverCarFlow('key:1', 65)
    check('DCAR16 err=identity', r16.err == 'identity')
    check('DCAR16 payout 0, cooldown restaurado, carro intacto, evento 0',
        netCash == 0 and cooldownReservedAt == nil and FAKE_VEH[65] ~= nil and FENCE_EVENTS == 0)

    -- DCAR17 · RESOURCE RESTART: delete falhou, jogador pago, entidade mantém o
    --          marcador; tabelas in-memory limpas; player B NÃO consegue revender.
    fresh(); spawnCar(66, 111)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() error('down') end
    local r17 = simDeliverCarFlow('key:A', 66)
    check('DCAR17 entrega cleanupPending, A pago', r17.cleanupPending == true and netCash == 8000)
    local markOnEntity = FAKE_VEH[66].vpChopDeliveredMark
    -- simula restart: limpa TODO o estado in-memory, preserva o statebag da entidade
    for k in pairs(DeliveredTombstone) do DeliveredTombstone[k] = nil end
    for k in pairs(DeliverCarBusy) do DeliverCarBusy[k] = nil end
    for k in pairs(DeliveryBusy) do DeliveryBusy[k] = nil end
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() end
    check('DCAR17 marcador PERSISTE na entidade', FAKE_VEH[66].vpChopDeliveredMark == markOnEntity)
    local r17b = simDeliverCarFlow('key:B', 66)
    check('DCAR17 player B → already_delivered', r17b.err == 'already_delivered')
    check('DCAR17 nenhum segundo payout', netCash == 8000 and FENCE_EVENTS == 1)

    -- DCAR18 · SAME-MODEL netId reuse: tombstone antigo + entidade nova (mesmo
    --          model, SEM marcador) → não herda identidade econômica
    fresh(); spawnCar(70, 111)
    DeliveredTombstone[70] = { model = 111, mark = 'dcm:old', at = os.time() }
    FAKE_VEH[70] = { model = 111 }   -- outra entidade, mesmo model, sem marcador
    local r18 = simDeliverCarFlow('key:1', 70)
    check('DCAR18 mesmo model, marcador ausente → entrega prossegue', r18.ok == true)

    -- DCAR19 · RETRY REAL: delete inicial falhou; entidade substituída (mesmo netId
    --          e model, SEM o marcador antigo) → tryDeleteCleanupOnce ABORTA
    fresh(); spawnCar(80, 111)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() error('down') end
    local r19 = simDeliverCarFlow('key:1', 80)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() end
    FAKE_VEH[80] = { model = 111 }   -- nova entidade herdou o netId, sem marcador
    local res19 = VPChopDeliverCar.tryDeleteCleanupOnce(DeliveredTombstone[80], 80, r19.mark, 'qbox')
    check('DCAR19 retry real → aborted (mark_mismatch)', res19.aborted == true and res19.reason == 'mark_mismatch')
    check('DCAR19 entidade nova intacta', FAKE_VEH[80] ~= nil)

    -- DCAR20 · RETRY REAL: mesma entidade mantém o marcador → deleção pode executar
    fresh(); spawnCar(81, 111)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() error('down') end
    local r20 = simDeliverCarFlow('key:1', 81)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() end   -- agora o delete funciona
    local res20 = VPChopDeliverCar.tryDeleteCleanupOnce(DeliveredTombstone[81], 81, r20.mark, 'qbox')
    check('DCAR20 retry real → done, entidade removida', res20.done == true and FAKE_VEH[81] == nil)

    -- DCAR21 · tryDeleteCleanupOnce com tombstone já coletado → aborta
    check('DCAR21 tombstone nil → aborted', VPChopDeliverCar.tryDeleteCleanupOnce(nil, 999, 'dcm:x', 'qbox').aborted == true)

    -- ── RC-FIX-1a/1b: observabilidade de rollback + clearMark ─────────────────

    -- DCAR22 · payment FAIL + rollback query completa mas affectedRows=0 → fail-closed,
    --          sem 2ª tentativa econômica automática
    fresh(); spawnCar(82, 111); PAY_OK = false; ROLLBACK_AFFECTED = 0
    local r22 = simDeliverCarFlow('key:1', 82)
    check('DCAR22 err=payment', r22.err == 'payment')
    check('DCAR22 payout 0, delete 0, evento 0', netCash == 0 and FAKE_VEH[82] ~= nil and FENCE_EVENTS == 0)
    check('DCAR22 rollbackCooldown == false (affected 0 não confirma)', rollbackConfirmed == false)
    check('DCAR22 cooldown NÃO restaurado (fail-closed)', cooldownReservedAt ~= nil)

    -- DCAR23 · payment FAIL + rollback affectedRows=1 → marcador removido, cooldown restaurado
    fresh(); spawnCar(83, 111); PAY_OK = false   -- ROLLBACK_AFFECTED=1 default
    local r23 = simDeliverCarFlow('key:1', 83)
    check('DCAR23 err=payment, payout 0, evento 0', r23.err == 'payment' and netCash == 0 and FENCE_EVENTS == 0)
    check('DCAR23 marcador removido da entidade', FAKE_VEH[83].vpChopDeliveredMark == nil)
    check('DCAR23 cooldown restaurado (nil) + carro intacto', cooldownReservedAt == nil and FAKE_VEH[83] ~= nil)
    check('DCAR23 rollbackCooldown == true', rollbackConfirmed == true)

    -- DCAR24 · payment FAIL + clearMark → false → falha observável, marcador permanece,
    --          nova entrega daquele veículo seria already_delivered, sem perda econômica
    fresh(); spawnCar(84, 111); PAY_OK = false; CLEARMARK_OK = false
    local r24 = simDeliverCarFlow('key:1', 84)
    check('DCAR24 err=payment, payout 0, delete 0, evento 0',
        r24.err == 'payment' and netCash == 0 and FAKE_VEH[84] ~= nil and FENCE_EVENTS == 0)
    check('DCAR24 falha de clearMark registrada no seam', markClearFailLogged == 1)
    check('DCAR24 marcador PERMANECE na entidade', type(FAKE_VEH[84].vpChopDeliveredMark) == 'string')
    -- cooldown ainda foi restaurado (rollback OK) → economicamente seguro
    check('DCAR24 cooldown restaurado (rollback independente do clearMark)', cooldownReservedAt == nil)
    -- nova tentativa: qualquer jogador naquele veículo → already_delivered
    PAY_OK, CLEARMARK_OK = true, true
    check('DCAR24 re-entrega daquele veículo → already_delivered',
        simDeliverCarFlow('key:2', 84).err == 'already_delivered')
    check('DCAR24 nenhum payout na re-entrada', netCash == 0)

    print(('[deliver_car/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then print('[deliver_car/spec] \27[31mHÁ FALHAS.\27[0m') end
end)
