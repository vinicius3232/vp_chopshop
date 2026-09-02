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
        AutoOrder = { 'evidences', 'vp_crimescene' },
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

    local origGetResourceState = _G.GetResourceState
    local mockResourceStates = {}
    _G.GetResourceState = function(resName)
        return mockResourceStates[resName] or 'missing'
    end

    local origExports = _G.exports or {}
    _G.exports = origExports

    -- ─── 1. Provider Resolution & AutoOrder Contract ──────────────────────────
    do
        EvidenceBridge._test.reset()
        mockResourceStates = {}

        -- EVID-CONFIG-01: Provider='none'
        Config.Evidence.Provider = 'none'
        check('EVID-CONFIG-01 Provider=none returns none', EvidenceBridge.GetProvider() == 'none')
        check('EVID-CONFIG-01 Provider=none is not available', EvidenceBridge.IsAvailable() == false)

        -- EVID-CONFIG-02: Provider='evidences' + started
        Config.Evidence.Provider = 'evidences'
        mockResourceStates['evidences'] = 'started'
        check('EVID-CONFIG-02 Provider=evidences when started returns evidences', EvidenceBridge.GetProvider() == 'evidences')
        check('EVID-CONFIG-02 Provider=evidences is available', EvidenceBridge.IsAvailable() == true)

        -- EVID-CONFIG-03: Provider='evidences' + stopped
        mockResourceStates['evidences'] = 'stopped'
        check('EVID-CONFIG-03 Provider=evidences when stopped returns none', EvidenceBridge.GetProvider() == 'none')
        check('EVID-CONFIG-03 Provider=evidences when stopped is not available', EvidenceBridge.IsAvailable() == false)

        -- EVID-AUTO-01: Both evidences and vp_crimescene started -> evidences wins (AutoOrder)
        Config.Evidence.Provider = 'auto'
        Config.Evidence.AutoOrder = { 'evidences', 'vp_crimescene' }
        mockResourceStates['evidences'] = 'started'
        mockResourceStates['vp_crimescene'] = 'started'
        check('EVID-AUTO-01 AutoOrder prefers evidences over vp_crimescene', EvidenceBridge.GetProvider() == 'evidences')

        -- EVID-AUTO-02: evidences stopped, vp_crimescene started -> vp_crimescene
        mockResourceStates['evidences'] = 'stopped'
        mockResourceStates['vp_crimescene'] = 'started'
        check('EVID-AUTO-02 AutoOrder falls back to vp_crimescene when evidences stopped', EvidenceBridge.GetProvider() == 'vp_crimescene')

        -- EVID-AUTO-03: Neither started -> none
        mockResourceStates['evidences'] = 'stopped'
        mockResourceStates['vp_crimescene'] = 'stopped'
        check('EVID-AUTO-03 AutoOrder returns none when no providers started', EvidenceBridge.GetProvider() == 'none')
        check('EVID-AUTO-03 AutoOrder is not available when none started', EvidenceBridge.IsAvailable() == false)

        -- EVID-UNKNOWN-01: Unknown provider configured -> none fail-soft
        Config.Evidence.Provider = 'non_existent_provider_xyz'
        check('EVID-UNKNOWN-01 Unknown configured provider returns none fail-soft', EvidenceBridge.GetProvider() == 'none')
    end

    -- ─── 2. Real Adapter Contract: noobsystems/evidences ──────────────────────
    do
        EvidenceBridge._test.reset()
        Config.Evidence.Provider = 'evidences'
        mockResourceStates['evidences'] = 'started'

        local capturedCalls = {}
        _G.exports.evidences = {
            syncEvidence = function(self, evClass, owner, fun, coords, meta)
                table.insert(capturedCalls, {
                    evidenceClass = evClass,
                    owner = owner,
                    functionName = fun,
                    coords = coords,
                    metadata = meta,
                })
                return true
            end
        }

        -- EVID-ADAPTER-EVIDENCES-01: Fingerprint call arguments
        capturedCalls = {}
        local targetCoords = vector3(100.5, 200.5, 30.0)
        local okPlantFp = EvidenceBridge.Plant('fingerprint', 42, targetCoords, 'chop_part', { custom = 'meta1' })
        check('EVID-ADAPTER-EVIDENCES-01 Plant fingerprint succeeded', okPlantFp == true)
        check('EVID-ADAPTER-EVIDENCES-01 syncEvidence called exactly once', #capturedCalls == 1)
        check('EVID-ADAPTER-EVIDENCES-01 arg1 is fingerprint', capturedCalls[1] and capturedCalls[1].evidenceClass == 'fingerprint')
        check('EVID-ADAPTER-EVIDENCES-01 arg2 is src serverId (42)', capturedCalls[1] and capturedCalls[1].owner == 42)
        check('EVID-ADAPTER-EVIDENCES-01 arg3 is atCoords', capturedCalls[1] and capturedCalls[1].functionName == 'atCoords')
        check('EVID-ADAPTER-EVIDENCES-01 arg4 is coords', capturedCalls[1] and capturedCalls[1].coords == targetCoords)
        check('EVID-ADAPTER-EVIDENCES-01 arg5 has action and custom metadata', capturedCalls[1] and capturedCalls[1].metadata.action == 'chop_part' and capturedCalls[1].metadata.custom == 'meta1')

        -- EVID-ADAPTER-EVIDENCES-02: DNA Blood call arguments
        capturedCalls = {}
        local okPlantBlood = EvidenceBridge.Plant('blood', 88, targetCoords, 'vin_scratch', { plate = 'HOT123' })
        check('EVID-ADAPTER-EVIDENCES-02 Plant blood succeeded', okPlantBlood == true)
        check('EVID-ADAPTER-EVIDENCES-02 arg1 is blood', capturedCalls[1] and capturedCalls[1].evidenceClass == 'blood')
        check('EVID-ADAPTER-EVIDENCES-02 arg2 is src serverId (88)', capturedCalls[1] and capturedCalls[1].owner == 88)
        check('EVID-ADAPTER-EVIDENCES-02 arg3 is atCoords', capturedCalls[1] and capturedCalls[1].functionName == 'atCoords')

        -- EVID-ADAPTER-EVIDENCES-03: Saliva call arguments
        capturedCalls = {}
        local okPlantSaliva = EvidenceBridge.Plant('saliva', 12, targetCoords, 'plate_steal', {})
        check('EVID-ADAPTER-EVIDENCES-03 Plant saliva succeeded', okPlantSaliva == true)
        check('EVID-ADAPTER-EVIDENCES-03 arg1 is saliva', capturedCalls[1] and capturedCalls[1].evidenceClass == 'saliva')
        check('EVID-ADAPTER-EVIDENCES-03 arg2 is src serverId (12)', capturedCalls[1] and capturedCalls[1].owner == 12)
        check('EVID-ADAPTER-EVIDENCES-03 arg3 is atCoords', capturedCalls[1] and capturedCalls[1].functionName == 'atCoords')

        -- EVID-ADAPTER-EVIDENCES-04: Export throws error -> fail-soft (returns false, no throw)
        _G.exports.evidences.syncEvidence = function()
            error('simulated_evidences_crash')
        end
        local okExportFail, resExportFail = pcall(function()
            return EvidenceBridge.Plant('fingerprint', 1, targetCoords, 'chop_part')
        end)
        check('EVID-ADAPTER-EVIDENCES-04 Export crash does not throw exception', okExportFail == true)
        check('EVID-ADAPTER-EVIDENCES-04 Export crash returns false', resExportFail == false)
    end

    -- ─── 3. Real Adapter Contract: vp_crimescene ─────────────────────────────
    do
        EvidenceBridge._test.reset()
        Config.Evidence.Provider = 'vp_crimescene'
        mockResourceStates['vp_crimescene'] = 'started'

        local capturedCrimeCalls = {}
        _G.exports.vp_crimescene = {
            AddGroundEvidence = function(self, evType, coords, playerSrc, meta)
                table.insert(capturedCrimeCalls, {
                    evidenceType = evType,
                    coords = coords,
                    playerSrc = playerSrc,
                    metadata = meta,
                })
                return true
            end
        }

        local crimeCoords = vector3(50.0, 60.0, 70.0)
        local okCrimePlant = EvidenceBridge.Plant('fingerprint', 7, crimeCoords, 'plate_forge', { tool = 'pliers' })
        check('EVID-ADAPTER-CRIME-01 vp_crimescene AddGroundEvidence succeeded', okCrimePlant == true)
        check('EVID-ADAPTER-CRIME-01 vp_crimescene received evidenceClass', capturedCrimeCalls[1] and capturedCrimeCalls[1].evidenceType == 'fingerprint')
        check('EVID-ADAPTER-CRIME-01 vp_crimescene received playerSrc (7)', capturedCrimeCalls[1] and capturedCrimeCalls[1].playerSrc == 7)
        check('EVID-ADAPTER-CRIME-01 vp_crimescene received coords', capturedCrimeCalls[1] and capturedCrimeCalls[1].coords == crimeCoords)
    end

    -- ─── 4. Custom Provider Server-Side Registry & Security ─────────────────
    do
        EvidenceBridge._test.reset()
        Config.Evidence.Provider = 'custom'

        -- EVID-CUSTOM-01: Valid custom provider registration
        local customPlanted = {}
        local okReg, errReg = EvidenceBridge.RegisterProvider('custom', 'my_custom_police', function(evClass, src, coords, actKey, meta)
            table.insert(customPlanted, { evClass = evClass, src = src, coords = coords, actKey = actKey, meta = meta })
            return true
        end)
        check('EVID-CUSTOM-01 Custom provider registration succeeded', okReg == true and errReg == nil)
        check('EVID-CUSTOM-01 Provider custom is active and available', EvidenceBridge.GetProvider() == 'custom' and EvidenceBridge.IsAvailable() == true)

        local okCustomPlant = EvidenceBridge.Plant('blood', 99, vector3(1, 1, 1), 'chop_part', { custom = 'data' })
        check('EVID-CUSTOM-01 Custom handler invoked successfully', okCustomPlant == true and #customPlanted == 1)
        check('EVID-CUSTOM-01 Custom handler received src (99)', customPlanted[1] and customPlanted[1].src == 99)

        -- EVID-CUSTOM-02: Hijack attempt by another resource is rejected
        local okHijack, errHijack = EvidenceBridge.RegisterProvider('custom', 'attacker_resource', function() return false end)
        check('EVID-CUSTOM-02 Hijack attempt by different resource is rejected', okHijack == false and (errHijack == 'already_registered' or errHijack == 'resource_mismatch'))

        -- EVID-CUSTOM-03: Custom handler throws exception -> fail-soft (returns false, no crash)
        EvidenceBridge._test.reset()
        EvidenceBridge.RegisterProvider('custom', 'failing_resource', function()
            error('custom_handler_crash')
        end)
        local okCustomCrash, resCustomCrash = pcall(function()
            return EvidenceBridge.Plant('blood', 1, vector3(1, 1, 1), 'chop_part')
        end)
        check('EVID-CUSTOM-03 Custom handler exception caught fail-soft', okCustomCrash == true and resCustomCrash == false)
    end

    -- ─── 5. Source Canary: No Fake / Guess QBX Integrations ──────────────────
    do
        -- EVID-NO-FAKE-QBX-01: Ensure bridge/evidence.lua contains no unverified qbx exports or triggers
        local f = io.open('bridge/evidence.lua', 'r')
        local bridgeContent = f and f:read('*a')
        if f then f:close() end

        local hasFakeQbxExport = bridgeContent and bridgeContent:find('qbx_policejob:CreateEvidence', 1, true) ~= nil
        local hasFakeTrigger = bridgeContent and bridgeContent:find('evidence:server:CreateFingerprint', 1, true) ~= nil
        check('EVID-NO-FAKE-QBX-01 Bridge contains ZERO calls to unverified qbx_policejob export', not hasFakeQbxExport)
        check('EVID-NO-FAKE-QBX-01 Bridge contains ZERO calls to unverified CreateFingerprint event', not hasFakeTrigger)
    end

    -- ─── 6. Legacy VPChopLeaveEvidence Full Crime Workflow & Gloves Matrix ──
    do
        EvidenceBridge._test.reset()
        Config.Evidence.Provider = 'evidences'
        mockResourceStates['evidences'] = 'started'

        local legacyCalls = {}
        _G.exports.evidences = {
            syncEvidence = function(self, evClass, owner, fun, coords, meta)
                table.insert(legacyCalls, {
                    evidenceClass = evClass,
                    owner = owner,
                    coords = coords,
                    metadata = meta,
                })
                return true
            end
        }

        -- Case A: No gloves -> drops both fingerprint and blood
        legacyCalls = {}
        mockInventory[1] = { gloves = 0 }
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'chop_part', 'CLEAN_PLATE')
        check('EVID-GLOVES-01 No gloves leaves exactly 2 traces (fingerprint + blood)', #legacyCalls == 2)
        check('EVID-GLOVES-01 First trace is fingerprint', legacyCalls[1] and legacyCalls[1].evidenceClass == 'fingerprint')
        check('EVID-GLOVES-01 Second trace is blood', legacyCalls[2] and legacyCalls[2].evidenceClass == 'blood')

        -- Case B: Wearing gloves (default GlovesBlocksDna=false) -> blocks fingerprint, leaves blood
        legacyCalls = {}
        mockInventory[1] = { gloves = 1 }
        Config.Evidence.GlovesBlocksDna = false
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'chop_part', 'CLEAN_PLATE')
        check('EVID-GLOVES-02 Wearing gloves blocks fingerprint but leaves blood (1 trace)', #legacyCalls == 1)
        check('EVID-GLOVES-02 Left trace is blood (DNA)', legacyCalls[1] and legacyCalls[1].evidenceClass == 'blood')

        -- Case C: Wearing gloves with GlovesBlocksDna=true -> blocks both
        legacyCalls = {}
        mockInventory[1] = { gloves = 1 }
        Config.Evidence.GlovesBlocksDna = true
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'chop_part', 'CLEAN_PLATE')
        check('EVID-GLOVES-03 Gloves with GlovesBlocksDna=true leaves ZERO traces', #legacyCalls == 0)
        Config.Evidence.GlovesBlocksDna = false

        -- Case D: Unknown actionKey -> zero trace
        legacyCalls = {}
        mockInventory[1] = { gloves = 0 }
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'unknown_action', 'CLEAN_PLATE')
        check('EVID-ACTION-01 Unknown actionKey leaves zero traces', #legacyCalls == 0)

        -- Case E: Provider none -> zero trace
        legacyCalls = {}
        Config.Evidence.Provider = 'none'
        VPChopLeaveEvidence(1, vector3(1.0, 2.0, 3.0), 'chop_part', 'CLEAN_PLATE')
        check('EVID-ACTION-02 Provider none leaves zero traces', #legacyCalls == 0)
        Config.Evidence.Provider = 'evidences'

        -- Case F: Heat scaling forwards plate to metadata
        legacyCalls = {}
        mockInventory[1] = { gloves = 0 }
        VPChopLeaveEvidence(1, vector3(5.0, 5.0, 5.0), 'vin_scratch', 'HOT_PLATE')
        check('EVID-HEAT-01 Provenance plate is forwarded to evidence metadata', legacyCalls[1] and legacyCalls[1].metadata.plate == 'HOT_PLATE')
    end

    -- Teardown
    EvidenceBridge._test.reset()
    Config.Evidence = origCfg
    _G.exports = origExports
    _G.GetResourceState = origGetResourceState

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
