-- server/tracker_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.2] TrackerManager Specification & LoJack Security Test Suite
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
            print(('[tracker/spec] PASS  %s'):format(desc))
        else
            fail = fail + 1
            print(('[tracker/spec] FAIL  %s'):format(desc))
        end
    end

    local origCfg = Config.Tracker
    Config.Tracker = {
        Enable = true,
        DefaultChance = 0.50,
        ClassChances = {
            [0] = 0.10,
            [7] = 0.90,
        },
        RequiredTool = 'pliers',
        ToolFallback = 'screwdriver',
        MinDurationMs = 7000,
        MaxDistance = 3.5,
        PingIntervalSeconds = 15,
        BlipDurationSeconds = 10,
        PoliceJobs = { 'police', 'sheriff' },
        RemovalEvidence = true,
    }

    local mockInventory = {}
    _G.InvCount = function(src, item)
        return (mockInventory[src] and mockInventory[src][item]) or 0
    end
    _G.IsValidSource = function(src)
        return type(src) == 'number' and src > 0
    end

    local evidenceCalls = {}
    _G.VPChopLeaveEvidence = function(src, coords, actionKey, plate)
        table.insert(evidenceCalls, { src = src, coords = coords, actionKey = actionKey, plate = plate })
    end

    -- ─── 1. Resolve & Vehicle State Resolution ────────────────────────────────
    do
        TrackerManager._test.reset()

        -- TRK-RES-01: Disabled config returns no tracker
        Config.Tracker.Enable = false
        local resDisabled = TrackerManager.Resolve(101, 'ABC111', 7)
        check('TRK-RES-01 Config.Tracker.Enable=false returns no tracker', resDisabled.hasTracker == false and resDisabled.state == 'NONE')
        Config.Tracker.Enable = true

        -- TRK-RES-02: Forced chance 1.0 creates ACTIVE tracker
        local resActive = TrackerManager.Resolve(102, 'SUPER77', 7, 1.0)
        check('TRK-RES-02 Forced chance 1.0 assigns ACTIVE tracker', resActive.hasTracker == true and resActive.state == 'ACTIVE')
        check('TRK-RES-02 VSID is deterministic', resActive.vsid == 'trk:102:SUPER77')

        -- TRK-RES-03: Forced chance 0.0 creates NONE tracker
        local resNone = TrackerManager.Resolve(103, 'COMP001', 0, 0.0)
        check('TRK-RES-03 Forced chance 0.0 assigns NONE tracker', resNone.hasTracker == false and resNone.state == 'NONE')

        -- TRK-RES-04: Idempotent lookup by VSID and NetId
        local resLookupVsid = TrackerManager.GetByVsid('trk:102:SUPER77')
        check('TRK-RES-04 Lookup by VSID returns active tracker', resLookupVsid ~= nil and resLookupVsid.state == 'ACTIVE')

        local resLookupNet = TrackerManager.GetByNetId(102, 'SUPER77')
        check('TRK-RES-04 Lookup by NetId returns identical tracker', resLookupNet ~= nil and resLookupNet.vsid == resActive.vsid)

        -- TRK-RES-05: IsActive check
        check('TRK-RES-05 IsActive returns true for vehicle 102', TrackerManager.IsActive(102, 'SUPER77') == true)
        check('TRK-RES-05 IsActive returns false for vehicle 103', TrackerManager.IsActive(103, 'COMP001') == false)
    end

    -- ─── 2. StartRemoval Validation & Security Gates ──────────────────────────
    do
        TrackerManager._test.reset()
        mockInventory[1] = { pliers = 1 }

        -- Setup vehicle with active tracker
        TrackerManager.Resolve(201, 'ACTIVE1', 7, 1.0)

        -- TRK-START-01: Invalid source rejected
        local resInvSrc = TrackerManager.StartRemoval(-1, 201, 'ACTIVE1')
        check('TRK-START-01 Invalid source rejected with invalid_source', resInvSrc.ok == false and resInvSrc.err == 'invalid_source')

        -- TRK-START-02: Invalid netId rejected
        local resInvNet = TrackerManager.StartRemoval(1, 0, 'ACTIVE1')
        check('TRK-START-02 Invalid netId rejected with invalid_net', resInvNet.ok == false and resInvNet.err == 'invalid_net')

        -- TRK-START-03: Vehicle without tracker returns not_found
        TrackerManager.Resolve(202, 'CLEAN1', 0, 0.0)
        local resClean = TrackerManager.StartRemoval(1, 202, 'CLEAN1')
        check('TRK-START-03 Clean vehicle rejected with not_found', resClean.ok == false and resClean.err == 'not_found')

        -- TRK-START-04: Missing required tool rejected
        mockInventory[1] = { pliers = 0, screwdriver = 0 }
        local resNoTool = TrackerManager.StartRemoval(1, 201, 'ACTIVE1')
        check('TRK-START-04 Missing required tool rejected with no_tool', resNoTool.ok == false and resNoTool.err == 'no_tool')

        -- TRK-START-05: Fallback tool (screwdriver) accepted
        mockInventory[1] = { pliers = 0, screwdriver = 1 }
        local resFallback = TrackerManager.StartRemoval(1, 201, 'ACTIVE1')
        check('TRK-START-05 ToolFallback screwdriver accepted', resFallback.ok == true and resFallback.minDurationMs == 7000)

        -- TRK-START-06: Primary tool (pliers) accepted
        mockInventory[1] = { pliers = 1, screwdriver = 0 }
        local resValid = TrackerManager.StartRemoval(1, 201, 'ACTIVE1')
        check('TRK-START-06 Valid startRemoval returns ok=true and minDurationMs', resValid.ok == true and resValid.minDurationMs == 7000)
    end

    -- ─── 3. CompleteRemoval Temporal & State Authority ────────────────────────
    do
        TrackerManager._test.reset()
        mockInventory[1] = { pliers = 1 }
        evidenceCalls = {}

        TrackerManager.Resolve(301, 'TRACKED', 7, 1.0)
        TrackerManager._test.setTime(1000)

        -- Start removal
        local startRes = TrackerManager.StartRemoval(1, 301, 'TRACKED')
        check('TRK-COMP-01 StartRemoval initialized successfully', startRes.ok == true)

        -- TRK-COMP-02: Complete without session rejected
        local resNoSess = TrackerManager.CompleteRemoval(2, 301, 'TRACKED')
        check('TRK-COMP-02 Player without active session rejected with no_session', resNoSess.ok == false and resNoSess.err == 'no_session')

        -- TRK-COMP-03: Complete too fast (anti-speedhack)
        TrackerManager._test.setTime(2000) -- elapsed 1000ms < 6500ms
        local resTooFast = TrackerManager.CompleteRemoval(1, 301, 'TRACKED')
        check('TRK-COMP-03 Premature completion rejected with too_fast', resTooFast.ok == false and resTooFast.err == 'too_fast')

        -- Re-start removal after failure
        TrackerManager._test.setTime(5000)
        TrackerManager.StartRemoval(1, 301, 'TRACKED')

        -- TRK-COMP-04: Complete with wrong vehicle rejected
        TrackerManager._test.setTime(13000) -- elapsed 8000ms >= 6500ms
        local resWrongVeh = TrackerManager.CompleteRemoval(1, 999, 'OTHER')
        check('TRK-COMP-04 Completion with mismatched netId rejected with vehicle_mismatch', resWrongVeh.ok == false and resWrongVeh.err == 'vehicle_mismatch')

        -- Re-start and complete legitimately
        TrackerManager._test.setTime(20000)
        TrackerManager.StartRemoval(1, 301, 'TRACKED')
        TrackerManager._test.setTime(28000) -- elapsed 8000ms
        local resComplete = TrackerManager.CompleteRemoval(1, 301, 'TRACKED')
        check('TRK-COMP-05 Legitimate completion succeeds with ok=true', resComplete.ok == true)

        -- TRK-COMP-06: Tracker state transitioned to REMOVED
        local trkAfter = TrackerManager.GetByNetId(301, 'TRACKED')
        check('TRK-COMP-06 Tracker transitioned to REMOVED', trkAfter ~= nil and trkAfter.state == 'REMOVED' and trkAfter.hasTracker == false)
        check('TRK-COMP-06 IsActive now returns false', TrackerManager.IsActive(301, 'TRACKED') == false)

        -- TRK-COMP-07: Forensic evidence was dropped
        check('TRK-COMP-07 Evidence was planted on tracker removal', #evidenceCalls == 1 and evidenceCalls[1].plate == 'TRACKED')

        -- TRK-COMP-08: Attempting to remove already removed tracker is rejected
        local resRepeat = TrackerManager.StartRemoval(1, 301, 'TRACKED')
        check('TRK-COMP-08 Second removal attempt rejected with already_removed', resRepeat.ok == false and resRepeat.err == 'already_removed')
    end

    -- ─── 4. BroadcastPings & Policial Dispatch Loop ───────────────────────────
    do
        TrackerManager._test.reset()
        TrackerManager._test.setTime(100000)

        -- Active tracker
        TrackerManager.Resolve(401, 'PINGME', 7, 1.0)
        -- Removed tracker
        local trkRemoved = TrackerManager.Resolve(402, 'SILENT', 7, 1.0)
        trkRemoved.state = 'REMOVED'

        -- Advance clock beyond 15s interval
        TrackerManager._test.setTime(120000)
        local pingsSent = TrackerManager.BroadcastPings()
        check('TRK-PING-01 BroadcastPings handles active trackers cleanly', type(pingsSent) == 'number')

        -- Feature disabled sends 0 pings
        Config.Tracker.Enable = false
        check('TRK-PING-02 Disabled Tracker config sends 0 pings', TrackerManager.BroadcastPings() == 0)
        Config.Tracker.Enable = true
    end

    -- Teardown
    TrackerManager._test.reset()
    Config.Tracker = origCfg

    print(('[tracker/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then
        error('tracker_spec falhou com ' .. fail .. ' erros')
    end
end

if CreateThread then
    CreateThread(run)
else
    run()
end
