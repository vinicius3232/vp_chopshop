-- server/evidence_bridge_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 FORENSICS V2] EvidenceBridge Specification & Multi-Provider Test Suite
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass = 0
    local fail = 0
    local total = 0

    local function check(desc, cond)
        total = total + 1
        if cond then
            pass = pass + 1
            print(('[evidence/spec] PASS  %s'):format(desc))
        else
            fail = fail + 1
            print(('[evidence/spec] FAIL  %s'):format(desc))
        end
    end

    -- Setup base state
    local origCfg = Config.Evidence
    Config.Evidence = {
        Enable = true,
        Provider = 'auto',
        GlovesItem = 'gloves',
        GlovesBlocksDna = false,
        DnaType = 'blood',
        HeatScaling = true,
        HeatFactor = 0.5,
        Actions = {
            chop_part   = { fingerprint = 1.0, dna = 1.0 },
            vin_scratch = { fingerprint = 1.0, dna = 1.0 },
            plate_steal = { fingerprint = 1.0, dna = 1.0 },
            plate_forge = { fingerprint = 1.0, dna = 1.0 },
            plate_apply = { fingerprint = 1.0, dna = 1.0 },
        },
    }

    local mockInventory = {}
    _G.InvCount = function(src, item)
        return (mockInventory[src] and mockInventory[src][item]) or 0
    end
    _G.IsValidSource = function(src)
        return type(src) == 'number' and src > 0
    end
    _G.VPChopHeatCalc = function(plate)
        if plate == 'HOT_PLATE' then return 100 end
        if plate == 'WARM_PLATE' then return 50 end
        return 0
    end

    -- ─── 1. Provider Resolution & Availability ───────────────────────────────
    do
        EvidenceBridge._test.reset()
        check('EVID-PROV-01 EvidenceBridge module exists', type(EvidenceBridge) == 'table')
        check('EVID-PROV-01 EvidenceBridge.GetProvider is a function', type(EvidenceBridge.GetProvider) == 'function')
        check('EVID-PROV-01 EvidenceBridge.IsAvailable is a function', type(EvidenceBridge.IsAvailable) == 'function')
        check('EVID-PROV-01 EvidenceBridge.Plant is a function', type(EvidenceBridge.Plant) == 'function')

        -- Disabled in Config
        Config.Evidence.Enable = false
        check('EVID-PROV-02 Config.Evidence.Enable=false returns provider none', EvidenceBridge.GetProvider() == 'none')
        check('EVID-PROV-02 Config.Evidence.Enable=false is not available', EvidenceBridge.IsAvailable() == false)
        Config.Evidence.Enable = true

        -- Mock provider selection
        EvidenceBridge._test.setProvider('vp_crimescene', function() return true end)
        check('EVID-PROV-03 Provider vp_crimescene is active and available', EvidenceBridge.GetProvider() == 'vp_crimescene' and EvidenceBridge.IsAvailable() == true)

        EvidenceBridge._test.setProvider('qbx_policejob', function() return true end)
        check('EVID-PROV-04 Provider qbx_policejob is active and available', EvidenceBridge.GetProvider() == 'qbx_policejob' and EvidenceBridge.IsAvailable() == true)

        EvidenceBridge._test.setProvider('ox_evidence', function() return true end)
        check('EVID-PROV-05 Provider ox_evidence is active and available', EvidenceBridge.GetProvider() == 'ox_evidence' and EvidenceBridge.IsAvailable() == true)

        EvidenceBridge._test.setProvider('evidences', function() return true end)
        check('EVID-PROV-06 Provider evidences is active and available', EvidenceBridge.GetProvider() == 'evidences' and EvidenceBridge.IsAvailable() == true)

        EvidenceBridge._test.setProvider('none', function() return false end)
        check('EVID-PROV-07 Provider none is not available', EvidenceBridge.GetProvider() == 'none' and EvidenceBridge.IsAvailable() == false)
    end

    -- ─── 2. Direct EvidenceBridge.Plant Validation ───────────────────────────
    do
        local plantedEvents = {}
        EvidenceBridge._test.setProvider('vp_crimescene', function(evClass, src, coords, actKey, meta)
            table.insert(plantedEvents, { evClass = evClass, src = src, coords = coords, actKey = actKey, meta = meta })
            return true
        end)

        -- Invalid source
        local resInvalidSrc = EvidenceBridge.Plant('fingerprint', -1, vector3(0, 0, 0), 'chop_part')
        check('EVID-PLANT-01 Invalid source rejects planting (ok=false)', resInvalidSrc == false and #plantedEvents == 0)

        -- Invalid coords
        local resInvalidCoords = EvidenceBridge.Plant('fingerprint', 1, nil, 'chop_part')
        check('EVID-PLANT-02 Invalid coords rejects planting (ok=false)', resInvalidCoords == false and #plantedEvents == 0)

        -- Valid plant
        local resValid = EvidenceBridge.Plant('fingerprint', 1, vector3(10.0, 20.0, 30.0), 'chop_part', { custom = 'test' })
        check('EVID-PLANT-03 Valid plant executes successfully', resValid == true and #plantedEvents == 1)
        check('EVID-PLANT-03 Planted event contains correct parameters', plantedEvents[1].evClass == 'fingerprint' and plantedEvents[1].src == 1 and plantedEvents[1].meta.custom == 'test')
    end

    -- ─── 3. VPChopLeaveEvidence Full Crime Workflow & Gloves Counterplay ─────
    do
        local plants = {}
        EvidenceBridge._test.setProvider('vp_crimescene', function(evClass, src, coords, actKey, meta)
            table.insert(plants, { evClass = evClass, src = src, coords = coords, actKey = actKey, meta = meta })
            return true
        end)

        -- Case A: No gloves -> drops both fingerprint and blood
        plants = {}
        mockInventory[1] = { gloves = 0 }
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'chop_part', 'CLEAN_PLATE')
        check('EVID-GLOVES-01 No gloves leaves exactly 2 traces (fingerprint + blood)', #plants == 2)
        check('EVID-GLOVES-01 First trace is fingerprint', plants[1] and plants[1].evClass == 'fingerprint')
        check('EVID-GLOVES-01 Second trace is blood', plants[2] and plants[2].evClass == 'blood')

        -- Case B: Wearing gloves (default GlovesBlocksDna=false) -> blocks fingerprint, leaves blood
        plants = {}
        mockInventory[1] = { gloves = 1 }
        Config.Evidence.GlovesBlocksDna = false
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'chop_part', 'CLEAN_PLATE')
        check('EVID-GLOVES-02 Wearing gloves blocks fingerprint but leaves blood (1 trace)', #plants == 1)
        check('EVID-GLOVES-02 Left trace is blood (DNA)', plants[1] and plants[1].evClass == 'blood')

        -- Case C: Wearing gloves with GlovesBlocksDna=true -> blocks both
        plants = {}
        mockInventory[1] = { gloves = 1 }
        Config.Evidence.GlovesBlocksDna = true
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'chop_part', 'CLEAN_PLATE')
        check('EVID-GLOVES-03 Gloves with GlovesBlocksDna=true leaves ZERO traces', #plants == 0)
        Config.Evidence.GlovesBlocksDna = false

        -- Case D: Unknown actionKey -> zero trace
        plants = {}
        mockInventory[1] = { gloves = 0 }
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'unknown_action', 'CLEAN_PLATE')
        check('EVID-ACTION-01 Unknown actionKey leaves zero traces', #plants == 0)

        -- Case E: Provider none -> zero trace
        plants = {}
        EvidenceBridge._test.setProvider('none', function() return false end)
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'chop_part', 'CLEAN_PLATE')
        check('EVID-ACTION-02 Provider none leaves zero traces', #plants == 0)
    end

    -- ─── 4. Heat Scaling & Fail-Closed Protection ───────────────────────────
    do
        local lastMetadata = nil
        EvidenceBridge._test.setProvider('qbx_policejob', function(evClass, src, coords, actKey, meta)
            lastMetadata = meta
            return true
        end)

        mockInventory[1] = { gloves = 0 }
        VPChopLeaveEvidence(1, vector3(5.0, 5.0, 5.0), 'vin_scratch', 'HOT_PLATE')
        check('EVID-HEAT-01 Provenance plate is forwarded to evidence metadata', lastMetadata ~= nil and lastMetadata.plate == 'HOT_PLATE')

        -- Third-party export error inside handler does not throw
        EvidenceBridge._test.setProvider('ox_evidence', function()
            error('simulated_third_party_failure')
        end)
        local okPcall = pcall(function()
            VPChopLeaveEvidence(1, vector3(5.0, 5.0, 5.0), 'plate_steal', 'WARM_PLATE')
        end)
        check('EVID-SAFETY-01 Third party export crash is safely caught by fail-closed pcall', okPcall == true)
    end

    -- Teardown
    EvidenceBridge._test.reset()
    Config.Evidence = origCfg

    print(('[evidence/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then
        error('evidence_bridge_spec falhou com ' .. fail .. ' erros')
    end
end

if CreateThread then
    CreateThread(run)
else
    run()
end
