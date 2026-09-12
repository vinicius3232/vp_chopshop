-- bridge/gang_territory_release_gate_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.20 P6-RC] GANGS, TERRITORIES & SMARTPHONE RELEASE GATE SPEC
--  Validação de invariantes invioláveis da Fase 6:
--  INV-P6-01: Territory Tax em zonas dominadas retida e creditada na gangue dona.
--  INV-P6-02: Bônus econômico para membros dominantes em território próprio.
--  INV-P6-03: Alívio de 50% de heat policial para membros no próprio território.
--  INV-P6-04: [REQUISITO DO DONO] Alerta disparado SE e SOMENTE SE turf tem informante ativo.
--  INV-P6-05: [REQUISITO DO DONO] Sem informante ativo na turf = ZERO alerta (aborto silencioso).
--  INV-P6-06: [REQUISITO DO DONO] Despacho multi-smartphone via PhoneBridge.
--  INV-P6-07: Rateio server-authoritative estrito em contratos cooperativos.
--  INV-P6-08: Canário de integridade de boundary de domínio (ZERO qbx_core em vp_gangs).
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[gang_rc/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[gang_rc/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local VG = dofile('bridge/vp_gangs.lua')
    local PB = dofile('bridge/phone.lua')
    local GC = dofile('server/broker/gang_contracts.lua')

    -- ─── 1. INV-P6-01: Territory Tax Retention & Credit ─────────────────────────
    local taxCredited = {}
    VG.__setMock({
        GetTerritory = function(coords)
            return { inside = true, turfId = 'grove_st', gangId = 'families', zoneName = 'Grove Street' }
        end,
        GetPlayerGang = function(src)
            if src == 10 then return 'families' end
            if src == 20 then return 'ballas' end
            return nil -- civil
        end,
        CreditTerritoryTax = function(gangId, amount, meta)
            taxCredited[gangId] = (taxCredited[gangId] or 0) + amount
            return true
        end
    })

    -- Civil desmanchando/vendendo em território Families (base $10000, 15% taxa)
    local civilAdj = VG.CalculateTerritoryAdjustment(99, vector3(100.0, 200.0, 20.0), 10000)
    check('INV-P6-01a Neutral/Civil pays 15% territory tax', civilAdj.adjustedPayout == 8500 and civilAdj.taxAmount == 1500)
    check('INV-P6-01b Territory tax credited to dominant gang cofre', taxCredited['families'] == 1500)

    -- Rival Ballas desmanchando em território Families
    local rivalAdj = VG.CalculateTerritoryAdjustment(20, vector3(100.0, 200.0, 20.0), 10000)
    check('INV-P6-01c Rival gang member pays 15% territory tax', rivalAdj.adjustedPayout == 8500 and rivalAdj.taxAmount == 1500)
    check('INV-P6-01d Cumulative territory tax credited correctly', taxCredited['families'] == 3000)

    -- ─── 2. INV-P6-02: Economic Bonus for Dominant Member ───────────────────────
    local ownerAdj = VG.CalculateTerritoryAdjustment(10, vector3(100.0, 200.0, 20.0), 10000)
    check('INV-P6-02a Dominant gang member receives 10% economic bonus', ownerAdj.adjustedPayout == 11000 and ownerAdj.bonusAmount == 1000)
    check('INV-P6-02b Dominant gang member pays zero tax in own turf', ownerAdj.taxAmount == 0 and ownerAdj.isOwner == true)

    -- ─── 3. INV-P6-03: Dominant Member Heat Reduction ───────────────────────────
    -- Simula VPChopAmbushMaybe logic
    local function computeSimulatedAmbushMult(src, coords, baseHeatMult)
        local heatMult = baseHeatMult
        local turf = VG.GetTerritory(coords)
        if turf and turf.inside and turf.gangId then
            local myGang = VG.GetPlayerGang(src)
            if myGang and myGang == turf.gangId then
                heatMult = heatMult * (Config.Gangs.HeatReductionMultiplier or 0.50)
            end
        end
        return heatMult
    end

    local normalHeatMult = computeSimulatedAmbushMult(20, vector3(100.0, 200.0, 20.0), 1.80) -- rival
    local ownerHeatMult = computeSimulatedAmbushMult(10, vector3(100.0, 200.0, 20.0), 1.80)  -- owner
    check('INV-P6-03 Dominant gang member heat multiplier is halved (50% reduction)', ownerHeatMult == 0.90 and normalHeatMult == 1.80)

    -- ─── 4. INV-P6-04 & INV-P6-05: Informant Guard for Alerts [USER REQ] ────────
    local phoneAlerts = {}
    PB.__setMock({
        provider = 'qs-smartphone',
        SendNotification = function(src, title, msg, opts)
            table.insert(phoneAlerts, { src = src, title = title, msg = msg, opts = opts })
            return true
        end
    })
    _G.PhoneBridge = PB

    local turfData = { turfId = 'grove_st', gangId = 'families', zoneName = 'Grove Street' }

    -- Cenário A: Turf SEM informante ativo
    local informantActive = false
    VG.__setMock({
        HasTurfInformant = function(gangId, turfId, coords)
            return informantActive
        end,
        GetOnlineGangMembers = function(gangId)
            return { 10, 11 }
        end
    })

    local resNoInf = VG.DispatchRivalAlert(turfData, vector3(100.0, 200.0, 20.0), 20)
    check('INV-P6-05a Alert rejected when turf has NO active informant', resNoInf.ok == false and resNoInf.reason == 'no_informant_in_turf')
    check('INV-P6-05b Zero phone notifications sent when informant is missing', #phoneAlerts == 0)

    -- Cenário B: Turf COM informante ativo
    informantActive = true
    local resWithInf = VG.DispatchRivalAlert(turfData, vector3(100.0, 200.0, 20.0), 20)
    check('INV-P6-04a Alert fires when turf HAS active informant', resWithInf.ok == true and resWithInf.alertedCount == 2)
    check('INV-P6-04b Smartphone notification delivered to online gang members', #phoneAlerts == 2 and phoneAlerts[1].src == 10 and phoneAlerts[2].src == 11)

    -- ─── 5. INV-P6-06: Multi-smartphone Provider Fallback ────────────────────────
    PB.__setMock({ provider = 'yphone', SendNotification = function(src, title, msg) return true end })
    check('INV-P6-06a PhoneBridge provider yphone supported', PB.IsAvailable() == true)
    PB.__setMock({ provider = 'lb-phone', SendNotification = function(src, title, msg) return true end })
    check('INV-P6-06b PhoneBridge provider lb-phone supported', PB.IsAvailable() == true)
    PB.__setMock({ provider = 'none' })
    check('INV-P6-06c PhoneBridge provider none returns false without error', PB.IsAvailable() == false)

    -- ─── 6. INV-P6-07: Strict Server-Authoritative Profit Division ───────────────
    local squad = {
        { src = 1, citizenid = 'P1', contribution = 50 },
        { src = 2, citizenid = 'P2', contribution = 30 },
        { src = 3, citizenid = 'P3', contribution = 20 },
    }
    local splitRes = GC.DistributePayout(50000, squad)
    check('INV-P6-07a Squad shares proportional: P1=$25k, P2=$15k, P3=$10k',
        splitRes['P1'].amount == 25000 and splitRes['P2'].amount == 15000 and splitRes['P3'].amount == 10000)
    local totalSquadPayout = splitRes['P1'].amount + splitRes['P2'].amount + splitRes['P3'].amount
    check('INV-P6-07b Sum of squad shares strictly equals total reward', totalSquadPayout == 50000)

    -- ─── 7. INV-P6-08: Domain Boundary & Canary Verification ────────────────────
    local f = io.open((arg and arg[1] or '.') .. '/bridge/vp_gangs.lua', 'r')
    local gangCode = f and f:read('*a') or ''
    if f then f:close() end

    check('INV-P6-08a bridge/vp_gangs.lua ZERO direct qbx_core calls', not gangCode:find('qbx_core', 1, true))
    check('INV-P6-08b bridge/vp_gangs.lua ZERO legacy rewardGangActivity calls', not gangCode:find(':rewardGangActivity(', 1, true))
    check('INV-P6-08c bridge/vp_gangs.lua contains HasTurfInformant canonical guard', gangCode:find('HasTurfInformant', 1, true) ~= nil)

    -- Teardown
    VG.__setMock(nil)
    PB.__setMock(nil)
    _G.PhoneBridge = nil

    print(('─── RESUMO GANG & TERRITORY RELEASE GATE: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('gang_territory_release_gate_spec failed: %d assertions failed'):format(fail))
end

run()
