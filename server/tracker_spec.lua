-- server/tracker_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.2.3] TrackerManager Specification & LoJack Security Test Suite
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

    local function mapCount(t)
        local n = 0
        for _ in pairs(t or {}) do
            n = n + 1
        end
        return n
    end

    local origCfg = Config.Tracker
    Config.Tracker = {
        Enable = true,
        DefaultChance = 0.40,
        ClassChances = {
            [0] = 0.10,
            [7] = 0.85,
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
    _G.ServerPlayerIsReady = function(src)
        return IsValidSource(src)
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
    _G.GetEntityType = function(ent)
        return ent and ent.entityType or 0
    end
    _G.GetEntityModel = function(ent)
        return ent and ent.model or 0
    end
    _G.GetVehicleClass = function(ent)
        return ent and ent.vehClass
    end
    _G.GetVehicleClassFromName = function(model)
        return nil
    end
    _G.GetVehicleNumberPlateText = function(ent)
        return ent and ent.plate or ''
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
        local stateData = mockStatebags[id]
        local proxy = {
            set = function(_, key, val, replicate)
                stateData[key] = val
            end
        }
        setmetatable(proxy, {
            __index = stateData,
            __newindex = function(_, k, v)
                stateData[k] = v
            end,
        })
        return { state = proxy }
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

    local function createMockVeh(netId, model, vehClass, plate)
        local veh = {
            id = netId,
            exists = true,
            entityType = 2, -- Vehicle
            model = model or 1111,
            vehClass = vehClass, -- pode ser nil explicitamente
            plate = plate or 'TEST123',
            coords = vector3(100.0, 200.0, 10.0),
        }
        mockEntities[netId] = veh
        mockEntityCoords[veh] = veh.coords
        mockStatebags[netId] = {}
        return veh
    end

    -- ─── 1. NetId Strict & Entity Validation ──────────────────────────────────
    do
        TrackerManager._test.reset()

        -- TRK-ENTITY-01: Non-existent netId rejected with zero mutation
        local resNone = TrackerManager.ObserveVehicle(999, 'test')
        check('TRK-ENTITY-01 Non-existent netId returns not_vehicle/entity_not_found', resNone.state == 'NONE' and resNone.err == 'entity_not_found')
        check('TRK-ENTITY-01 Zero trackers stored for non-existent netId', mapCount(TrackerManager._test.getTrackers()) == 0)

        -- TRK-ENTITY-02: Ped entity rejected
        mockEntities[501] = { id = 501, exists = true, entityType = 1, model = 1234 }
        local resPed = TrackerManager.ObserveVehicle(501, 'test')
        check('TRK-ENTITY-02 Ped entity rejected with not_vehicle', resPed.state == 'NONE' and resPed.err == 'not_vehicle')
        check('TRK-ENTITY-02 Ped entity creates ZERO trackers', mapCount(TrackerManager._test.getTrackers()) == 0)

        -- TRK-ENTITY-03: Object entity rejected
        mockEntities[502] = { id = 502, exists = true, entityType = 3, model = 4321 }
        local resObj = TrackerManager.ObserveVehicle(502, 'test')
        check('TRK-ENTITY-03 Object entity rejected with not_vehicle', resObj.state == 'NONE' and resObj.err == 'not_vehicle')
        check('TRK-ENTITY-03 Object entity creates ZERO trackers', mapCount(TrackerManager._test.getTrackers()) == 0)

        -- TRK-ENTITY-04: Real vehicle entity accepted
        local vReal = createMockVeh(503, 7777, 7, 'VALID1')
        local resVeh = TrackerManager.ObserveVehicle(503, 'test', 1.0)
        check('TRK-ENTITY-04 Vehicle entity accepted', resVeh.hasTracker == true and resVeh.state == 'ACTIVE')
        check('TRK-ENTITY-04 Statebag vpChopTrackerId confirmed', mockStatebags[503].vpChopTrackerId == resVeh.trackerId)
    end

    -- ─── 2. NetId Alias & Malformed Numeric Rejections ────────────────────────
    do
        TrackerManager._test.reset()
        local vAlias = createMockVeh(1501, 7777, 7, 'ALIAS1')
        local trkOrig = TrackerManager.ObserveVehicle(1501, 'test', 1.0)
        local initialCount = mapCount(TrackerManager._test.getTrackers())
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)

        -- TRK-NETID-ALIAS-01: String netId rejected without creating alias
        local resStr = TrackerManager.StartRemoval(1, '1501')
        check('TRK-NETID-ALIAS-01 String "1501" rejected with invalid_net', resStr.ok == false and resStr.err == 'invalid_net')

        local resStrZero = TrackerManager.StartRemoval(1, '01501')
        check('TRK-NETID-ALIAS-01 String "01501" rejected with invalid_net', resStrZero.ok == false and resStrZero.err == 'invalid_net')

        local resStrFloat = TrackerManager.StartRemoval(1, '1501.0')
        check('TRK-NETID-ALIAS-01 String "1501.0" rejected with invalid_net', resStrFloat.ok == false and resStrFloat.err == 'invalid_net')

        check('TRK-NETID-ALIAS-01 Zero new trackers created by string aliases', mapCount(TrackerManager._test.getTrackers()) == initialCount)
        check('TRK-NETID-ALIAS-01 Original tracker remains authority', mockStatebags[1501].vpChopTrackerId == trkOrig.trackerId)

        -- TRK-NETID-INVALID-01: Non-positive or non-integer numbers rejected
        check('TRK-NETID-INVALID-01 NetId 0 rejected', TrackerManager.ObserveVehicle(0, 'test').err == 'invalid_net')
        check('TRK-NETID-INVALID-01 NetId -1 rejected', TrackerManager.ObserveVehicle(-1, 'test').err == 'invalid_net')
        check('TRK-NETID-INVALID-01 Float 1.5 rejected', TrackerManager.ObserveVehicle(1.5, 'test').err == 'invalid_net')
        check('TRK-NETID-INVALID-01 math.huge rejected', TrackerManager.ObserveVehicle(math.huge, 'test').err == 'invalid_net')
    end

    -- ─── 3. Pre-Auth Observation Gate in StartRemoval ─────────────────────────
    do
        TrackerManager._test.reset()
        local vUnobs = createMockVeh(1601, 7777, 7, 'UNOBSERVED')
        TrackerManager._test.setRoll(0.01) -- would generate ACTIVE if observed

        -- TRK-START-AUTH-01: Distant player calling StartRemoval produces ZERO mutation
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(500.0, 500.0, 10.0) -- distant
        local resDistFail = TrackerManager.StartRemoval(1, 1601)
        check('TRK-START-AUTH-01 Distant player rejected with distance', resDistFail.ok == false and resDistFail.err == 'distance')
        check('TRK-START-AUTH-01 Distant attempt created ZERO trackers', mapCount(TrackerManager._test.getTrackers()) == 0)
        check('TRK-START-AUTH-01 Distant attempt created ZERO statebags', mockStatebags[1601].vpChopTrackerId == nil)
        check('TRK-START-AUTH-01 Distant attempt created ZERO active removals', TrackerManager._test.getActiveRemovals()[1] == nil)

        -- TRK-START-AUTH-02: Missing tool produces ZERO mutation
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0) -- near
        mockInventory[1] = { pliers = 0, screwdriver = 0 }
        local resNoToolFail = TrackerManager.StartRemoval(1, 1601)
        check('TRK-START-AUTH-02 No tool attempt rejected with no_tool', resNoToolFail.ok == false and resNoToolFail.err == 'no_tool')
        check('TRK-START-AUTH-02 No tool attempt created ZERO trackers', mapCount(TrackerManager._test.getTrackers()) == 0)
        check('TRK-START-AUTH-02 No tool attempt created ZERO statebags', mockStatebags[1601].vpChopTrackerId == nil)

        -- TRK-START-AUTH-03: Legitimate start observes exactly once
        mockInventory[1] = { pliers = 1 }
        local resLegitStart = TrackerManager.StartRemoval(1, 1601)
        check('TRK-START-AUTH-03 Legitimate start succeeds', resLegitStart.ok == true and type(resLegitStart.removalToken) == 'string')
        check('TRK-START-AUTH-03 Exactly 1 tracker created', mapCount(TrackerManager._test.getTrackers()) == 1)
        check('TRK-START-AUTH-03 Statebag marker written', mockStatebags[1601].vpChopTrackerId ~= nil)

        -- Second legitimate start replaces token without rerolling
        local firstToken = resLegitStart.removalToken
        local resSecondStart = TrackerManager.StartRemoval(1, 1601)
        check('TRK-START-AUTH-03 Second start succeeds with new token', resSecondStart.ok == true and resSecondStart.removalToken ~= firstToken)
        check('TRK-START-AUTH-03 Still exactly 1 tracker (zero reroll)', mapCount(TrackerManager._test.getTrackers()) == 1)

        TrackerManager._test.setRoll(nil)
    end

    -- ─── 4. CompleteRemoval NetId Strict & State Preservation ─────────────────
    do
        TrackerManager._test.reset()
        local v17 = createMockVeh(1701, 7777, 7, 'COMP_STRICT')
        local trk17 = TrackerManager.ObserveVehicle(1701, 'test', 1.0)
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        TrackerManager._test.setTime(1000)

        local startRes = TrackerManager.StartRemoval(1, 1701)
        local token = startRes.removalToken

        -- TRK-COMP-NETID-01: String netId rejected without consuming active session
        TrackerManager._test.setTime(9000)
        local resStrComp = TrackerManager.CompleteRemoval(1, '1701', token)
        check('TRK-COMP-NETID-01 Complete with string "1701" rejected with invalid_net', resStrComp.ok == false and resStrComp.err == 'invalid_net')
        check('TRK-COMP-NETID-01 Tracker remains ACTIVE', trk17.state == 'ACTIVE')
        check('TRK-COMP-NETID-01 Session was NOT consumed by malformed payload', TrackerManager._test.getActiveRemovals()[1] ~= nil)

        -- Subsequent complete with numeric netId succeeds
        local resLegitComp = TrackerManager.CompleteRemoval(1, 1701, token)
        check('TRK-COMP-NETID-01 Legitimate completion with integer netId succeeds', resLegitComp.ok == true)
        check('TRK-COMP-NETID-01 Tracker transitioned to REMOVED', trk17.state == 'REMOVED')
    end

    -- ─── 5. ClassChances with Unresolved Class ────────────────────────────────
    do
        TrackerManager._test.reset()

        -- TRK-CLASS-01: Super class (0.85) with roll 0.50 -> ACTIVE
        local vSuper = createMockVeh(1801, 7777, 7, 'SUPER7')
        TrackerManager._test.setRoll(0.50)
        local resSuper = TrackerManager.ObserveVehicle(1801, 'test')
        check('TRK-CLASS-01 Super class (0.85) with roll 0.50 is ACTIVE', resSuper.hasTracker == true and resSuper.state == 'ACTIVE')

        -- TRK-CLASS-02: Compact class (0.10) with roll 0.50 -> NONE
        local vCompact = createMockVeh(1802, 1111, 0, 'COMPACT')
        local resCompact = TrackerManager.ObserveVehicle(1802, 'test')
        check('TRK-CLASS-02 Compact class (0.10) with roll 0.50 is NONE', resCompact.hasTracker == false and resCompact.state == 'NONE')

        -- TRK-CLASS-03: Unknown class (nil) uses DefaultChance (0.40) with roll 0.35 -> ACTIVE
        local vUnkActive = createMockVeh(1803, 2222, nil, 'UNK_ACT')
        TrackerManager._test.setRoll(0.35)
        local resUnkAct = TrackerManager.ObserveVehicle(1803, 'test')
        check('TRK-CLASS-03 Unresolved class with roll 0.35 is ACTIVE via DefaultChance', resUnkAct.hasTracker == true and resUnkAct.state == 'ACTIVE')

        -- TRK-CLASS-04: Unknown class (nil) uses DefaultChance (0.40) with roll 0.50 -> NONE
        local vUnkNone = createMockVeh(1804, 3333, nil, 'UNK_NONE')
        TrackerManager._test.setRoll(0.50)
        local resUnkNone = TrackerManager.ObserveVehicle(1804, 'test')
        check('TRK-CLASS-04 Unresolved class with roll 0.50 is NONE via DefaultChance', resUnkNone.hasTracker == false and resUnkNone.state == 'NONE')

        TrackerManager._test.setRoll(nil)
    end

    -- ─── 6. Canonical Plate to Evidence Integration ───────────────────────────
    do
        TrackerManager._test.reset()
        TrackerManager._test.setRoll(0.01) -- guarantees ACTIVE tracker
        evidenceCalls = {}

        _G.VPChopMDT = {
            GetRealPlate = function(visiblePlate)
                if visiblePlate == 'FAKE999' then
                    return 'REAL777'
                end
                return visiblePlate
            end
        }

        local vEvid = createMockVeh(1901, 7777, 7, '  FAKE999  ')
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        TrackerManager._test.setTime(1000)

        local startEv = TrackerManager.StartRemoval(1, 1901)
        TrackerManager._test.setTime(9000)
        local compEv = TrackerManager.CompleteRemoval(1, 1901, startEv.removalToken)
        check('TRK-EVID-REAL-01 Complete removal succeeds', compEv.ok == true)
        check('TRK-EVID-REAL-01 Evidence received REAL777 canonical plate', #evidenceCalls == 1 and evidenceCalls[1].plate == 'REAL777' and evidenceCalls[1].actionKey == 'tracker_removal')

        TrackerManager._test.setRoll(nil)
    end

    -- ─── 7. BroadcastPings Same Model + Marker Mismatch ───────────────────────
    do
        TrackerManager._test.reset()
        sentClientEvents = {}
        mockPlayerJobs[1] = 'police'
        mockPlayerJobs[2] = 'civilian'

        local vSameA = createMockVeh(2001, 7777, 7, 'SAME_A')
        local trkSameA = TrackerManager.ObserveVehicle(2001, 'test', 1.0)
        TrackerManager._test.setTime(100000)

        -- Replace statebag with different marker (simulating recycled entity with same model)
        mockStatebags[2001].vpChopTrackerId = 'trk:different_lifecycle'

        -- TRK-PING-RECYCLE-SAME-MODEL-01: Broadcast produces ZERO pings and invalidates stale tracker A
        TrackerManager._test.setTime(120000)
        local pingsStale = TrackerManager.BroadcastPings()
        check('TRK-PING-RECYCLE-SAME-MODEL-01 Marker mismatch produces ZERO pings', pingsStale == 0)
        check('TRK-PING-RECYCLE-SAME-MODEL-01 Zero client events emitted', #sentClientEvents == 0)

        -- Observe new lifecycle B
        local trkSameB = TrackerManager.ObserveVehicle(2001, 'test', 1.0)
        check('TRK-PING-RECYCLE-SAME-MODEL-01 New lifecycle B observed', trkSameB.trackerId ~= trkSameA.trackerId)

        TrackerManager._test.setTime(140000)
        local pingsB = TrackerManager.BroadcastPings()
        check('TRK-PING-RECYCLE-SAME-MODEL-01 Only lifecycle B produces ping', pingsB == 1 and #sentClientEvents == 1 and sentClientEvents[1].target == 1)
    end

    -- ─── 8. Cancel & TTL Expiry ───────────────────────────────────────────────
    do
        TrackerManager._test.reset()
        local vCancel = createMockVeh(2101, 7777, 7, 'CANCEL_TEST')
        local trkCancel = TrackerManager.ObserveVehicle(2101, 'test', 1.0)
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        TrackerManager._test.setTime(1000)

        local startRes = TrackerManager.StartRemoval(1, 2101)
        local token = startRes.removalToken

        -- Cancel with wrong token fails
        local resWrongCancel = TrackerManager.CancelRemoval(1, 'wrong_token')
        check('TRK-CANCEL-01 Cancel with wrong token fails', resWrongCancel.ok == false and resWrongCancel.err == 'invalid_token')
        check('TRK-CANCEL-01 Active removal session remains intact', TrackerManager._test.getActiveRemovals()[1] ~= nil)

        -- Cancel with correct token cleans session
        local resOkCancel = TrackerManager.CancelRemoval(1, token)
        check('TRK-CANCEL-02 Cancel with correct token succeeds', resOkCancel.ok == true)
        check('TRK-CANCEL-02 Session is cleared', TrackerManager._test.getActiveRemovals()[1] == nil)
        check('TRK-CANCEL-02 Tracker remains ACTIVE', trkCancel.state == 'ACTIVE')

        -- TTL Expiry
        TrackerManager._test.setTime(5000)
        startRes = TrackerManager.StartRemoval(1, 2101)
        token = startRes.removalToken

        TrackerManager._test.setTime(5000 + 7000 + 25000) -- elapsed 32000ms > 27000ms expiresAt
        local resExpired = TrackerManager.CompleteRemoval(1, 2101, token)
        check('TRK-TTL-01 Complete after expiresAt fails with expired', resExpired.ok == false and resExpired.err == 'expired')
        check('TRK-TTL-01 Tracker remains ACTIVE', trkCancel.state == 'ACTIVE')
        check('TRK-TTL-01 Expired session was cleared', TrackerManager._test.getActiveRemovals()[1] == nil)
    end

    -- ─── 9. Source Canaries ───────────────────────────────────────────────────
    do
        local f = io.open('server/tracker.lua', 'r')
        if f then
            local code = f:read('*a')
            f:close()
            check('TRK-CANARY-01 server/tracker.lua has zero GetRealPlate(netId)', not code:find('GetRealPlate%(%s*netId%s*%)'))
            check('TRK-CANARY-01 server/tracker.lua has zero trackerPing to -1', not code:find("TriggerClientEvent%(%s*'vp_chopshop:client:trackerPing'%s*,%s*%-1"))
        end

        local fc = io.open('client/tracker.lua', 'r')
        if fc then
            local clientCode = fc:read('*a')
            fc:close()
            check('TRK-CANARY-02 client/tracker.lua does not send plate to startRemoval', not clientCode:find("startRemoval'%s*,%s*false%s*,%s*function.-,%s*netId%s*,%s*plate"))
            check('TRK-CANARY-02 client/tracker.lua does not send class to startRemoval', not clientCode:find("startRemoval'%s*,%s*false%s*,%s*function.-,%s*netId.-,%s*modelClass"))
        end
    end

    -- ─── 10. Locale Parity across 5 Languages ─────────────────────────────────
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
