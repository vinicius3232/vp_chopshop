-- server/logistics/tyre_entitlement_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-E] Self-test do TYRE ENTITLEMENT + TRUCK STORAGE. NÃO roda em produção
--  (self-gated na convar vp_chopshop_selftest 1).
--
--  Cobre: TyreEntitlement.* + TruckStorage.* + a COMPOSIÇÃO dos fluxos load/sell
--  (`simLoadFlow` / `simSellFlow` espelham o commit-point de server/fence.lua).
--  Fora daqui (TEST_PLAN de servidor): props/carry no client, ox_target, trust,
--  proximidade real, yield real de BridgeAddCash.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[tyre_entitlement/spec] PASS  ' .. name)
    else fail = fail + 1; print('[tyre_entitlement/spec] FAIL  ' .. name) end
end

-- ─── ChopSession seam (veículos de origem) ────────────────────────────────────
local ENTITY_API = {
    get    = function(netId) return FAKE_VEH[netId] and (netId + 70000) or 0 end,
    exists = function(h) return h ~= nil and h ~= 0 end,
    model  = function(h) local n = (h or 0) - 70000; return FAKE_VEH[n] and FAKE_VEH[n].model or 0 end,
    plate  = function() return 'PLATE' end,
    owned  = function() return nil end,
    tag    = function(h, vsid) local n = h - 70000; if FAKE_VEH[n] then FAKE_VEH[n].mark = vsid end; return FAKE_VEH[n] and FAKE_VEH[n].mark == vsid end,
    marker = function(h) local n = h - 70000; return FAKE_VEH[n] and FAKE_VEH[n].mark or nil end,
}

-- ─── TruckStorage seam (trucks) ──────────────────────────────────────────────
local FAKE_TRUCK = {}
local TAG_OK = true
local TRUCK_API = {
    get      = function(n) return FAKE_TRUCK[n] and (n + 90000) or 0 end,
    exists   = function(h) return h ~= nil and h ~= 0 end,
    model    = function(h) local n = (h or 0) - 90000; return FAKE_TRUCK[n] and FAKE_TRUCK[n].model or 0 end,
    tag      = function(h, sid)
        if not TAG_OK then return false end
        local n = h - 90000; if FAKE_TRUCK[n] then FAKE_TRUCK[n].mark = sid end
        return FAKE_TRUCK[n] and FAKE_TRUCK[n].mark == sid
    end,
    marker   = function(h) local n = h - 90000; return FAKE_TRUCK[n] and FAKE_TRUCK[n].mark or nil end,
    setCount = function(h, c) local n = h - 90000; if FAKE_TRUCK[n] then FAKE_TRUCK[n].count = c end end,
}
local function spawnTruck(netId, model) FAKE_TRUCK[netId] = { model = model or 555, count = 0 } end
local function despawnTruck(netId) FAKE_TRUCK[netId] = nil end

local PAY_OK, REFUND_OK, netMoney = true, true, 0
local SELL_MIDPAY_HOOK        -- fn() chamada ENTRE o pagamento e o CommitSold (simula yield)
local TruckStorageBusy = {}
local TyreSaleQuarantine = {}  -- espelha o fail-closed econômico de server/fence.lua

local function fresh()
    ChopSession._test.setEntityAPI(ENTITY_API); ChopSession._test.reset()
    TyreEntitlement._test.reset()
    TruckStorage._test.setEntityAPI(TRUCK_API); TruckStorage._test.reset()
    for k in pairs(FAKE_VEH) do FAKE_VEH[k] = nil end
    for k in pairs(FAKE_TRUCK) do FAKE_TRUCK[k] = nil end
    for k in pairs(TruckStorageBusy) do TruckStorageBusy[k] = nil end
    Config.ChopSession.Enable = true
    Config.TyreSelling.Enable = true
    Config.TyreSelling.MaxTyresInTruck = 4
    TAG_OK, PAY_OK, REFUND_OK, netMoney = true, true, true, 0
    SELL_MIDPAY_HOOK = nil
    for k in pairs(TyreSaleQuarantine) do TyreSaleQuarantine[k] = nil end
end

local function spawn(netId, model) FAKE_VEH[netId] = { model = model or 111 } end

