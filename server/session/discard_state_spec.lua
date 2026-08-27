-- server/session/discard_state_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-D] Self-test do UNIFIED DISCARD + OWNED/DELETE SAFETY. NÃO roda em
--  produção (self-gated na convar vp_chopshop_selftest 1).
--
--  Cobre: VPChopDiscardState.* + BridgeResolveVehiclePersistence /
--  BridgeDeleteWorldVehicle + o FREEZE da ChopSession em READY_FOR_DISCARD +
--  a COMPOSIÇÃO da transação terminal (`simDiscardFlow` espelha o commit-point
--  do callback vp_chopshop:discardVehicle em server/main.lua).
--
--  Fora daqui (TEST_PLAN de servidor): exports reais do qbx_vehicles/qbx_core,
--  deleção real da entidade, entityRemoved → CleanupVehicle, retries de deleção,
--  multiplayer real com yield de BridgeAddCash.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[discard_state/spec] PASS  ' .. name)
    else fail = fail + 1; print('[discard_state/spec] FAIL  ' .. name) end
end

local ENTITY_API = {
    get    = function(netId) return FAKE_VEH[netId] and (netId + 70000) or 0 end,
    exists = function(h) return h ~= nil and h ~= 0 end,
    model  = function(h) local n = (h or 0) - 70000; return FAKE_VEH[n] and FAKE_VEH[n].model or 0 end,
    plate  = function() return 'PLATE' end,
    owned  = function() return nil end,
    tag    = function(h, vsid) local n = h - 70000; if FAKE_VEH[n] then FAKE_VEH[n].mark = vsid end; return FAKE_VEH[n] and FAKE_VEH[n].mark == vsid end,
    marker = function(h) local n = h - 70000; return FAKE_VEH[n] and FAKE_VEH[n].mark or nil end,
}
local function spawn(netId, model) FAKE_VEH[netId] = { model = model or 111 } end
local function despawn(netId) FAKE_VEH[netId] = nil end

-- Estado de teste controlável
local PAY_OK        = true
local REG_BY_ID     = {}   -- vehicleId → PlayerVehicle
local REG_BY_PLATE  = {}   -- plate     → vehicleId
FAKE_EXPORTS.qbx_vehicles = {
    GetPlayerVehicle    = function(_, id) return REG_BY_ID[id] end,
    GetVehicleIdByPlate = function(_, plate) return REG_BY_PLATE[plate] end,
    DeletePlayerVehicles = function() return true end,
}
FAKE_EXPORTS.qbx_core = { DisablePersistence = function() end }

local COMP_OK = true         -- BridgeRemoveCash (compensação) devolve isto
local netMoney = 0           -- soma líquida de payouts − compensações no fluxo simulado
local DiscardBusy = {}       -- espelha o mutex de main.lua (keyed por sessionId)
local Quarantine  = {}       -- espelha DiscardQuarantine de main.lua

local function fresh()
    ChopSession._test.setEntityAPI(ENTITY_API)
    ChopSession._test.reset()
    for k in pairs(FAKE_VEH) do FAKE_VEH[k] = nil end
    for k in pairs(DiscardBusy) do DiscardBusy[k] = nil end
    for k in pairs(Quarantine) do Quarantine[k] = nil end
    for k in pairs(REG_BY_ID) do REG_BY_ID[k] = nil end
    for k in pairs(REG_BY_PLATE) do REG_BY_PLATE[k] = nil end
    for i = #_TRIGGERED, 1, -1 do _TRIGGERED[i] = nil end
    Config.ChopSession.Enable = true
    Config.ChopSession.EnforceRaised = true
    Config.Discard.MinPartsToDiscard = 4
    Config.Discard.OwnedPolicy = 'deny'
    PAY_OK, COMP_OK, netMoney = true, true, 0
    FAKE_RESOURCES.qbx_core, FAKE_RESOURCES.qbx_vehicles = 'started', 'started'
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() end
    VPChopMDT.GetRealPlate = function(p) return p end
    _G.VPChopDBReady = true   -- default: DB pronto (caminho normal not_owned)
