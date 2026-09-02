-- server/tracker_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.2.1] TrackerManager Specification & LoJack Security Test Suite
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
        return type(src) == 'number' and src > 0 and src ~= 65535
    end

    local mockEntities = {}
    local mockEntityCoords = {}
    local mockPlayerCoords = {}
    local mockPlayerJobs = {}
    local mockStatebags = {}
    local sentClientEvents = {}

    _G.NetworkGetEntityFromNetworkId = function(netId)
        return mockEntities[netId] or 0
    end
    _G.DoesEntityExist = function(ent)
        return ent ~= nil and ent ~= 0 and ent.exists == true
    end
    _G.GetEntityModel = function(ent)
        return ent and ent.model or 0
    end
    _G.GetPlayerPed = function(src)
        return src
    end
    _G.GetEntityCoords = function(ent)
        if type(ent) == 'number' and mockPlayerCoords[ent] then
            return mockPlayerCoords[ent]
        end
        return (ent and ent.coords) or mockEntityCoords[ent] or vector3(0, 0, 0)
    end
    _G.Entity = function(ent)
        local id = (type(ent) == 'table' and ent.id) or ent
        mockStatebags[id] = mockStatebags[id] or {}
        return { state = mockStatebags[id] }
    end
    _G.GetPlayers = function()
        local list = {}
        for src, _ in pairs(mockPlayerJobs) do
            table.insert(list, tostring(src))
        end
        return list
    end
    _G.BridgeIsPolice = function(src, jobs)
        local j = mockPlayerJobs[src]
        if not j then return false end
        for _, pj in ipairs(jobs) do
            if pj == j then return true end
        end
        return false
    end
    _G.TriggerClientEvent = function(eventName, target, ...)
        table.insert(sentClientEvents, { event = eventName, target = target, args = { ... } })
    end

    local evidenceCalls = {}
    _G.VPChopLeaveEvidence = function(src, coords, actionKey, plate)
        table.insert(evidenceCalls, { src = src, coords = coords, actionKey = actionKey, plate = plate })
    end

    local function createMockVeh(netId, model)
        local veh = { id = netId, exists = true, model = model or 1111, coords = vector3(100.0, 200.0, 10.0) }
        mockEntities[netId] = veh
        mockEntityCoords[veh] = veh.coords
        mockStatebags[netId] = {}
        return veh
    end

    -- ─── 1. Identity & Authority Validation ──────────────────────────────────
    do
        TrackerManager._test.reset()
        local v1 = createMockVeh(101, 7777)

        -- TRK-ID-01: Config.Tracker.Enable=false returns no tracker
        Config.Tracker.Enable = false
        local resDisabled = TrackerManager.ObserveVehicle(101, 'test')
        check('TRK-ID-01 Config.Tracker.Enable=false returns no tracker', resDisabled.hasTracker == false and resDisabled.state == 'NONE')
        Config.Tracker.Enable = true

        -- TRK-ID-02: ObserveVehicle assigns server-authoritative trackerId and statebag
        local resObs = TrackerManager.ObserveVehicle(101, 'test', 1.0)
        check('TRK-ID-02 Forced chance 1.0 assigns ACTIVE tracker', resObs.hasTracker == true and resObs.state == 'ACTIVE')
        check('TRK-ID-02 TrackerId is server-minted opaque token', type(resObs.trackerId) == 'string' and resObs.trackerId:sub(1, 4) == 'trk:')
        check('TRK-ID-02 Statebag marker is confirmed', resObs.markerSet == true and mockStatebags[101].vpChopTrackerId == resObs.trackerId)

        -- TRK-ID-03: Repeated ObserveVehicle on same entity does NOT reroll
        local resObsAgain = TrackerManager.ObserveVehicle(101, 'test', 0.0)
        check('TRK-ID-03 ObserveVehicle repeated call returns identical tracker without reroll', resObsAgain.trackerId == resObs.trackerId and resObsAgain.state == 'ACTIVE')

        -- TRK-ID-04: Lookup by NetId and TrackerId
        check('TRK-ID-04 GetByNetId returns active tracker', TrackerManager.GetByNetId(101) ~= nil and TrackerManager.GetByNetId(101).state == 'ACTIVE')
        check('TRK-ID-04 GetByTrackerId returns record', TrackerManager.GetByTrackerId(resObs.trackerId) ~= nil)
        check('TRK-ID-04 IsActive returns true', TrackerManager.IsActive(101) == true)

        -- TRK-ID-05: NetId recycled for different model invalidates old tracker
        local vRecycled = createMockVeh(101, 9999) -- different model on same netId
        mockStatebags[101] = {} -- statebag wiped
        local resRecycled = TrackerManager.ObserveVehicle(101, 'recycled', 0.0)
        check('TRK-ID-05 Recycled netId creates new tracker lifecycle', resRecycled.trackerId ~= resObs.trackerId and resRecycled.state == 'NONE')
    end

    -- ─── 2. StartRemoval Validation & Security Tokens ─────────────────────────
    do
        TrackerManager._test.reset()
        local v2 = createMockVeh(201, 5555)
        TrackerManager.ObserveVehicle(201, 'test', 1.0)

        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)

        -- TRK-START-01: Invalid source rejected
        local resInvSrc = TrackerManager.StartRemoval(-1, 201)
        check('TRK-START-01 Invalid source rejected with invalid_source', resInvSrc.ok == false and resInvSrc.err == 'invalid_source')

        -- TRK-START-02: Invalid netId / non-existent entity rejected
        local resInvNet = TrackerManager.StartRemoval(1, 999)
        check('TRK-START-02 Non-existent entity rejected with invalid_entity', resInvNet.ok == false and resInvNet.err == 'invalid_entity')

        -- TRK-START-03: Vehicle without tracker rejected with not_found
        local vClean = createMockVeh(202, 5555)
        TrackerManager.ObserveVehicle(202, 'test', 0.0)
        local resClean = TrackerManager.StartRemoval(1, 202)
        check('TRK-START-03 Clean vehicle rejected with not_found', resClean.ok == false and resClean.err == 'not_found')

        -- TRK-START-04: Missing required tool rejected
        mockInventory[1] = { pliers = 0, screwdriver = 0 }
        local resNoTool = TrackerManager.StartRemoval(1, 201)
        check('TRK-START-04 Missing required tool rejected with no_tool', resNoTool.ok == false and resNoTool.err == 'no_tool')

        -- TRK-START-05: Fallback tool (screwdriver) accepted
        mockInventory[1] = { pliers = 0, screwdriver = 1 }
        local resFallback = TrackerManager.StartRemoval(1, 201)
        check('TRK-START-05 ToolFallback screwdriver accepted', resFallback.ok == true and type(resFallback.removalToken) == 'string')

        -- TRK-START-06: Player too far rejected with distance
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(200.0, 300.0, 10.0)
        local resFar = TrackerManager.StartRemoval(1, 201)
        check('TRK-START-06 Player too far rejected with distance', resFar.ok == false and resFar.err == 'distance')

        -- TRK-START-07: Valid StartRemoval returns removalToken and minDurationMs
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        local resValid = TrackerManager.StartRemoval(1, 201)
        check('TRK-START-07 Valid startRemoval returns ok=true, removalToken and minDurationMs', resValid.ok == true and resValid.minDurationMs == 7000 and resValid.removalToken ~= nil)
    end

    -- ─── 3. CompleteRemoval & Cancellation Hardening ──────────────────────────
    do
        TrackerManager._test.reset()
        local v3 = createMockVeh(301, 3333)
        local trk3 = TrackerManager.ObserveVehicle(301, 'test', 1.0)
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        TrackerManager._test.setTime(1000)
        evidenceCalls = {}

        -- Start removal
        local startRes = TrackerManager.StartRemoval(1, 301)
        local token = startRes.removalToken

        -- TRK-CANCEL-01: CancelRemoval cleans active session
        TrackerManager.CancelRemoval(1, token)
        check('TRK-CANCEL-01 CancelRemoval cleans active session', TrackerManager._test.getActiveRemovals()[1] == nil)
        check('TRK-CANCEL-01 Tracker remains ACTIVE after cancel', trk3.state == 'ACTIVE')

        -- Re-start
        TrackerManager._test.setTime(2000)
        startRes = TrackerManager.StartRemoval(1, 301)
        token = startRes.removalToken

        -- TRK-COMP-01: Invalid token rejected
        local resBadToken = TrackerManager.CompleteRemoval(1, 301, 'fake_token')
        check('TRK-COMP-01 Invalid token rejected with invalid_token', resBadToken.ok == false and resBadToken.err == 'invalid_token')

        -- TRK-COMP-02: Complete too fast (< 7000ms strict, zero negative tolerance)
        TrackerManager._test.setTime(8000) -- elapsed 6000ms < 7000ms
        local resTooFast = TrackerManager.CompleteRemoval(1, 301, token)
        check('TRK-COMP-02 Elapsed 6000ms (< 7000ms) rejected with too_fast', resTooFast.ok == false and resTooFast.err == 'too_fast')

        -- TRK-COMP-03: Distance check on completion
        mockPlayerCoords[1] = vector3(500.0, 500.0, 10.0)
        TrackerManager._test.setTime(10000) -- elapsed 8000ms >= 7000ms
        local resDistFar = TrackerManager.CompleteRemoval(1, 301, token)
        check('TRK-COMP-03 Player moved far before complete rejected with distance', resDistFar.ok == false and resDistFar.err == 'distance')

        -- Re-start for tool check
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        TrackerManager._test.setTime(15000)
        startRes = TrackerManager.StartRemoval(1, 301)
        token = startRes.removalToken

        -- TRK-COMP-04: Tool lost before completion
        mockInventory[1] = { pliers = 0, screwdriver = 0 }
        TrackerManager._test.setTime(23000)
        local resLostTool = TrackerManager.CompleteRemoval(1, 301, token)
        check('TRK-COMP-04 Tool lost before completion rejected with no_tool', resLostTool.ok == false and resLostTool.err == 'no_tool')

        -- Re-start for entity stale check
        mockInventory[1] = { pliers = 1 }
        TrackerManager._test.setTime(30000)
        startRes = TrackerManager.StartRemoval(1, 301)
        token = startRes.removalToken

        -- TRK-COMP-05: Entity destroyed before completion
        v3.exists = false
        TrackerManager._test.setTime(38000)
        local resStaleVeh = TrackerManager.CompleteRemoval(1, 301, token)
        check('TRK-COMP-05 Destroyed entity rejected with vehicle_stale', resStaleVeh.ok == false and resStaleVeh.err == 'vehicle_stale')

        -- Re-start for legitimate success
        v3.exists = true
        TrackerManager._test.setTime(50000)
        startRes = TrackerManager.StartRemoval(1, 301)
        token = startRes.removalToken

        -- TRK-COMP-06: Legitimate completion succeeds
        TrackerManager._test.setTime(58000) -- elapsed 8000ms >= 7000ms
        local resSuccess = TrackerManager.CompleteRemoval(1, 301, token)
        check('TRK-COMP-06 Legitimate completion succeeds with ok=true', resSuccess.ok == true)
        check('TRK-COMP-06 Tracker transitioned to REMOVED', trk3.state == 'REMOVED' and trk3.hasTracker == false)
        check('TRK-COMP-06 IsActive returns false', TrackerManager.IsActive(301) == false)

        -- TRK-COMP-07: Forensic evidence was dropped with actionKey tracker_removal
        check('TRK-COMP-07 Evidence was planted on removal', #evidenceCalls == 1 and evidenceCalls[1].actionKey == 'tracker_removal')

        -- TRK-COMP-08: Attempting to remove already removed tracker rejected
        local resAlready = TrackerManager.StartRemoval(1, 301)
        check('TRK-COMP-08 Start removal on already removed tracker rejected with already_removed', resAlready.ok == false and resAlready.err == 'already_removed')
    end

    -- ─── 4. Server-Filtered Police Beacon Broadcast ───────────────────────────
    do
        TrackerManager._test.reset()
        sentClientEvents = {}

        local v4 = createMockVeh(401, 4444)
        local trk4 = TrackerManager.ObserveVehicle(401, 'test', 1.0)
        TrackerManager._test.setTime(100000)

        mockPlayerJobs[1] = 'police'
        mockPlayerJobs[2] = 'sheriff'
        mockPlayerJobs[3] = 'unemployed'
        mockPlayerJobs[4] = 'mechanic'

        -- TRK-POLICE-01: BroadcastPings only targets online police officers
        TrackerManager._test.setTime(120000) -- 20s elapsed > 15s interval
        local count = TrackerManager.BroadcastPings()
        check('TRK-POLICE-01 BroadcastPings emitted beacon', count == 1)
        check('TRK-POLICE-01 Two police recipients received ping', #sentClientEvents == 2)

        local recipients = {}
        for _, ev in ipairs(sentClientEvents) do
            recipients[ev.target] = true
            check('TRK-POLICE-01 Event is trackerPing', ev.event == 'vp_chopshop:client:trackerPing')
        end
        check('TRK-POLICE-01 Police officer (src 1) received ping', recipients[1] == true)
        check('TRK-POLICE-01 Sheriff (src 2) received ping', recipients[2] == true)
        check('TRK-POLICE-02 Civilian (src 3) received ZERO pings', recipients[3] == nil)
        check('TRK-POLICE-02 Mechanic (src 4) received ZERO pings', recipients[4] == nil)

        -- TRK-POLICE-03: Zero broadcast to -1
        local hasWildcard = false
        for _, ev in ipairs(sentClientEvents) do
            if ev.target == -1 then hasWildcard = true end
        end
        check('TRK-POLICE-03 Zero trackerPing sent to -1 wildcard', hasWildcard == false)
    end

    -- ─── 5. Locale Parity & Canary Verification ───────────────────────────────
    do
        local requiredKeys = {
            'target_search_tracker',
            'tracker_searching',
            'tracker_found',
            'tracker_not_found',
            'tracker_removed',
            'tracker_removal_failed',
            'tracker_no_tool',
            'tracker_already_removed',
            'tracker_police_title',
            'tracker_police_alert',
            'tracker_police_blip',
        }

        local languages = { 'en', 'pt', 'es', 'fr', 'tr' }
        for _, lang in ipairs(languages) do
            Config.Locale = lang
            for _, key in ipairs(requiredKeys) do
                local val = L(key)
                check(('TRK-LOCALE-01 Key %s present in %s'):format(key, lang), val ~= nil and val ~= key and val ~= '')
            end
        end
        Config.Locale = 'en'
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