local function legitRaise(netId, src)
    local s = ChopSession.Create(netId, src)
    ChopSession.AddParticipant(s.id, src); ChopSession.MarkRaised(s.id, src)
    return s
end

-- Remove uma roda pelo fluxo base real + emite o entitlement (como server/main.lua).
local function chopWheel(netId, src, partKey)
    local okP = select(1, VPChopServerTryPart(src, netId, partKey))
    if not okP then return nil, 'chop' end
    local s = ChopSession.GetByVehicle(netId)
    if not s then return nil, 'no_session' end
    return TyreEntitlement.Issue(s.id, src, partKey)
end

-- Espelha server/fence.lua 'vp_chopshop:tyre:loadToTruck' (truck/model/range já OK).
local function simLoadFlow(src, truckNetId, entitlementId)
    local ent = TyreEntitlement.Get(entitlementId)
    if not ent then return { ok = false, err = 'entitlement' } end
    if ent.removedBy ~= src then return { ok = false, err = 'owner' } end
    if ent.state == 'STORED' then return { ok = false, err = 'already_stored' } end
    if ent.state ~= 'REMOVED' then return { ok = false, err = 'bad_state' } end
    local storageId, sErr = TruckStorage.Resolve(truckNetId)
    if not storageId then return { ok = false, err = sErr or 'storage_identity' } end
    if TruckStorageBusy[storageId] then return { ok = false, err = 'truck_busy' } end
    TruckStorageBusy[storageId] = true
    local ok, c = TruckStorage.Load(storageId, entitlementId)
    TruckStorageBusy[storageId] = nil
    if not ok then return { ok = false, err = c } end
    return { ok = true, count = c, storageId = storageId }
end

-- Espelha server/fence.lua 'vp_chopshop:fence:sellTyres' (truck path). `src` = playerKey.
local function simSellFlow(src, truckNetId)
    if TyreSaleQuarantine[src] then return { ok = false, err = 'transaction_locked' } end
    local storageId, sErr = TruckStorage.Peek(truckNetId)
    if not storageId then return { ok = false, err = sErr or 'no_tyres' } end
    if TruckStorageBusy[storageId] then return { ok = false, err = 'truck_busy' } end
    TruckStorageBusy[storageId] = true
    local function rel(r) TruckStorageBusy[storageId] = nil; return r end
    local ids   = TruckStorage.SnapshotStored(storageId)
    local count = #ids
    if count <= 0 then return rel({ ok = false, err = 'no_tyres' }) end
    local totalPrice = 400 * count
    if not PAY_OK then return rel({ ok = false, err = 'payment' }) end   -- entitlements intactos
    netMoney = netMoney + totalPrice
    if SELL_MIDPAY_HOOK then SELL_MIDPAY_HOOK(ids) end                   -- simula yield do pagamento
    local sold = TruckStorage.CommitSold(storageId, ids)
    if sold < count then
        local refund = 400 * (count - sold)
        if REFUND_OK then
            netMoney = netMoney - refund                                -- BridgeRemoveCash ok
        else
            TyreSaleQuarantine[src] = (TyreSaleQuarantine[src] or 0) + refund   -- fail-closed
        end
        totalPrice = 400 * sold
    end
    if sold <= 0 then return rel({ ok = false, err = 'no_tyres' }) end
    return rel({ ok = true, count = sold, total = totalPrice })
end