end

-- Leva uma sessão (com peças) até COMPLETED (tombstone) pelo caminho da fachada.
local function driveToTombstone(netId, src)
    local sid = ChopSession.GetByVehicle(netId).id
    VPChopDiscardState.begin(sid)
    VPChopDiscardState.complete(sid)
    return sid
end

local function legitRaise(netId, src)
    local s = ChopSession.Create(netId, src)
    if not s then return nil end
    ChopSession.AddParticipant(s.id, src); ChopSession.MarkRaised(s.id, src)
    return s
end

-- Popula a sessão com N peças base e M advanced (via as fachadas reais).
local function seedParts(netId, src, nBase, nAdv)
    local sid = ChopSession.GetByVehicle(netId).id
    for i = 1, (nBase or 0) do ChopSession.MarkPart(sid, 'b' .. i, src, { origin = 'base' }) end
    for i = 1, (nAdv or 0) do ChopSession.MarkPart(sid, 'a' .. i, src, { origin = 'advanced' }) end
    return sid
end

local function countCarDiscarded()
    local c = 0
    for _, e in ipairs(_TRIGGERED) do if e.evt == VPChopEvt.CAR_DISCARDED then c = c + 1 end end
    return c
end

-- Espelha o commit-point de vp_chopshop:discardVehicle (entidade/distância já OK).
-- Retorna { ok, err, payout, counts }. `compensated` marca BridgeRemoveCash chamado.
local function simDiscardFlow(src, netId)
    local minParts = math.floor(tonumber(Config.Discard.MinPartsToDiscard) or 4)
    local sessionId = VPChopDiscardState.resolve(netId)
    if not sessionId then return { ok = false, err = 'parts_min', count = 0 } end
    if Quarantine[sessionId] then return { ok = false, err = 'transaction_locked' } end
    if DiscardBusy[sessionId] then return { ok = false, err = 'processing' } end
    DiscardBusy[sessionId] = netId
    local function rel(r) DiscardBusy[sessionId] = nil; return r end

    local veh = NetworkGetEntityFromNetworkId(netId)
    local persistence = BridgeResolveVehiclePersistence(veh, 'discard')
    if persistence.status ~= 'not_owned' then
        return rel({ ok = false, err = 'owned', persistence = persistence.status })
    end

    local counts = VPChopDiscardState.getCounts(sessionId)
    if counts.total < minParts then
        return rel({ ok = false, err = 'parts_min', count = counts.total, counts = counts })
    end

    local payout = 1500
    if not VPChopDiscardState.begin(sessionId) then return rel({ ok = false, err = 'transaction' }) end

    if not PAY_OK then
        VPChopDiscardState.rollback(sessionId)
        return rel({ ok = false, err = 'payment', counts = counts })
    end
    netMoney = netMoney + payout   -- BridgeAddCash ok

    local cOk = VPChopDiscardState.complete(sessionId)
    if not cOk then
        local compensated = COMP_OK   -- BridgeRemoveCash
        if compensated then
            netMoney = netMoney - payout
            VPChopDiscardState.rollback(sessionId)   -- READY_FOR_DISCARD → DISMANTLING
            return rel({ ok = false, err = 'transaction', compensated = true })
        end
        -- compensação falhou → QUARENTENA (sessão fica READY_FOR_DISCARD + frozen)
        Quarantine[sessionId] = netId
        return rel({ ok = false, err = 'transaction_locked', compensated = false })
    end

    _TRIGGERED[#_TRIGGERED + 1] = { evt = VPChopEvt.CAR_DISCARDED, args = { src, netId, 'PLATE', payout } }
    return rel({ ok = true, payout = payout, counts = counts })
end

CreateThread(function()
    Wait(1000)

    -- ─── D1–D5 · CONTAGEM UNIFICADA ─────────────────────────────────────────────
    fresh(); spawn(10, 111); legitRaise(10, 1)
    local sid = seedParts(10, 1, 2, 2)   -- 2 base + 2 advanced
    check('D1 CountParts total (base+advanced) = 4', ChopSession.CountParts(sid) == 4)
    check('D2 VPChopGetPartCount ainda é base-only = 2', VPChopGetPartCount(10) == 2)
    local counts = VPChopDiscardState.getCounts(sid)
    check('D3 getCounts.total = 4', counts.total == 4)
    check('D3 getCounts.base = 2 / advanced = 2', counts.base == 2 and counts.advanced == 2)
    check('D4 discard usa TOTAL: 4 >= min 4 → ok', simDiscardFlow(1, 10).ok == true)

    fresh(); spawn(11, 111); legitRaise(11, 1)
    seedParts(11, 1, 2, 1)   -- total 3
    check('D5 total=3 < min 4 → parts_min', (function()
        local r = simDiscardFlow(1, 11); return r.err == 'parts_min' and r.count == 3
    end)())

    -- ─── D6 · DOIS PLAYERS, MESMA SESSÃO → NO MÁXIMO 1 PAYOUT ────────────────────
    fresh(); spawn(20, 111); local s20 = legitRaise(20, 1)
    ChopSession.AddParticipant(s20.id, 2)
    seedParts(20, 1, 4, 0)
    local a = simDiscardFlow(1, 20)
    local b = simDiscardFlow(2, 20)   -- sessão já COMPLETED (terminal) → resolve nil
    check('D6 primeiro paga', a.ok == true and a.payout == 1500)
    check('D6 segundo NÃO paga (sessão terminal)', b.ok ~= true)
    check('D6 CAR_DISCARDED exatamente 1×', countCarDiscarded() == 1)

    -- D6b · lock explícito (mutex por sessão)
    fresh(); spawn(20, 111); legitRaise(20, 1); local s20b = seedParts(20, 1, 4, 0)
    DiscardBusy[s20b] = 20
    check('D6b sessão já travada → processing', simDiscardFlow(1, 20).err == 'processing')

    -- ─── D7 · PAGAMENTO FALHOU → ROLLBACK, NADA PERDIDO ─────────────────────────
    fresh(); spawn(30, 111); legitRaise(30, 1); local s30 = seedParts(30, 1, 4, 0)
    PAY_OK = false
    local r7 = simDiscardFlow(1, 30)
    check('D7 err=payment', r7.err == 'payment')
    check('D7 sessão voltou a DISMANTLING (rollback)', ChopSession._test._sessions()[s30].state == 'DISMANTLING')
    check('D7 sessão NÃO foi completada', ChopSession._test._sessions()[s30].completed ~= true)
    check('D7 nenhum CAR_DISCARDED', countCarDiscarded() == 0)
    check('D7 peças intactas (4)', ChopSession.CountParts(s30) == 4)
    PAY_OK = true
    check('D7 retry após pagamento voltar → ok, 1 payout', (function()
        local r = simDiscardFlow(1, 30); return r.ok == true and countCarDiscarded() == 1
    end)())

    -- ─── D8/D9 · FREEZE EM READY_FOR_DISCARD ────────────────────────────────────
    fresh(); spawn(40, 111); legitRaise(40, 1); local s40 = seedParts(40, 1, 4, 0)
    check('D8 begin → READY_FOR_DISCARD', VPChopDiscardState.begin(s40) == true
        and ChopSession._test._sessions()[s40].state == 'READY_FOR_DISCARD')
    local mOk, mDup, mErr = ChopSession.MarkPart(s40, 'novo', 1, { origin = 'base' })
    check('D8 MarkPart nova peça → DENY discarding', mOk == false and mErr == 'discarding')
    check('D8 contagem não mudou (4)', ChopSession.CountParts(s40) == 4)
    local lOk, lErr = ChopSession.LockPart(s40, 'x')
    check('D9 LockPart novo → DENY discarding', lOk == false and lErr == 'discarding')
    check('D9 base_state.markPart propaga discarding', (function()
        local o, _, e = VPChopBaseState.markPart(1, 40, 'novo2'); return o == false and e == 'discarding'
    end)())

    -- ─── D10 · PAGAMENTO OK → COMPLETE EXATAMENTE 1× ────────────────────────────
    fresh(); spawn(50, 111); legitRaise(50, 1); local s50 = seedParts(50, 1, 4, 0)
    check('D10 fluxo ok', simDiscardFlow(1, 50).ok == true)
    check('D10 sessão COMPLETED', ChopSession._test._sessions()[s50].state == 'COMPLETED')
    check('D10 Complete idempotente (2ª chamada true, sem efeito extra)', VPChopDiscardState.complete(s50) == true)
    check('D10 resolve devolve nil (terminal)', VPChopDiscardState.resolve(50) == nil)

    -- ─── D11 · COMPLETE FALHA PÓS-PAYMENT → COMPENSA, SEM DOUBLE PAYOUT ─────────
    fresh(); spawn(60, 111); legitRaise(60, 1); local s60 = seedParts(60, 1, 4, 0)
    local realComplete = ChopSession.Complete
    ChopSession.Complete = function() return false, 'simulated' end
    local r11 = simDiscardFlow(1, 60)
    ChopSession.Complete = realComplete
    check('D11 err=transaction', r11.err == 'transaction')
    check('D11 compensação sinalizada', r11.compensated == true)
    check('D11 nenhum CAR_DISCARDED', countCarDiscarded() == 0)
    check('D11 compensação OK → rollback DISMANTLING (retry legítimo)',
        ChopSession._test._sessions()[s60].state == 'DISMANTLING')
    check('D11 líquido zerado', netMoney == 0)
    -- retry com Complete normal → paga UMA vez (compensação zerou o payout órfão)
    check('D11 retry → 1 payout único', (function()
        local r = simDiscardFlow(1, 60); return r.ok == true and countCarDiscarded() == 1
    end)())

    -- ─── D12–D17 · OWNERSHIP ────────────────────────────────────────────────────
    -- D12: state.vehicleid + registro confirma → owned
    fresh(); spawn(70, 111); FAKE_VEH[70].vehicleid = 999; REG_BY_ID[999] = { citizenid = 'ABC' }
    legitRaise(70, 1); seedParts(70, 1, 4, 0)
    check('D12 state.vehicleid + registro → owned', BridgeResolveVehiclePersistence(70 + 70000, 'x').status == 'owned')
    check('D13 owned + policy deny → discard DENY antes de payout', (function()
        local r = simDiscardFlow(1, 70)
        return r.err == 'owned' and countCarDiscarded() == 0
    end)())
    check('D13 sessão intacta (não entrou em READY_FOR_DISCARD)',
        ChopSession.GetByVehicle(70).state == 'DISMANTLING')

    -- D14: fake plate + vehicleid válido → continua owned (não depende da placa visível)
    fresh(); spawn(71, 111); FAKE_VEH[71].vehicleid = 555; REG_BY_ID[555] = { citizenid = 'X' }
    check('D14 fake plate irrelevante: state id manda → owned',
        BridgeResolveVehiclePersistence(71 + 70000, 'x').status == 'owned')

    -- D15: sem state id, lookup por placa real confirma → owned
    fresh(); spawn(72, 111); REG_BY_PLATE['PLATE'] = 777; REG_BY_ID[777] = { citizenid = 'Y' }
    local p15 = BridgeResolveVehiclePersistence(72 + 70000, 'x')
    check('D15 sem state id + qbx_vehicles confirma → owned', p15.status == 'owned' and p15.source == 'qbx_vehicles_plate')

    -- D16: state id existe mas registro NÃO confirma → unknown (fail-closed)
    fresh(); spawn(73, 111); FAKE_VEH[73].vehicleid = 111   -- REG_BY_ID[111] vazio
    legitRaise(73, 1); seedParts(73, 1, 4, 0)
    check('D16 state id órfão → unknown', BridgeResolveVehiclePersistence(73 + 70000, 'x').status == 'unknown')
    check('D16 unknown → discard DENY (fail-closed)', simDiscardFlow(1, 73).err == 'owned')

    -- D17: nenhum registro → not_owned → fluxo normal
    fresh(); spawn(74, 111); legitRaise(74, 1); seedParts(74, 1, 4, 0)
    check('D17 sem registro → not_owned', BridgeResolveVehiclePersistence(74 + 70000, 'x').status == 'not_owned')
    check('D17 not_owned → discard ok', simDiscardFlow(1, 74).ok == true)

    -- D17b: framework não-QBox → unknown (sem adapter) → fail-closed
    fresh(); spawn(75, 111); FAKE_RESOURCES.qbx_core, FAKE_RESOURCES.qbx_vehicles = 'missing', 'missing'
    legitRaise(75, 1); seedParts(75, 1, 4, 0)
    check('D17b sem QBox → unknown', BridgeResolveVehiclePersistence(75 + 70000, 'x').status == 'unknown')
    check('D17b unknown → DENY', simDiscardFlow(1, 75).err == 'owned')
    FAKE_RESOURCES.qbx_core, FAKE_RESOURCES.qbx_vehicles = 'started', 'started'

    -- D16b: export QBox LANÇA erro (resource instável) → unknown, NUNCA not_owned (fail-closed)
    fresh(); spawn(76, 111); FAKE_VEH[76].vehicleid = 42
    local realGPV = FAKE_EXPORTS.qbx_vehicles.GetPlayerVehicle
    FAKE_EXPORTS.qbx_vehicles.GetPlayerVehicle = function() error('resource crash') end
    check('D16b export erra → unknown (não not_owned)', BridgeResolveVehiclePersistence(76 + 70000, 'x').status == 'unknown')
    -- sem state id + GetVehicleIdByPlate erra → também unknown
    fresh(); spawn(77, 111)
    FAKE_EXPORTS.qbx_vehicles.GetVehicleIdByPlate = function() error('boom') end
    check('D16b plate lookup erra → unknown', BridgeResolveVehiclePersistence(77 + 70000, 'x').status == 'unknown')
    FAKE_EXPORTS.qbx_vehicles.GetPlayerVehicle = realGPV
    FAKE_EXPORTS.qbx_vehicles.GetVehicleIdByPlate = function(_, plate) return REG_BY_PLATE[plate] end

    -- ─── D18–D22 · DELETE WORLD VEHICLE (bridge) ────────────────────────────────
    fresh(); spawn(80, 111)
    local d18 = BridgeDeleteWorldVehicle(80 + 70000)
    check('D18 QBox → method desliga persistence + native', d18.method == 'qbx_disable_persist+native')
    check('D20 delete ok → existsAfter=false, ok=true', d18.ok == true and d18.existsAfter == false)
    check('D20 entidade removida do mundo falso', FAKE_VEH[80] == nil)

    fresh()
    local d22 = BridgeDeleteWorldVehicle(0)   -- handle inválido
    check('D22 handle inválido → noop, sem crash', d22.method == 'noop' and d22.ok == true)

    fresh(); spawn(81, 111); FAKE_RESOURCES.qbx_core = 'missing'
    local d18b = BridgeDeleteWorldVehicle(81 + 70000)
    check('D18b sem qbx_core → method=native', d18b.method == 'native' and d18b.ok == true)
    FAKE_RESOURCES.qbx_core = 'started'

    -- ─── D23–D26 · EVENTOS ─────────────────────────────────────────────────────
    fresh(); spawn(90, 111); legitRaise(90, 1); seedParts(90, 1, 4, 0)
    simDiscardFlow(1, 90)
    check('D23 success → CAR_DISCARDED 1×', countCarDiscarded() == 1)

    fresh(); spawn(91, 111); legitRaise(91, 1); seedParts(91, 1, 4, 0); PAY_OK = false
    simDiscardFlow(1, 91)
    check('D24 payment fail → CAR_DISCARDED 0×', countCarDiscarded() == 0)
    PAY_OK = true

    fresh(); spawn(92, 111); FAKE_VEH[92].vehicleid = 1; REG_BY_ID[1] = {}
    legitRaise(92, 1); seedParts(92, 1, 4, 0)
    simDiscardFlow(1, 92)
    check('D25 owned deny → CAR_DISCARDED 0×', countCarDiscarded() == 0)

    fresh(); spawn(93, 111); legitRaise(93, 1); seedParts(93, 1, 2, 0)
    simDiscardFlow(1, 93)
    check('D26 parts_min → CAR_DISCARDED 0×', countCarDiscarded() == 0)

    -- ─── D27 · ROLLBACK/COMPLETE respeitam FSM ─────────────────────────────────
    fresh(); spawn(94, 111); legitRaise(94, 1); local s94 = seedParts(94, 1, 4, 0)
    check('D27 rollback sem begin → no-op true', VPChopDiscardState.rollback(s94) == true)
    check('D27 complete sem READY_FOR_DISCARD → bad_state', (select(1, VPChopDiscardState.complete(s94))) == false)

    -- ═══ HARDENINGS (follow-up review PR #7) ═══════════════════════════════════

    -- ─── TX1 · payment OK → Complete FAIL → compensation OK ────────────────────
    fresh(); spawn(100, 111); legitRaise(100, 1); local s100 = seedParts(100, 1, 4, 0)
    local realComplete = ChopSession.Complete
    ChopSession.Complete = function() return false, 'sim' end
    local tx1 = simDiscardFlow(1, 100)
    ChopSession.Complete = realComplete
    check('TX1 err=transaction', tx1.err == 'transaction')
    check('TX1 dinheiro líquido = 0', netMoney == 0)
    check('TX1 rollback → DISMANTLING', ChopSession._test._sessions()[s100].state == 'DISMANTLING')
    check('TX1 mutex liberado', DiscardBusy[s100] == nil)
    check('TX1 NÃO quarantined', Quarantine[s100] == nil)
    check('TX1 CAR_DISCARDED = 0 no 1º attempt', countCarDiscarded() == 0)
    check('TX1 retry legítimo → ok, 1 payout, líquido 1500', (function()
        local r = simDiscardFlow(1, 100)
        return r.ok == true and countCarDiscarded() == 1 and netMoney == 1500
    end)())

    -- ─── TX2 · payment OK → Complete FAIL → compensation FAIL ──────────────────
    fresh(); spawn(101, 111); legitRaise(101, 1); local s101 = seedParts(101, 1, 4, 0)
    ChopSession.Complete = function() return false, 'sim' end
    COMP_OK = false
    local tx2 = simDiscardFlow(1, 101)
    ChopSession.Complete = realComplete
    check('TX2 err=transaction_locked', tx2.err == 'transaction_locked')
    check('TX2 sessão permanece READY_FOR_DISCARD', ChopSession._test._sessions()[s101].state == 'READY_FOR_DISCARD')
    check('TX2 quarantined', Quarantine[s101] == 101)
    check('TX2 frozen (MarkPart → discarding)', (select(3, ChopSession.MarkPart(s101, 'zz', 1))) == 'discarding')
    check('TX2 CAR_DISCARDED = 0', countCarDiscarded() == 0)
    local moneyBefore = netMoney
    local tx2b = simDiscardFlow(1, 101)
    check('TX2 retry → transaction_locked', tx2b.err == 'transaction_locked')
    check('TX2 BridgeAddCash NÃO chamado de novo (líquido inalterado)', netMoney == moneyBefore)
    check('TX2 CAR_DISCARDED ainda 0', countCarDiscarded() == 0)
    COMP_OK = true

    -- ─── OWN1 · state id ausente + GetRealPlate lança erro → unknown ──────────
    fresh(); spawn(110, 111)
    VPChopMDT.GetRealPlate = function() error('resolver down') end
    check('OWN1 GetRealPlate erra → unknown (não cai p/ placa visível)',
        BridgeResolveVehiclePersistence(110 + 70000, 'x').status == 'unknown')
    VPChopMDT.GetRealPlate = function(p) return p end

    -- ─── OWN2 · state id ausente + DB/resolver indisponível → unknown ─────────
    fresh(); spawn(111, 111); _G.VPChopDBReady = false
    check('OWN2A VPChopDBReady=false → unknown', BridgeResolveVehiclePersistence(111 + 70000, 'x').status == 'unknown')
    fresh(); spawn(116, 111); _G.VPChopDBReady = nil
    check('OWN2B VPChopDBReady=nil → unknown', BridgeResolveVehiclePersistence(116 + 70000, 'x').status == 'unknown')
    _G.VPChopDBReady = true
    fresh(); spawn(112, 111)
    local savedGRP = VPChopMDT.GetRealPlate; VPChopMDT.GetRealPlate = nil
    check('OWN2C resolver de placa ausente → unknown', BridgeResolveVehiclePersistence(112 + 70000, 'x').status == 'unknown')
    VPChopMDT.GetRealPlate = savedGRP

    -- ─── OWN3 · GetVehicleIdByPlate → 777 mas GetPlayerVehicle(777) → nil → unknown
    fresh(); spawn(113, 111); REG_BY_PLATE['PLATE'] = 777   -- REG_BY_ID[777] vazio
    check('OWN3 id sem PlayerVehicle → unknown (inconsistente)',
        BridgeResolveVehiclePersistence(113 + 70000, 'x').status == 'unknown')

    -- ─── OWN4 · GetVehicleIdByPlate → valor não-nil inválido → unknown ───────
    fresh(); spawn(114, 111)
    FAKE_EXPORTS.qbx_vehicles.GetVehicleIdByPlate = function() return 'not-a-number' end
    check('OWN4 id inválido não-nil → unknown',
        BridgeResolveVehiclePersistence(114 + 70000, 'x').status == 'unknown')
    FAKE_EXPORTS.qbx_vehicles.GetVehicleIdByPlate = function(_, plate) return REG_BY_PLATE[plate] end

    -- ─── OWN5 · placa vazia + sem state vehicleid → unknown ──────────────────
    fresh(); spawn(115, 111)
    local savedPlate = _G.GetVehicleNumberPlateText
    _G.GetVehicleNumberPlateText = function() return '' end
    check('OWN5 placa vazia → unknown (nunca not_owned)',
        BridgeResolveVehiclePersistence(115 + 70000, 'x').status == 'unknown')
    _G.GetVehicleNumberPlateText = savedPlate

    -- ─── DEL1 · expectedFramework=qbox + DisablePersistence lança erro ───────
    fresh(); spawn(120, 111)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() error('qbx_core crash') end
    local del1 = BridgeDeleteWorldVehicle(120 + 70000, { expectedFramework = 'qbox' })
    check('DEL1 DisablePersistence falha → NÃO deleta', FAKE_VEH[120] ~= nil)
    check('DEL1 method=qbx_disable_persist_failed, existsAfter, retryable',
        del1.method == 'qbx_disable_persist_failed' and del1.existsAfter == true and del1.retryable == true)
    check('DEL1 ok=false', del1.ok == false)
    FAKE_EXPORTS.qbx_core.DisablePersistence = function() end

    -- ─── DEL2 · qbx_core para entre ownership e delete → framework race ──────
    fresh(); spawn(121, 111); FAKE_RESOURCES.qbx_core = 'missing'
    local del2 = BridgeDeleteWorldVehicle(121 + 70000, { expectedFramework = 'qbox' })
    check('DEL2 framework race → NÃO cai p/ native delete', FAKE_VEH[121] ~= nil)
    check('DEL2 method=framework_race, retryable', del2.method == 'framework_race' and del2.retryable == true)
    FAKE_RESOURCES.qbx_core = 'started'

    -- ─── DEL3 · delete inicial falha → retry com identidade confirmada → deleta
    fresh(); spawn(122, 111); legitRaise(122, 1); seedParts(122, 1, 4, 0)
    local s122 = driveToTombstone(122, 1)
    local bound = ChopSession.ResolveBoundVehicleForCleanup(s122)
    check('DEL3 identidade confirmada (tombstone + entidade original)', bound == 122 + 70000)
    local del3 = BridgeDeleteWorldVehicle(bound, { expectedFramework = 'qbox' })
    check('DEL3 retry com identidade OK → deleta', del3.ok == true and FAKE_VEH[122] == nil)

    -- ─── DEL4 · NETID REUSE: veículo original some, outro herda o netId ─────
    fresh(); spawn(123, 111); legitRaise(123, 1); seedParts(123, 1, 4, 0)
    local s123 = driveToTombstone(123, 1)
    FAKE_VEH[123] = { model = 222 }   -- netId 123 agora aponta p/ OUTRO veículo (modelo diferente, sem marker)
    local bound4, reason4 = ChopSession.ResolveBoundVehicleForCleanup(s123)
    check('DEL4 modelo diferente → identity_mismatch', bound4 == nil and reason4 == 'identity_mismatch')
    check('DEL4 veículo NOVO intacto', FAKE_VEH[123] ~= nil and FAKE_VEH[123].model == 222)

    -- ─── DEL4B · marker NUNCA foi cravado (markerSet=false) + netId reuse MESMO modelo
    fresh(); spawn(123, 111); legitRaise(123, 1); seedParts(123, 1, 4, 0)
    local s4b = driveToTombstone(123, 1)
    ChopSession._test._sessions()[s4b].vehicle._fp.markerSet = false   -- runtime não suportou o marcador no mint
    FAKE_VEH[123] = { model = 111 }   -- OUTRO veículo, MESMO netId, MESMO modelo, sem marker
    local b4b, r4b = ChopSession.ResolveBoundVehicleForCleanup(s4b)
    check('DEL4B markerSet=false → identity_unproven (NÃO auto-delete)', b4b == nil and r4b == 'identity_unproven')
    check('DEL4B veículo B intacto (0 DeleteEntity)', FAKE_VEH[123] ~= nil and FAKE_VEH[123].model == 111)

    -- ─── DEL4C · marker cravado no A (vsid A); B mesmo netId+modelo, marker ausente/difere
    fresh(); spawn(123, 111); legitRaise(123, 1); seedParts(123, 1, 4, 0)
    local s4c = driveToTombstone(123, 1)
    check('DEL4C A tinha markerSet=true', ChopSession._test._sessions()[s4c].vehicle._fp.markerSet == true)
    FAKE_VEH[123] = { model = 111 }   -- B: mesmo netId, mesmo modelo, SEM o marker do A
    local b4c, r4c = ChopSession.ResolveBoundVehicleForCleanup(s4c)
    check('DEL4C marker não bate → identity_mismatch (NÃO auto-delete)', b4c == nil and r4c == 'identity_mismatch')
    check('DEL4C veículo B intacto', FAKE_VEH[123] ~= nil)

    -- ─── DEL5 · identidade não confirmável → auto retry aborta, tombstone fica
    fresh(); spawn(124, 111); legitRaise(124, 1); seedParts(124, 1, 4, 0)
    local s124 = driveToTombstone(124, 1)
    despawn(124)   -- entidade sumiu de vez, mas a sessão (tombstone) ainda existe em memória
    local bound5, reason5 = ChopSession.ResolveBoundVehicleForCleanup(s124)
    check('DEL5 entidade sumiu → nil (retry aborta)', bound5 == nil and (reason5 == 'identity_mismatch' or reason5 == 'gone'))
    check('DEL5 tombstone COMPLETED preservado', ChopSession._test._sessions()[s124].state == 'COMPLETED')
    -- sessão não-COMPLETED nunca é alvo de cleanup destrutivo
    fresh(); spawn(125, 111); legitRaise(125, 1); local s125 = seedParts(125, 1, 4, 0)
    check('DEL5 sessão não-tombstone → not_tombstone', (select(2, ChopSession.ResolveBoundVehicleForCleanup(s125))) == 'not_tombstone')

    print(('[discard_state/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then print('[discard_state/spec] \27[31mHÁ FALHAS.\27[0m') end
end)
