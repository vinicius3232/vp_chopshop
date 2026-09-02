-- server/tracker_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.2.2] TrackerManager Specification & LoJack Security Test Suite
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
            vehClass = vehClass or 7,
            plate = plate or 'TEST123',
            coords = vector3(100.0, 200.0, 10.0),
        }
        mockEntities[netId] = veh
        mockEntityCoords[veh] = veh.coords
        mockStatebags[netId] = {}
        return veh
    end

    -- ─── 1. Entity Type & Server Authority ────────────────────────────────────
    do
        TrackerManager._test.reset()

        -- TRK-ENTITY-01: Non-existent netId rejected with zero mutation
        local resNone = TrackerManager.ObserveVehicle(999, 'test')
        check('TRK-ENTITY-01 Non-existent netId returns not_vehicle/entity_not_found', resNone.state == 'NONE' and resNone.err == 'entity_not_found')
        check('TRK-ENTITY-01 Zero trackers stored for non-existent netId', #TrackerManager._test.getTrackers() == 0)

        -- TRK-ENTITY-02: Ped entity rejected
        mockEntities[501] = { id = 501, exists = true, entityType = 1, model = 1234 }
        local resPed = TrackerManager.ObserveVehicle(501, 'test')
        check('TRK-ENTITY-02 Ped entity rejected with not_vehicle', resPed.state == 'NONE' and resPed.err == 'not_vehicle')

        -- TRK-ENTITY-03: Object entity rejected
        mockEntities[502] = { id = 502, exists = true, entityType = 3, model = 4321 }
        local resObj = TrackerManager.ObserveVehicle(502, 'test')
        check('TRK-ENTITY-03 Object entity rejected with not_vehicle', resObj.state == 'NONE' and resObj.err == 'not_vehicle')

        -- TRK-ENTITY-04: Real vehicle entity accepted
        local vReal = createMockVeh(503, 7777, 7, 'VALID1')
        local resVeh = TrackerManager.ObserveVehicle(503, 'test', 1.0)
        check('TRK-ENTITY-04 Vehicle entity accepted', resVeh.hasTracker == true and resVeh.state == 'ACTIVE')
        check('TRK-ENTITY-04 Statebag vpChopTrackerId confirmed', mockStatebags[503].vpChopTrackerId == resVeh.trackerId)
    end

    -- ─── 2. ClassChances in Production Path & Deterministic Roll ───────────────
    do
        TrackerManager._test.reset()

        -- TRK-CLASS-01: Class 7 (chance 0.85) with roll 0.50 -> ACTIVE
        local vSuper = createMockVeh(601, 7777, 7, 'SUPER7')
        TrackerManager._test.setRoll(0.50)
        local resSuper = TrackerManager.ObserveVehicle(601, 'test')
        check('TRK-CLASS-01 Super class (0.85) with roll 0.50 is ACTIVE', resSuper.hasTracker == true and resSuper.state == 'ACTIVE')

        -- TRK-CLASS-02: Class 0 (chance 0.10) with roll 0.50 -> NONE
        local vCompact = createMockVeh(602, 1111, 0, 'COMPACT')
        local resCompact = TrackerManager.ObserveVehicle(602, 'test')
        check('TRK-CLASS-02 Compact class (0.10) with roll 0.50 is NONE', resCompact.hasTracker == false and resCompact.state == 'NONE')

        -- TRK-CLASS-03: Unknown class uses DefaultChance (0.40) with roll 0.35 -> ACTIVE
        local vOther = createMockVeh(603, 2222, nil, 'OTHER')
        TrackerManager._test.setRoll(0.35)
        local resOther = TrackerManager.ObserveVehicle(603, 'test')
        check('TRK-CLASS-03 Unknown class uses DefaultChance (0.40) with roll 0.35 -> ACTIVE', resOther.hasTracker == true and resOther.state == 'ACTIVE')

        TrackerManager._test.setRoll(nil)
    end

    -- ─── 3. Canonical Plate Resolution & MDT Integration ──────────────────────
    do
        TrackerManager._test.reset()

        -- Mock VPChopMDT.GetRealPlate expecting visiblePlate string
        local mdtReceivedPlate = nil
        _G.VPChopMDT = {
            GetRealPlate = function(visiblePlate)
                mdtReceivedPlate = visiblePlate
                if visiblePlate == 'FAKE999' then
                    return 'REAL777'
                end
                return visiblePlate
            end
        }

        local vPlate = createMockVeh(701, 7777, 7, '  FAKE999  ')
        local resPlate = TrackerManager.ObserveVehicle(701, 'test', 1.0)
        check('TRK-PLATE-01 MDT received normalized visiblePlate string', mdtReceivedPlate == 'FAKE999')
        check('TRK-PLATE-01 Canonical plate resolved to real plate', resPlate.canonicalPlate == 'REAL777')

        -- Fallback when MDT fails
        _G.VPChopMDT = {
            GetRealPlate = function() error('MDT crash') end
        }
        local vFallback = createMockVeh(702, 7777, 7, 'CLEAN123')
        local resFallback = TrackerManager.ObserveVehicle(702, 'test', 1.0)
        check('TRK-PLATE-02 MDT crash falls back cleanly to visiblePlate', resFallback.canonicalPlate == 'CLEAN123')
    end

    -- ─── 4. StartRemoval, Strict MaxDistance & Token Transaction ──────────────
    do
        TrackerManager._test.reset()
        local v8 = createMockVeh(801, 7777, 7, 'START1')
        TrackerManager.ObserveVehicle(801, 'test', 1.0)

        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0) -- dist = 0.0

        -- TRK-DIST-01: Exact distance 3.5 is accepted
        mockPlayerCoords[1] = vector3(100.0, 203.5, 10.0)
        local resDistOk = TrackerManager.StartRemoval(1, 801)
        check('TRK-DIST-01 Exact MaxDistance (3.5) is accepted', resDistOk.ok == true)

        -- TRK-DIST-02: Distance 3.51 is rejected with distance (strict, zero hidden margin)
        mockPlayerCoords[1] = vector3(100.0, 203.51, 10.0)
        local resDistFar = TrackerManager.StartRemoval(1, 801)
        check('TRK-DIST-02 Distance 3.51 is rejected with distance', resDistFar.ok == false and resDistFar.err == 'distance')

        -- TRK-TOKEN-01: Valid start generates opaque token
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        local resStart = TrackerManager.StartRemoval(1, 801)
        check('TRK-TOKEN-01 StartRemoval returns token', resStart.ok == true and type(resStart.removalToken) == 'string')
    end

    -- ─── 5. CancelRemoval & TTL Expiry ────────────────────────────────────────
    do
        TrackerManager._test.reset()
        local v9 = createMockVeh(901, 7777, 7, 'CANCEL1')
        local trk9 = TrackerManager.ObserveVehicle(901, 'test', 1.0)
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        TrackerManager._test.setTime(1000)

        local startRes = TrackerManager.StartRemoval(1, 901)
        local token = startRes.removalToken

        -- TRK-CANCEL-01: Cancel with wrong token fails
        local resWrongCancel = TrackerManager.CancelRemoval(1, 'wrong_token')
        check('TRK-CANCEL-01 Cancel with wrong token fails', resWrongCancel.ok == false and resWrongCancel.err == 'invalid_token')
        check('TRK-CANCEL-01 Active removal session remains intact', TrackerManager._test.getActiveRemovals()[1] ~= nil)

        -- TRK-CANCEL-02: Cancel with correct token cleans session
        local resOkCancel = TrackerManager.CancelRemoval(1, token)
        check('TRK-CANCEL-02 Cancel with correct token succeeds', resOkCancel.ok == true)
        check('TRK-CANCEL-02 Session is cleared', TrackerManager._test.getActiveRemovals()[1] == nil)
        check('TRK-CANCEL-02 Tracker remains ACTIVE', trk9.state == 'ACTIVE')

        -- TRK-TTL-01: Advance clock past expiresAt -> COMPLETE fails with expired
        TrackerManager._test.setTime(5000)
        startRes = TrackerManager.StartRemoval(1, 901)
        token = startRes.removalToken

        TrackerManager._test.setTime(5000 + 7000 + 25000) -- elapsed 32000ms > 27000ms expiresAt
        local resExpired = TrackerManager.CompleteRemoval(1, 901, token)
        check('TRK-TTL-01 Complete after expiresAt fails with expired', resExpired.ok == false and resExpired.err == 'expired')
        check('TRK-TTL-01 Tracker remains ACTIVE', trk9.state == 'ACTIVE')
        check('TRK-TTL-01 Expired session was cleared', TrackerManager._test.getActiveRemovals()[1] == nil)
    end

    -- ─── 6. CompleteRemoval Old Token & NetId Recycling ───────────────────────
    do
        TrackerManager._test.reset()
        local v10 = createMockVeh(1001, 7777, 7, 'RECYCLE1')
        local trk10 = TrackerManager.ObserveVehicle(1001, 'test', 1.0)
        mockInventory[1] = { pliers = 1 }
        mockPlayerCoords[1] = vector3(100.0, 200.0, 10.0)
        TrackerManager._test.setTime(1000)
        evidenceCalls = {}

        -- TRK-TOKEN-OLD-01: New start invalidates old token
        local resStartA = TrackerManager.StartRemoval(1, 1001)
        local tokenA = resStartA.removalToken

        TrackerManager._test.setTime(2000)
        local resStartB = TrackerManager.StartRemoval(1, 1001)
        local tokenB = resStartB.removalToken

        TrackerManager._test.setTime(10000)
        local resOldComp = TrackerManager.CompleteRemoval(1, 1001, tokenA)
        check('TRK-TOKEN-OLD-01 Completion with old token A rejected with invalid_token', resOldComp.ok == false and resOldComp.err == 'invalid_token')
        check('TRK-TOKEN-OLD-01 Tracker remains ACTIVE', trk10.state == 'ACTIVE')

        -- Legitimate completion with token B
        local resNewComp = TrackerManager.CompleteRemoval(1, 1001, tokenB)
        check('TRK-TOKEN-OLD-01 Completion with new token B succeeds', resNewComp.ok == true)
        check('TRK-TOKEN-OLD-01 Tracker transitioned to REMOVED', trk10.state == 'REMOVED')

        -- TRK-COMP-RECYCLE-01: Model changed before complete -> identity_mismatch
        local v11 = createMockVeh(1101, 8888, 7, 'MOD_RECYCLE')
        local trk11 = TrackerManager.ObserveVehicle(1101, 'test', 1.0)
        TrackerManager._test.setTime(20000)
        local start11 = TrackerManager.StartRemoval(1, 1101)
        local token11 = start11.removalToken

        -- Change model on entity (netId recycled to different car)
        v11.model = 9999
        TrackerManager._test.setTime(28000)
        local resRecycleModel = TrackerManager.CompleteRemoval(1, 1101, token11)
        check('TRK-COMP-RECYCLE-01 Model change before complete rejected with identity_mismatch', resRecycleModel.ok == false and resRecycleModel.err == 'identity_mismatch')
        check('TRK-COMP-RECYCLE-01 Tracker 11 not removed', trk11.state == 'ACTIVE')

        -- TRK-COMP-RECYCLE-02: Same model but statebag marker mismatch -> identity_mismatch
        v11.model = 8888 -- restore model
        mockStatebags[1101].vpChopTrackerId = 'trk:different_lifecycle'
        TrackerManager._test.setTime(35000)
        local start12 = TrackerManager.StartRemoval(1, 1101)
        local token12 = start12.removalToken

        mockStatebags[1101].vpChopTrackerId = 'trk:recycled_tampered'
        TrackerManager._test.setTime(43000)
        local resMarkerMismatch = TrackerManager.CompleteRemoval(1, 1101, token12)
        check('TRK-COMP-RECYCLE-02 Marker mismatch rejected with identity_mismatch', resMarkerMismatch.ok == false and resMarkerMismatch.err == 'identity_mismatch')
    end

    -- ─── 7. BroadcastPings Lifecycle Validation & Stale Cleanup ───────────────
    do
        TrackerManager._test.reset()
        sentClientEvents = {}

        mockPlayerJobs[1] = 'police'
        mockPlayerJobs[2] = 'civilian'

        local vA = createMockVeh(1201, 7777, 7, 'VEH_A')
        local trkA = TrackerManager.ObserveVehicle(1201, 'test', 1.0)
        TrackerManager._test.setTime(100000)

        -- TRK-PING-RECYCLE-01: Veículo A desaparece, netId recebe modelo diferente
        vA.exists = false -- A despawned
        local vB = createMockVeh(1201, 3333, 7, 'VEH_B') -- B spawned on same netId with different model

        TrackerManager._test.setTime(120000)
        local pings = TrackerManager.BroadcastPings()
        check('TRK-PING-RECYCLE-01 Stale tracker A produces ZERO pings', pings == 0)
        check('TRK-PING-RECYCLE-01 Zero client events sent for stale A', #sentClientEvents == 0)

        -- TRK-PING-RECYCLE-02: Veículo B é observado legitimamente
        local trkB = TrackerManager.ObserveVehicle(1201, 'test', 1.0)
        check('TRK-PING-RECYCLE-02 Vehicle B receives new trackerId', trkB.trackerId ~= trkA.trackerId)

        TrackerManager._test.setTime(140000)
        local pingsB = TrackerManager.BroadcastPings()
        check('TRK-PING-RECYCLE-03 Only active tracker B produces ping', pingsB == 1)
        check('TRK-PING-RECYCLE-03 Only police receives ping for B', #sentClientEvents == 1 and sentClientEvents[1].target == 1)
    end

    -- ─── 8. Source Canaries ───────────────────────────────────────────────────
    do
        -- Canary: server/tracker.lua must have zero GetRealPlate(netId) and zero trackerPing to -1
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

    -- ─── 9. Locale Parity across 5 Languages ──────────────────────────────────
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