CreateThread(function()
    Wait(1000)

    -- ═══ ISSUE ═══════════════════════════════════════════════════════════════
    fresh(); spawn(10, 111); legitRaise(10, 1)
    local e1 = chopWheel(10, 1, 'wheel_lf')
    check('E1 wheel_lf committed → 1 entitlement', type(e1) == 'string' and TyreEntitlement.State(e1) == 'REMOVED')

    local sid10 = ChopSession.GetByVehicle(10).id
    local e2 = TyreEntitlement.Issue(sid10, 1, 'wheel_lf')
    check('E2 Issue de novo mesma session+part → MESMO id', e2 == e1)
    check('E2 só 1 entitlement no ledger', (function()
        local c = 0; for _ in pairs(TyreEntitlement._test._all()) do c = c + 1 end; return c == 1
    end)())

    -- E3 door/non-tyre → nenhum entitlement
    check('E3 bonnet (door) → not_tyre', select(2, TyreEntitlement.Issue(sid10, 1, 'bonnet')) == 'not_tyre')

    -- E4 provenance
    local e4 = TyreEntitlement.Get(e1)
    check('E4 guarda sourceSessionId + vsid + partKey', e4.source.sessionId == sid10
        and type(e4.source.vsid) == 'string' and e4.source.partKey == 'wheel_lf')

    -- E5 source vehicle some → entitlement persiste
    despawnTruck(0)  -- no-op
    FAKE_VEH[10] = nil
    ChopSession.CleanupVehicle(10)
    check('E5 source vehicle removido → entitlement persiste', TyreEntitlement.State(e1) == 'REMOVED')
    check('E5 ChopSession do veículo sumiu', ChopSession.GetByVehicle(10) == nil)

    -- ═══ LOAD ═══════════════════════════════════════════════════════════════
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w1 = chopWheel(10, 1, 'wheel_lf')
    local r6 = simLoadFlow(1, 20, w1)
    check('E6 entitlement válido + truck → STORED', r6.ok == true and TyreEntitlement.State(w1) == 'STORED')
    check('E6 count = 1', r6.count == 1)

    check('E7 mesmo entitlement load de novo → already_stored', simLoadFlow(1, 20, w1).err == 'already_stored')

    -- E8 entitlement de outro jogador
    local w8 = chopWheel(10, 1, 'wheel_rf')   -- removedBy = 1
    check('E8 outro jogador (src 2) → owner', simLoadFlow(2, 20, w8).err == 'owner')

    -- E9 fake id
    check('E9 fake entitlementId → entitlement', simLoadFlow(1, 20, 'te:9999').err == 'entitlement')

    -- E10 truck cheio → entitlement continua REMOVED
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    Config.TyreSelling.MaxTyresInTruck = 2
    local a = chopWheel(10, 1, 'wheel_lf'); local b = chopWheel(10, 1, 'wheel_rf')
    local c = chopWheel(10, 1, 'wheel_lr')
    simLoadFlow(1, 20, a); simLoadFlow(1, 20, b)
    local r10 = simLoadFlow(1, 20, c)
    check('E10 truck cheio → truck_full', r10.err == 'truck_full')
    check('E10 3º entitlement continua REMOVED', TyreEntitlement.State(c) == 'REMOVED')
    Config.TyreSelling.MaxTyresInTruck = 4

    -- E13 dois callbacks mesmo entitlement → no máximo 1 STORED
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w13 = chopWheel(10, 1, 'wheel_lf')
    local x, y = simLoadFlow(1, 20, w13), simLoadFlow(1, 20, w13)
    check('E13 um STORED, outro already_stored', x.ok == true and y.err == 'already_stored')
    check('E13 storage count = 1', TruckStorage.Count(x.storageId) == 1)

    -- ═══ STORAGE IDENTITY ═══════════════════════════════════════════════════
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w14 = chopWheel(10, 1, 'wheel_lf')
    local r14 = simLoadFlow(1, 20, w14)
    check('E14 1º load → storageId cunhado + marcador confirmado',
        type(r14.storageId) == 'string' and FAKE_TRUCK[20].mark == r14.storageId)

    -- E15 marker write/readback falha → nenhum storage, entitlement continua REMOVED
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(21, 555)
    local w15 = chopWheel(10, 1, 'wheel_lf'); TAG_OK = false
    local r15 = simLoadFlow(1, 21, w15)
    check('E15 marcador falha → storage_identity', r15.err == 'storage_identity')
    check('E15 entitlement continua REMOVED', TyreEntitlement.State(w15) == 'REMOVED')
    check('E15 nenhum storage criado', (function()
        local c = 0; for _ in pairs(TruckStorage._test._all()) do c = c + 1 end; return c == 0
    end)())
    TAG_OK = true

    -- E16 netId reciclado, OUTRO truck → storage antigo não aparece no novo
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w16 = chopWheel(10, 1, 'wheel_lf'); simLoadFlow(1, 20, w16)
    despawnTruck(20); spawnTruck(20, 555)   -- novo truck, mesmo netId, SEM o marcador antigo
    check('E16 Resolve no netId reciclado → storage_identity', select(2, TruckStorage.Resolve(20)) == 'storage_identity')
    check('E16 Peek no netId reciclado → storage_identity', select(2, TruckStorage.Peek(20)) == 'storage_identity')

    -- E17 mesmo model + mesmo netId + marker diferente → DENY storage_identity
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w17 = chopWheel(10, 1, 'wheel_lf'); simLoadFlow(1, 20, w17)
    FAKE_TRUCK[20].mark = 'ts:evil'   -- outra entidade herdou o netId, marcador diferente
    check('E17 marker diferente → storage_identity', simLoadFlow(1, 20, chopWheel(10, 1, 'wheel_rf')).err == 'storage_identity')

    -- ═══ SELL ═══════════════════════════════════════════════════════════════
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local ws = {}
    for _, pk in ipairs({ 'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr' }) do
        local id = chopWheel(10, 1, pk); ws[#ws + 1] = id; simLoadFlow(1, 20, id)
    end
    local sid = TruckStorage.Peek(20)
    check('E18 4 entitlements STORED → count = 4', TruckStorage.Count(sid) == 4)

    -- E19 payment fail → continuam STORED
    PAY_OK = false
    local r19 = simSellFlow(1, 20)
    check('E19 payment fail → err=payment', r19.err == 'payment')
    check('E19 os 4 continuam STORED', TruckStorage.Count(sid) == 4)
    check('E19 nenhum dinheiro', netMoney == 0)
    PAY_OK = true

    -- E20 payment OK → 4 SOLD, storage vazio
    local r20 = simSellFlow(1, 20)
    check('E20 venda ok, count = 4', r20.ok == true and r20.count == 4)
    check('E20 os 4 → SOLD', (function()
        for _, id in ipairs(ws) do if TyreEntitlement.State(id) ~= 'SOLD' then return false end end; return true
    end)())
    check('E20 storage vazio (count 0)', TruckStorage.Count(sid) == 0)
    check('E20 dinheiro = 4 * 400', netMoney == 1600)

    -- E20b · CommitSold PARCIAL (1 entitlement virou LOST durante o pagamento) → estorno
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local q1 = chopWheel(10, 1, 'wheel_lf'); local q2 = chopWheel(10, 1, 'wheel_rf')
    simLoadFlow(1, 20, q1); simLoadFlow(1, 20, q2)
    SELL_MIDPAY_HOOK = function(ids) TyreEntitlement.MarkLost(ids[1], 'mid_pay') end
    local r20b = simSellFlow(1, 20)
    SELL_MIDPAY_HOOK = nil
    check('E20b venda parcial: só 1 vendido', r20b.ok == true and r20b.count == 1)
    check('E20b dinheiro líquido = 1 * 400 (estorno do outro)', netMoney == 400)
    check('E20b um LOST + um SOLD', (function()
        local s = { [TyreEntitlement.State(q1)] = true, [TyreEntitlement.State(q2)] = true }
        return s.LOST and s.SOLD
    end)())

    -- E20c · venda parcial + ESTORNO FALHA → quarentena econômica fail-closed
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local z1 = chopWheel(10, 1, 'wheel_lf'); local z2 = chopWheel(10, 1, 'wheel_rf')
    simLoadFlow(1, 20, z1); simLoadFlow(1, 20, z2)
    SELL_MIDPAY_HOOK = function(ids) TyreEntitlement.MarkLost(ids[1], 'mid_pay') end
    REFUND_OK = false
    local r20c = simSellFlow('key:1', 20)
    SELL_MIDPAY_HOOK = nil; REFUND_OK = true
    check('E20c venda parcial: 1 vendido', r20c.ok == true and r20c.count == 1)
    check('E20c um SOLD + um LOST (ledger NÃO revertido)', (function()
        local s = { [TyreEntitlement.State(z1)] = true, [TyreEntitlement.State(z2)] = true }
        return s.LOST and s.SOLD
    end)())
    check('E20c player quarantined (dívida = 400)', TyreSaleQuarantine['key:1'] == 400)
    local mBefore = netMoney
    local r20d = simSellFlow('key:1', 20)
    check('E20c nova venda → transaction_locked', r20d.err == 'transaction_locked')
    check('E20c nenhum novo BridgeAddCash', netMoney == mBefore)

    -- E21 retry após success → no_tyres, sem segundo payout
    local before = netMoney
    local r21 = simSellFlow(1, 20)
    check('E21 retry → no_tyres', r21.err == 'no_tyres')
    check('E21 sem segundo payout', netMoney == before)

    -- E22 dois sellers mesmo storage → no máximo 1 payout (2º vê lock OU storage vazio)
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w22 = chopWheel(10, 1, 'wheel_lf'); simLoadFlow(1, 20, w22)
    local s1 = simSellFlow(1, 20)
    local s2 = simSellFlow(2, 20)
    check('E22 primeiro paga, segundo não', s1.ok == true and s2.ok ~= true)
    check('E22 entitlement SOLD 1×', TyreEntitlement.State(w22) == 'SOLD')

    -- E22b SOLD nunca volta p/ STORED (replay)
    check('E22b MarkStored sobre SOLD → bad_state', select(2, TyreEntitlement.MarkStored(w22, 'ts:1')) ~= nil
        and TyreEntitlement.State(w22) == 'SOLD')

    -- E23 load durante sale → storage busy
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w23 = chopWheel(10, 1, 'wheel_lf'); local r = simLoadFlow(1, 20, w23)
    TruckStorageBusy[r.storageId] = true   -- simula venda em curso
    local w23b = chopWheel(10, 1, 'wheel_rf')
    check('E23 load com storage travado → truck_busy', simLoadFlow(1, 20, w23b).err == 'truck_busy')
    TruckStorageBusy[r.storageId] = nil

    -- ═══ CLEANUP ═══════════════════════════════════════════════════════════
    -- E24 playerDropped com REMOVED → LOST
    fresh(); spawn(10, 111); legitRaise(10, 1)
    local w24 = chopWheel(10, 1, 'wheel_lf')
    TyreEntitlement.CleanupPlayer(1)
    check('E24 REMOVED do player que saiu → LOST', TyreEntitlement.State(w24) == 'LOST')

    -- E25 playerDropped com STORED → continua STORED
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w25 = chopWheel(10, 1, 'wheel_lf'); simLoadFlow(1, 20, w25)
    TyreEntitlement.CleanupPlayer(1)
    check('E25 STORED não depende do player → continua STORED', TyreEntitlement.State(w25) == 'STORED')

    -- E26 truck entityRemoved → STORED → LOST
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local w26 = chopWheel(10, 1, 'wheel_lf'); local r26 = simLoadFlow(1, 20, w26)
    TruckStorage.OnTruckRemoved(20)
    check('E26 truck sumiu → STORED vira LOST', TyreEntitlement.State(w26) == 'LOST')
    check('E26 storage removido', TruckStorage._test._all()[r26.storageId] == nil)
    check('E26 sell no truck que sumiu → no_storage/no_tyres', simSellFlow(1, 20).ok ~= true)

    -- E27 source ChopSession CleanupVehicle → entitlement permanece
    fresh(); spawn(10, 111); legitRaise(10, 1)
    local w27 = chopWheel(10, 1, 'wheel_lf')
    FAKE_VEH[10] = nil; ChopSession.CleanupVehicle(10)
    check('E27 CleanupVehicle → entitlement REMOVED intacto', TyreEntitlement.State(w27) == 'REMOVED')
    check('E27 provenance ainda legível', TyreEntitlement.Get(w27).source.partKey == 'wheel_lf')

    -- E28 GetPendingForPlayer (recuperação read-only)
    fresh(); spawn(10, 111); legitRaise(10, 1); spawnTruck(20, 555)
    local p1 = chopWheel(10, 1, 'wheel_lf'); local p2 = chopWheel(10, 1, 'wheel_rf')
    simLoadFlow(1, 20, p2)   -- p2 vira STORED
    local pend = TyreEntitlement.GetPendingForPlayer(1)
    check('E28 pending só REMOVED do src (p1, não p2)', #pend == 1 and pend[1].id == p1)
    check('E28 não cria nada', (function()
        local c = 0; for _ in pairs(TyreEntitlement._test._all()) do c = c + 1 end; return c == 2
    end)())

    print(('[tyre_entitlement/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then print('[tyre_entitlement/spec] \27[31mHÁ FALHAS.\27[0m') end
end)
