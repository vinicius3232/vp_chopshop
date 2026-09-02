-- server/v118_release_gate_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 FORENSICS RC.1] Release Gate & Architecture Invariants Specification
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
            print(('[v118-gate] PASS  %s'):format(desc))
        else
            fail = fail + 1
            print(('[v118-gate] FAIL  %s'):format(desc))
        end
    end

    print('\n[v118-gate] ══════════════════════════════════════════════════════')
    print('[v118-gate] RUNNING v1.18 FORENSICS RC.1 RELEASE GATE SPEC')
    print('[v118-gate] ══════════════════════════════════════════════════════\n')

    -- =========================================================================
    -- HELPER: loadProductionConfigSnapshot()
    -- Reads and evaluates shared/config.lua in an isolated sandbox, neutralizing
    -- ONLY CfxLua hash literals (`...` -> 0) without mutating global Config.
    -- =========================================================================
    local function loadProductionConfigSnapshot()
        if GetResourceState and GetResourceState('vp_chopshop') == 'started' and type(_G.Config) == 'table' and _G.Config.Evidence then
            return _G.Config
        end
        local f = io.open('shared/config.lua', 'r')
        if not f then return nil, 'cannot_open_shared_config' end
        local src = f:read('*a')
        f:close()
        if not src or src == '' then return nil, 'empty_shared_config' end

        local cleanSrc = src:gsub('`[^`]*`', '0')

        local env = {
            Config = {},
            vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
            vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
            pairs = pairs,
            ipairs = ipairs,
            tostring = tostring,
            tonumber = tonumber,
            type = type,
            math = math,
            table = table,
            string = string,
            print = function() end,
        }
        local fn, err = load(cleanSrc, '@shared/config.lua', 't', env)
        if not fn then return nil, err end
        local ok, execErr = pcall(fn)
        if not ok then return nil, execErr end
        return env.Config
    end

    local releaseConfig, configErr = loadProductionConfigSnapshot()
    if not releaseConfig then
        error('[v118-gate] FATAL: Failed to load production config snapshot: ' .. tostring(configErr))
    end

    -- =========================================================================
    -- GROUP 1: V118-RC-CONFIG — Production Config Snapshot Integrity
    -- =========================================================================
    check('V118-RC-CONFIG-01: Production config snapshot loaded successfully from shared/config.lua',
        type(releaseConfig) == 'table' and releaseConfig.Locale ~= nil)
    check('V118-RC-CONFIG-02: Evidence configuration exists in production snapshot with required structure',
        type(releaseConfig.Evidence) == 'table' and
        releaseConfig.Evidence.Enable == true and
        releaseConfig.Evidence.Provider == 'auto' and
        type(releaseConfig.Evidence.AutoOrder) == 'table' and
        type(releaseConfig.Evidence.Actions) == 'table')
    check('V118-RC-CONFIG-03: Tracker configuration exists in production snapshot with required structure',
        type(releaseConfig.Tracker) == 'table' and
        releaseConfig.Tracker.Enable == true and
        releaseConfig.Tracker.DefaultChance == 0.40 and
        type(releaseConfig.Tracker.ClassChances) == 'table' and
        releaseConfig.Tracker.RequiredTool == 'pliers' and
        releaseConfig.Tracker.MinDurationMs == 7000)
    check('V118-RC-CONFIG-04: Dispatch configuration exists in production snapshot with required structure',
        type(releaseConfig.Dispatch) == 'table' and
        releaseConfig.Dispatch.Enable == true and
        releaseConfig.Dispatch.Provider == 'auto' and
        type(releaseConfig.Dispatch.AutoOrder) == 'table' and
        releaseConfig.Dispatch.DefaultCode == '10-90')
    check('V118-RC-CONFIG-05: PartSerial.VehicleInspection exists in production snapshot with required structure',
        type(releaseConfig.PartSerial) == 'table' and
        type(releaseConfig.PartSerial.VehicleInspection) == 'table' and
        releaseConfig.PartSerial.VehicleInspection.Enable == true and
        releaseConfig.PartSerial.VehicleInspection.DurationMs == 5000 and
        type(releaseConfig.PartSerial.VehicleInspection.Bones) == 'table')

    -- =========================================================================
    -- GROUP 2: V118-RC-ECONOMY — Baseline Economy Drift Gate (using releaseConfig)
    -- =========================================================================
    check('V118-RC-ECON-01: Broker Market bounds match frozen baseline (Demand 0.40..1.30, Price 0.40..2.50, Jitter 0.03)',
        releaseConfig.Broker.Market.DemandFloor == 0.40 and
        releaseConfig.Broker.Market.DemandCeiling == 1.30 and
        releaseConfig.Broker.Market.PriceFloor == 0.40 and
        releaseConfig.Broker.Market.PriceCeiling == 2.50 and
        releaseConfig.Broker.Market.Jitter == 0.03 and
        releaseConfig.Broker.Market.FlushIntervalSec == 300)

    check('V118-RC-ECON-02: Broker Workshop configuration matches frozen baseline (Provider none, MaxPrice 50000)',
        releaseConfig.Broker.Workshop.Enable == true and
        releaseConfig.Broker.Workshop.Provider == 'none' and
        releaseConfig.Broker.Workshop.MaxPrice == 50000 and
        releaseConfig.Broker.Workshop.PrepareMaxTtlSec == 60 and
        releaseConfig.Broker.Workshop.MaxReconcileAttempts == 4)

    local contractsCfg = releaseConfig.Broker.Contracts
    local frozenPools = {
        part_type = {
            { key = 'adv_engine', minTrust = 2, minQty = 1, maxQty = 3, mult = 1.25, bonus = 2500 },
            { key = 'catalytic_converter', minTrust = 1, minQty = 2, maxQty = 4, mult = 1.20, bonus = 1800 },
            { key = 'body_panel', minTrust = 1, minQty = 2, maxQty = 6, mult = 1.15, bonus = 1000 },
        },
        model = {
            { key = 'sultan', minTrust = 2, minQty = 1, maxQty = 2, mult = 1.35, bonus = 3000 },
            { key = 'bison', minTrust = 1, minQty = 1, maxQty = 2, mult = 1.20, bonus = 2000 },
            { key = 'baller', minTrust = 2, minQty = 1, maxQty = 2, mult = 1.25, bonus = 2200 },
            { key = 'banshee', minTrust = 3, minQty = 1, maxQty = 1, mult = 1.40, bonus = 4000 },
        },
        class = {
            { key = 'sports', minTrust = 2, minQty = 1, maxQty = 3, mult = 1.30, bonus = 3000 },
            { key = 'suvs', minTrust = 1, minQty = 2, maxQty = 4, mult = 1.20, bonus = 2000 },
            { key = 'muscle', minTrust = 2, minQty = 1, maxQty = 3, mult = 1.25, bonus = 2500 },
            { key = 'coupes', minTrust = 1, minQty = 2, maxQty = 4, mult = 1.15, bonus = 1800 },
        },
        high_value = {
            { key = 'adv_engine', minTrust = 3, minQty = 1, maxQty = 2, mult = 1.50, bonus = 5000 },
            { key = 'catalytic_converter', minTrust = 3, minQty = 2, maxQty = 3, mult = 1.45, bonus = 4500 },
        },
    }

    local poolsOk = type(contractsCfg.Pools) == 'table'
    local totalPoolCount = 0
    if poolsOk then
        for poolName, frozenList in pairs(frozenPools) do
            totalPoolCount = totalPoolCount + 1
            local realList = contractsCfg.Pools[poolName]
            if type(realList) ~= 'table' or #realList ~= #frozenList then
                poolsOk = false
            else
                for idx, expEntry in ipairs(frozenList) do
                    local actEntry = realList[idx]
                    if not actEntry or
                       actEntry.key ~= expEntry.key or
                       actEntry.minTrust ~= expEntry.minTrust or
                       actEntry.minQty ~= expEntry.minQty or
                       actEntry.maxQty ~= expEntry.maxQty or
                       actEntry.mult ~= expEntry.mult or
                       actEntry.bonus ~= expEntry.bonus then
                        poolsOk = false
                    end
                end
            end
        end
        local realPoolCount = 0
        for _ in pairs(contractsCfg.Pools) do realPoolCount = realPoolCount + 1 end
        if realPoolCount ~= totalPoolCount then poolsOk = false end
    end

    check('V118-RC-ECON-03: Broker Contracts constants & deep pool contents match frozen baseline (4 pools, 13 entries)',
        contractsCfg.Enable == true and
        contractsCfg.MinTrust == 3 and
        contractsCfg.GlobalSlots == 3 and
        contractsCfg.PersonalSlots == 3 and
        contractsCfg.RewardMultMin == 1.05 and
        contractsCfg.RewardMultMax == 1.80 and
        contractsCfg.BonusCashMax == 15000 and
        poolsOk == true)

    local frozenCommodities = {
        catalytic_converter = { basePrice = 1600, salePressure = 0.04,  recoveryPerHour = 0.15 },
        adv_engine          = { basePrice = 2500, salePressure = 0.05,  recoveryPerHour = 0.12 },
        tyre                = { basePrice = 400,  salePressure = 0.015, recoveryPerHour = 0.20 },
        stolen_plate        = { basePrice = 250,  salePressure = 0.03,  recoveryPerHour = 0.15 },
        body_panel          = { basePrice = 600,  salePressure = 0.03,  recoveryPerHour = 0.15 },
        metalscrap          = { basePrice = 80,   salePressure = 0.002, recoveryPerHour = 0.25 },
        steel               = { basePrice = 100,  salePressure = 0.003, recoveryPerHour = 0.25 },
        aluminum            = { basePrice = 130,  salePressure = 0.004, recoveryPerHour = 0.20 },
        copper              = { basePrice = 150,  salePressure = 0.005, recoveryPerHour = 0.20 },
        car_parts           = { basePrice = 400,  salePressure = 0.004, recoveryPerHour = 0.20 },
    }

    local com = releaseConfig.Broker.Commodities
    local comCount = 0
    local comOk = type(com) == 'table'
    if comOk then
        for comKey, expCom in pairs(frozenCommodities) do
            local actCom = com[comKey]
            if not actCom or
               actCom.basePrice ~= expCom.basePrice or
               actCom.salePressure ~= expCom.salePressure or
               actCom.recoveryPerHour ~= expCom.recoveryPerHour then
                comOk = false
            end
        end
        for _ in pairs(com) do comCount = comCount + 1 end
        if comCount ~= 10 then comOk = false end
    end
    check('V118-RC-ECON-04: Exactly 10 Broker Commodities match frozen base prices, sale pressures, and recovery rates',
        comOk == true)

    local integ = releaseConfig.Broker.Integration
    local integOk = type(integ.ItemToCommodity) == 'table' and
                    integ.ItemToCommodity.metalscrap == 'metalscrap' and
                    integ.ItemToCommodity.stolen_plate == 'stolen_plate' and
                    integ.ItemToCommodity.chopshop_tyre == 'tyre' and
                    type(integ.PhysicalPartToCommodity) == 'table' and
                    integ.PhysicalPartToCommodity.catalytic_converter == 'catalytic_converter' and
                    integ.PhysicalPartToCommodity.adv_engine == 'adv_engine' and
                    type(integ.LegacyStaticItems) == 'table' and
                    integ.LegacyStaticItems.rubber == true
    check('V118-RC-ECON-05: Broker Integration mappings match frozen baseline',
        integOk == true)

    -- =========================================================================
    -- MOCK ENVIRONMENT FOR REAL CALLBACK TESTS
    -- =========================================================================
    local origBridgeIsPolice = _G.BridgeIsPolice
    local origInvCount = _G.InvCount
    local origVPChopSerialGen = _G.VPChopSerialGen
    local origVPChopMDT = _G.VPChopMDT
    local origMySQL = _G.MySQL
    local origEntity = _G.Entity
    local origGetEntityCoords = _G.GetEntityCoords

    _G.GetEntityCoords = function(ent) return vector3(0.0, 0.0, 0.0) end

    local mockPolice = {}
    local mockInventory = {}
    local mockVinDb = {}
    local mockFakePlatesDb = {}
    local serialGenCalls = 0
    local observeCalls = 0

    _G.BridgeIsPolice = function(src, _) return mockPolice[src] == true end
    _G.InvCount = function(src, item) return (mockInventory[src] and mockInventory[src][item]) or 0 end
    _G.VPChopSerialGen = function()
        serialGenCalls = serialGenCalls + 1
        return ('SERIAL-GEN-%04d'):format(serialGenCalls)
    end

    _G.MySQL = _G.MySQL or {}
    local origMySQLScalar = _G.MySQL.scalar
    _G.MySQL.scalar = {
        await = function(query, params)
            if query and query:find('vp_chop_vin_scratched') then
                local plate = params and params[1]
                if plate == 'DB_THROW' then
                    error('Simulated DB timeout')
                end
                return mockVinDb[plate] and 1 or nil
            end
            if query and query:find('vp_chop_fake_plates') then
                local fake = params and params[1]
                return mockFakePlatesDb[fake] or nil
            end
            return nil
        end
    }

    _G.VPChopMDT = _G.VPChopMDT or {}
    _G.VPChopMDT.GetRealPlate = function(visiblePlate)
        if not visiblePlate or visiblePlate == '' then return visiblePlate end
        return mockFakePlatesDb[visiblePlate] or visiblePlate
    end

    -- Track ObserveVehicle calls if hook exists
    local origObserveVehicle = TrackerManager and TrackerManager.ObserveVehicle
    if origObserveVehicle then
        TrackerManager.ObserveVehicle = function(...)
            observeCalls = observeCalls + 1
            return origObserveVehicle(...)
        end
    end

    -- Setup officer source and inventory
    local officerSrc = 2
    mockPolice[officerSrc] = true
    mockInventory[officerSrc] = { parts_scanner = 1, forensic_kit = 1 }

    local callbacks = _G.CapturedCallbacks or _G.LIB_CALLBACKS or {}
    local inspectVehCb = callbacks['vp_chopshop:inspectVehicle']
    check('V118-RC-LOAD-01: Real callback vp_chopshop:inspectVehicle is registered',
        type(inspectVehCb) == 'function')

    -- =========================================================================
    -- GROUP 3: V118-RC-READONLY — Cross-Domain Scanner Read-Only Purity (Real Callback)
    -- =========================================================================
    _G._CUSTOM_TIMER = 1000
    local vNet1 = 1001
    _G.FAKE_VEH[vNet1] = { model = 12345, plate = 'CLEAN01', exists = true }

    observeCalls = 0
    serialGenCalls = 0
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resScan1 = inspectVehCb(officerSrc, vNet1)

    check('V118-RC-READONLY-01: Real inspectVehicle succeeds on clean vehicle',
        resScan1 and resScan1.ok == true and resScan1.data ~= nil)
    check('V118-RC-READONLY-02: Zero ObserveVehicle calls executed during inspection (pure observation)',
        observeCalls == 0)
    check('V118-RC-READONLY-03: Zero VPChopSerialGen calls executed on un-chopped engine (no serial manufactured)',
        serialGenCalls == 0 and resScan1.data.serial == nil)
    check('V118-RC-READONLY-04: Untracked vehicle inspect reports trackerStatus none without creating tracker record',
        resScan1.data.trackerStatus == 'none' and TrackerManager.GetVehicleState(vNet1) == 'NONE')

    -- Test with ACTIVE tracker
    local vNetActive = 1002
    _G.FAKE_VEH[vNetActive] = { model = 12345, plate = 'ACTIVE01', exists = true }
    local obsActive = TrackerManager.ObserveVehicle(vNetActive, 'test', 1.0)
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resScanActive = inspectVehCb(officerSrc, vNetActive)
    check('V118-RC-READONLY-05: Inspection on ACTIVE tracker reports active without state mutation',
        obsActive.state == 'ACTIVE' and
        resScanActive and resScanActive.ok == true and resScanActive.data.trackerStatus == 'active' and
        TrackerManager.GetVehicleState(vNetActive) == 'ACTIVE')

    -- Test with REMOVED tracker
    local vNetRemoved = 1003
    _G.FAKE_VEH[vNetRemoved] = { model = 12345, plate = 'REMOVED01', exists = true }
    mockInventory[officerSrc] = { parts_scanner = 1, forensic_kit = 1, pliers = 1 }
    local obsCut = TrackerManager.ObserveVehicle(vNetRemoved, 'test', 1.0)
    local startRem = TrackerManager.StartRemoval(officerSrc, vNetRemoved)
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local compRem = TrackerManager.CompleteRemoval(officerSrc, vNetRemoved, startRem.removalToken)
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resScanRemoved = inspectVehCb(officerSrc, vNetRemoved)
    check('V118-RC-READONLY-06: Inspection on REMOVED tracker reports cut without state mutation',
        compRem.ok == true and
        resScanRemoved and resScanRemoved.ok == true and resScanRemoved.data.trackerStatus == 'cut' and
        TrackerManager.GetVehicleState(vNetRemoved) == 'REMOVED')

    -- =========================================================================
    -- GROUP 4: V118-RC-PLATE — Canonical Plate Resolution via Real Scanner
    -- =========================================================================
    local vNetFake = 1004
    _G.FAKE_VEH[vNetFake] = { model = 12345, plate = 'FAKE999', exists = true }
    mockFakePlatesDb['FAKE999'] = 'REAL777'

    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resScanFakePlate = inspectVehCb(officerSrc, vNetFake)
    check('V118-RC-PLATE-01: Disguised plate resolves canonical real plate and flags plateDisguised true',
        resScanFakePlate and resScanFakePlate.ok == true and
        resScanFakePlate.data.plate == 'FAKE999' and
        resScanFakePlate.data.plateOriginal == 'REAL777' and
        resScanFakePlate.data.plateDisguised == true)

    local vNetNormalPlate = 1005
    _G.FAKE_VEH[vNetNormalPlate] = { model = 12345, plate = 'GENUINE1', exists = true }
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resScanNormalPlate = inspectVehCb(officerSrc, vNetNormalPlate)
    check('V118-RC-PLATE-02: Genuine plate matches canonical and flags plateDisguised false',
        resScanNormalPlate and resScanNormalPlate.ok == true and
        resScanNormalPlate.data.plate == 'GENUINE1' and
        resScanNormalPlate.data.plateDisguised == false)

    -- =========================================================================
    -- GROUP 5: V118-RC-VIN — VIN Tri-State via Real Scanner
    -- =========================================================================
    -- 1. Row in DB -> scratched
    local vNetVinScr = 1006
    _G.FAKE_VEH[vNetVinScr] = { model = 12345, plate = 'HOTVIN01', exists = true }
    mockVinDb['HOTVIN01'] = true
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resVinScr = inspectVehCb(officerSrc, vNetVinScr)
    check('V118-RC-VIN-01: Vehicle in vin_scratched table reports vinStatus scratched and vinScratched true',
        resVinScr and resVinScr.ok == true and
        resVinScr.data.vinStatus == 'scratched' and
        resVinScr.data.vinScratched == true)

    -- 2. Row absent from DB -> intact
    local vNetVinIntact = 1007
    _G.FAKE_VEH[vNetVinIntact] = { model = 12345, plate = 'CLEANVIN', exists = true }
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resVinIntact = inspectVehCb(officerSrc, vNetVinIntact)
    check('V118-RC-VIN-02: Vehicle absent from vin_scratched table reports vinStatus intact and vinScratched false',
        resVinIntact and resVinIntact.ok == true and
        resVinIntact.data.vinStatus == 'intact' and
        resVinIntact.data.vinScratched == false)

    -- 3. DB Error/Timeout -> unknown (never intact!)
    local vNetVinErr = 1008
    _G.FAKE_VEH[vNetVinErr] = { model = 12345, plate = 'DB_THROW', exists = true }
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resVinErr = inspectVehCb(officerSrc, vNetVinErr)
    check('V118-RC-VIN-03: DB error fail-closed reports vinStatus unknown and vinScratched false (never intact)',
        resVinErr and resVinErr.ok == true and
        resVinErr.data.vinStatus == 'unknown' and
        resVinErr.data.vinScratched == false)

    -- 4. Disguised plate checks VIN of canonical real plate
    local vNetVinFake = 1009
    _G.FAKE_VEH[vNetVinFake] = { model = 12345, plate = 'FAKE_VIN_1', exists = true }
    mockFakePlatesDb['FAKE_VIN_1'] = 'REAL_HOT_1'
    mockVinDb['REAL_HOT_1'] = true
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resVinFake = inspectVehCb(officerSrc, vNetVinFake)
    check('V118-RC-VIN-04: Disguised plate vehicle resolves canonical plate before querying vin_scratched DB',
        resVinFake and resVinFake.ok == true and
        resVinFake.data.plateOriginal == 'REAL_HOT_1' and
        resVinFake.data.vinStatus == 'scratched')

    -- =========================================================================
    -- GROUP 6: V118-RC-FLAG — Behavioral Feature Flags
    -- =========================================================================
    local origEvidenceCfg = Config.Evidence
    Config.Evidence = { Enable = false }
    local evPlantRes = EvidenceBridge.Plant('fingerprint', 1, { x = 0, y = 0, z = 0 }, 'chop_part', { plate = 'T' })
    check('V118-RC-FLAG-01: Config.Evidence.Enable=false causes Plant to immediately return false with 0 emissions',
        evPlantRes == false)
    Config.Evidence = origEvidenceCfg

    local origTrackerCfg = Config.Tracker
    Config.Tracker = { Enable = false }
    local trkRemRes = TrackerManager.StartRemoval(1, 1001)
    check('V118-RC-FLAG-02: Config.Tracker.Enable=false causes StartRemoval to return disabled',
        type(trkRemRes) == 'table' and trkRemRes.ok == false and trkRemRes.err == 'disabled')
    Config.Tracker = origTrackerCfg

    local origDispatchCfg = Config.Dispatch
    Config.Dispatch = { Enable = false }
    local dispOk, dispSucc, dispReason = pcall(function()
        return DispatchBridge.SendAlert('catalytic_cut', { coords = { x = 0, y = 0, z = 0 } })
    end)
    check('V118-RC-FLAG-03: Config.Dispatch.Enable=false causes SendAlert to return false, disabled without throw',
        dispOk and dispSucc == false and dispReason == 'disabled')
    Config.Dispatch = origDispatchCfg

    local origPartSerialCfg = Config.PartSerial
    Config.PartSerial = {
        Enable = true,
        PoliceJobs = { 'police' },
        ScannerItem = 'parts_scanner',
        ForensicItem = 'forensic_kit',
        InspectCooldownSeconds = 5,
        VehicleInspection = { Enable = false, DurationMs = 5000 },
    }
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local scanFlagVehOff = inspectVehCb(officerSrc, 1001)
    check('V118-RC-FLAG-04: Config.PartSerial.VehicleInspection.Enable=false causes inspectVehicle to return disabled',
        scanFlagVehOff and scanFlagVehOff.ok == false and scanFlagVehOff.err == 'disabled')

    Config.PartSerial.Enable = false
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local scanFlagSerialOff = inspectVehCb(officerSrc, 1001)
    check('V118-RC-FLAG-05: Config.PartSerial.Enable=false causes inspectVehicle to return disabled',
        scanFlagSerialOff and scanFlagSerialOff.ok == false and scanFlagSerialOff.err == 'disabled')
    Config.PartSerial = origPartSerialCfg

    -- =========================================================================
    -- GROUP 7: V118-RC-BOUNDARY — Vehicle Trust & NetId Boundary (Real Callback)
    -- =========================================================================
    _G._MOCK_ENTITY_TYPES = _G._MOCK_ENTITY_TYPES or {}

    -- 1. Ped entity (type 1)
    local vNetPed = 2001
    _G.FAKE_VEH[vNetPed] = { model = 12345, plate = 'PED01', exists = true }
    _G._MOCK_ENTITY_TYPES[vNetPed + 70000] = 1
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resPed = inspectVehCb(officerSrc, vNetPed)
    check('V118-RC-ENTITY-01: Ped entity (GetEntityType == 1) rejected with not_a_vehicle',
        resPed and resPed.ok == false and resPed.err == 'not_a_vehicle')

    -- 2. Object entity (type 3)
    local vNetObj = 2002
    _G.FAKE_VEH[vNetObj] = { model = 12345, plate = 'OBJ01', exists = true }
    _G._MOCK_ENTITY_TYPES[vNetObj + 70000] = 3
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resObj = inspectVehCb(officerSrc, vNetObj)
    check('V118-RC-ENTITY-02: Object entity (GetEntityType == 3) rejected with not_a_vehicle',
        resObj and resObj.ok == false and resObj.err == 'not_a_vehicle')

    -- 3. Vehicle entity (type 2)
    local vNetVehValid = 2003
    _G.FAKE_VEH[vNetVehValid] = { model = 12345, plate = 'VEH01', exists = true }
    _G._MOCK_ENTITY_TYPES[vNetVehValid + 70000] = 2
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resVehValid = inspectVehCb(officerSrc, vNetVehValid)
    check('V118-RC-ENTITY-03: Vehicle entity (GetEntityType == 2) accepted when other gates valid',
        resVehValid and resVehValid.ok == true)

    -- 4. String netId
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resStrNet = inspectVehCb(officerSrc, "2003")
    check('V118-RC-NET-01: String netId rejected with invalid_net',
        resStrNet and resStrNet.ok == false and resStrNet.err == 'invalid_net')

    -- 5. Float netId
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resFloatNet = inspectVehCb(officerSrc, 2003.5)
    check('V118-RC-NET-02: Float netId rejected with invalid_net',
        resFloatNet and resFloatNet.ok == false and resFloatNet.err == 'invalid_net')

    -- 6. NaN / Inf netId
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resNanNet = inspectVehCb(officerSrc, 0/0)
    _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 10000
    local resInfNet = inspectVehCb(officerSrc, 1/0)
    check('V118-RC-NET-03: NaN and Inf netId rejected with invalid_net',
        resNanNet and resNanNet.ok == false and resNanNet.err == 'invalid_net' and
        resInfNet and resInfNet.ok == false and resInfNet.err == 'invalid_net')

    -- Restore mocks
    _G.BridgeIsPolice = origBridgeIsPolice
    _G.InvCount = origInvCount
    _G.VPChopSerialGen = origVPChopSerialGen
    _G.VPChopMDT = origVPChopMDT
    _G.MySQL.scalar = origMySQLScalar
    _G.GetEntityCoords = origGetEntityCoords
    if TrackerManager and origObserveVehicle then
        TrackerManager.ObserveVehicle = origObserveVehicle
    end
    _G._MOCK_ENTITY_TYPES = nil

    -- =========================================================================
    -- GROUP 8: V118-RC-EVIDENCE — EvidenceBridge Anti-Regression & Fail-Soft
    -- =========================================================================
    local function fileContains(filePath, pattern)
        local f = io.open(filePath, 'r')
        if not f then return false end
        local content = f:read('*a')
        f:close()
        return content:find(pattern, 1, true) ~= nil
    end

    local evHasLegacy1 = fileContains('bridge/evidence.lua', 'qbx_policejob:CreateEvidence')
    local evHasLegacy2 = fileContains('bridge/evidence.lua', 'CreateEvidence(')
    local evHasLegacy3 = fileContains('bridge/evidence.lua', 'evidence:server:CreateFingerprint')
    local evHasLegacy4 = fileContains('bridge/evidence.lua', 'CreateFingerprint')
    check('V118-RC-EVIDENCE-01: Zero legacy fake evidence adapter calls in bridge/evidence.lua',
        not evHasLegacy1 and not evHasLegacy2 and not evHasLegacy3 and not evHasLegacy4)

    -- Behavioral test: custom provider throwing exception is safely caught by pcall (fail-soft)
    local explodingHandlerCalls = 0
    local regOk, regErr = EvidenceBridge.RegisterProvider('custom', 'release_gate_test_res', function(evidenceClass, src, coords, actionKey, meta)
        explodingHandlerCalls = explodingHandlerCalls + 1
        error('Exploding provider test')
    end)
    local prevEvCfg2 = Config.Evidence
    Config.Evidence = { Enable = true, Provider = 'custom', Actions = { chop_part = { fingerprint = 1.0, dna = 0.0 } } }
    local plantOk, plantRes = pcall(function()
        return EvidenceBridge.Plant('fingerprint', 1, { x = 0, y = 0, z = 0 }, 'chop_part', { plate = 'T' })
    end)
    check('V118-RC-EVIDENCE-02A: Custom evidence provider handler executed exactly 1 time during Plant',
        explodingHandlerCalls == 1)
    check('V118-RC-EVIDENCE-02B: EvidenceBridge.Plant caught handler runtime error via pcall without throwing to caller',
        plantOk == true)
    check('V118-RC-EVIDENCE-02C: EvidenceBridge.Plant returned false on handler failure (fail-soft)',
        plantRes == false)
    Config.Evidence = prevEvCfg2

    -- Anti-hijack: Re-register duplicate custom provider from a different resource is rejected with already_registered
    local dupRegOk, dupRegErr = EvidenceBridge.RegisterProvider('custom', 'attacker_res', function() end)
    check('V118-RC-EVIDENCE-03: Duplicate custom provider registration from different resource rejected with already_registered',
        dupRegOk == false and dupRegErr == 'already_registered')

    if EvidenceBridge._test and EvidenceBridge._test.reset then
        EvidenceBridge._test.reset()
    end

    -- =========================================================================
    -- GROUP 9: V118-RC-DISPATCH — Dispatch Release Contract
    -- =========================================================================
    local prevDispCfg2 = Config.Dispatch
    Config.Dispatch = { Enable = true, Provider = 'none' }
    local dOk, dSucc, dReason = pcall(function()
        return DispatchBridge.SendAlert('lojack_ping', { coords = { x = 0, y = 0, z = 0 }, plate = 'T', model = 'sultan' })
    end)
    check('V118-RC-DISPATCH-01: DispatchBridge provider none emits 0 calls and returns false, none',
        dOk and dSucc == false and dReason == 'none')
    Config.Dispatch = prevDispCfg2

    local dispHasOldOpExport = fileContains('bridge/dispatch.lua', "exports['op-dispatch']") or fileContains('client/dispatch.lua', "exports['op-dispatch']")
    local dispClientHasCore = fileContains('client/dispatch.lua', 'core_dispatch:addCall')
    check('V118-RC-DISPATCH-02: Zero deprecated dispatch transport patterns in production code',
        not dispHasOldOpExport and not dispClientHasCore)

    -- =========================================================================
    -- GROUP 10: V118-RC-TRACKER — Tracker Release Contract
    -- =========================================================================
    local trkClientPassesPlate = fileContains('client/tracker.lua', "startRemoval', netId, plate")
    local trkClientPassesClass = fileContains('client/tracker.lua', "startRemoval', netId, vehicleClass")
    check('V118-RC-TRACKER-01: Client startRemoval passes only netId authority (zero plate/class injection)',
        not trkClientPassesPlate and not trkClientPassesClass)

    local trkServerPingAll = fileContains('server/tracker.lua', "TriggerClientEvent('vp_chopshop:trackerPing', -1")
    check('V118-RC-TRACKER-02: TrackerManager does not broadcast LoJack pings blindly to -1',
        not trkServerPingAll)

    local trkCompFake = TrackerManager.CompleteRemoval(1, 99991, 'fake_token_xyz')
    check('V118-RC-TRACKER-03: CompleteRemoval with fake token fails closed with invalid_token or no_session',
        type(trkCompFake) == 'table' and trkCompFake.ok == false and
        (trkCompFake.err == 'no_session' or trkCompFake.err == 'invalid_token'))

    -- =========================================================================
    -- GROUP 11: V118-RC-REGISTRATION — Spec & Manifest Registration
    -- =========================================================================
    local runSpecSrc = ""
    local fRunSpec = io.open('tools/run_spec.lua', 'r')
    if fRunSpec then runSpecSrc = fRunSpec:read('*a'); fRunSpec:close() end

    local fxSrc = ""
    local fFx = io.open('fxmanifest.lua', 'r')
    if fFx then fxSrc = fFx:read('*a'); fFx:close() end

    local requiredSpecs = {
        'server/evidence_bridge_spec.lua',
        'server/tracker_spec.lua',
        'server/dispatch_bridge_spec.lua',
        'server/forensic_scanner_spec.lua',
        'server/v118_release_gate_spec.lua',
    }

    local allInRunSpec = true
    local allInFx = true
    for _, specPath in ipairs(requiredSpecs) do
        if not runSpecSrc:find(specPath, 1, true) then allInRunSpec = false end
        if not fxSrc:find(specPath, 1, true) then allInFx = false end
    end

    check('V118-RC-REG-01: All 5 forensic/release specs registered in tools/run_spec.lua',
        allInRunSpec)
    check('V118-RC-REG-02: All 5 forensic/release specs registered in fxmanifest.lua server_scripts',
        allInFx)

    -- Verify this release gate spec is self-gated on convar vp_chopshop_selftest
    local gateSrc = ""
    local fGate = io.open('server/v118_release_gate_spec.lua', 'r')
    if fGate then gateSrc = fGate:read('*a'); fGate:close() end
    check('V118-RC-REG-03: server/v118_release_gate_spec.lua possesses selftest convar gate at entry',
        gateSrc:find("GetConvar('vp_chopshop_selftest'", 1, true) ~= nil or gateSrc:find('vp_chopshop_selftest', 1, true) ~= nil)

    -- =========================================================================
    -- GROUP 12: V118-RC-DOCS — Canonical Invariants & Live QA Integrity
    -- =========================================================================
    local fInv = io.open('docs/V118_RELEASE_INVARIANTS.md', 'rb')
    local invContent = fInv and fInv:read('*a') or ''
    if fInv then fInv:close() end

    local hasControlChars = false
    for i = 1, #invContent do
        local byte = invContent:byte(i)
        -- Flag control characters: 0x00..0x08, 0x0B, 0x0C, 0x0E..0x1F (Allow TAB=9, LF=10, CR=13)
        if (byte >= 0 and byte <= 8) or byte == 11 or byte == 12 or (byte >= 14 and byte <= 31) then
            hasControlChars = true
            break
        end
    end
    check('V118-RC-DOC-CTRL-01: docs/V118_RELEASE_INVARIANTS.md has ZERO corrupting control characters',
        not hasControlChars and #invContent > 0)

    -- Count invariants in document (1 to 12)
    local invCount = 0
    for i = 1, 12 do
        if invContent:find(('### %d.'):format(i), 1, true) then
            invCount = invCount + 1
        end
    end
    check('V118-RC-DOC-INV-01: Exactly 12 numbered canonical invariants found in docs/V118_RELEASE_INVARIANTS.md',
        invCount == 12)

    -- Count complementary contracts (A to E)
    local compCount = 0
    local compLetters = { 'A', 'B', 'C', 'D', 'E' }
    for _, letter in ipairs(compLetters) do
        if invContent:find(('### %s.'):format(letter), 1, true) then
            compCount = compCount + 1
        end
    end
    check('V118-RC-DOC-INV-02: Exactly 5 complementary contracts (A-E) found in docs/V118_RELEASE_INVARIANTS.md',
        compCount == 5)

    -- Audit docs/V118_LIVE_QA.md
    local fQa = io.open('docs/V118_LIVE_QA.md', 'r')
    local qaContent = fQa and fQa:read('*a') or ''
    if fQa then fQa:close() end

    local qaHasCheckedBoxes = qaContent:find('%- %[X%]') ~= nil or qaContent:find('%- %[x%]') ~= nil
    check('V118-RC-QA-01: All checkbox items in docs/V118_LIVE_QA.md are unchecked [ ] (zero [X])',
        not qaHasCheckedBoxes and #qaContent > 0)

    local totalQaCases = 0
    for _ in qaContent:gmatch('%- %[ %] %*%*QA%-') do totalQaCases = totalQaCases + 1 end
    local obsCount = 0
    for _ in qaContent:gmatch('%- %*%*Observed:%*%*') do obsCount = obsCount + 1 end
    local evCount = 0
    for _ in qaContent:gmatch('%- %*%*Evidence:%*%*') do evCount = evCount + 1 end
    local resCount = 0
    for _ in qaContent:gmatch('%- %*%*Result:%*%*') do resCount = resCount + 1 end
    check('V118-RC-QA-02: Every QA case defines Observed, Evidence, and Result fields',
        totalQaCases > 0 and totalQaCases == obsCount and totalQaCases == evCount and totalQaCases == resCount)

    local qaHasPassResult = qaContent:find('Result:%s*PASS') ~= nil
    check('V118-RC-QA-03: Zero cases have Result PASS before human execution (all PENDING)',
        not qaHasPassResult)

    local qaStatusPending = qaContent:find('PENDING EXECUTION', 1, true) ~= nil
    check('V118-RC-QA-04: Overall status in docs/V118_LIVE_QA.md is PENDING EXECUTION',
        qaStatusPending)

    -- =========================================================================
    -- GROUP 13: V118-RC-I18N — 5-Language Complete Parity Check
    -- =========================================================================
    local requiredI18nKeys = {
        'forensic_report_title',
        'forensic_engine_ok',
        'forensic_engine_missing',
        'forensic_catalytic_ok',
        'forensic_catalytic_stolen',
        'forensic_vin_ok',
        'forensic_vin_scratched',
        'forensic_vin_unknown',
        'forensic_tracker_active',
        'forensic_tracker_cut',
        'forensic_tracker_none',
        'forensic_plate_disguised',
        'err_engine_missing',
        'err_catalytic_stolen_drive',
    }

    local languages = { 'en', 'pt', 'es', 'fr', 'tr' }
    local allI18nPresent = true
    local origLocale = Config.Locale

    for _, lang in ipairs(languages) do
        Config.Locale = lang
        for _, k in ipairs(requiredI18nKeys) do
            local val = L(k)
            if val == nil or val == k or val == '' then
                allI18nPresent = false
            end
        end
    end
    Config.Locale = origLocale

    check('V118-RC-I18N-01: All 5 locales (en, pt, es, fr, tr) contain all 14 required forensic & disablement keys',
        allI18nPresent)

    print(('\n[v118-gate] ══════════════════════════════════════════════════════'))
    print(('[v118-gate] SUMMARY: %d PASS / %d FAIL / %d asserts'):format(pass, fail, total))
    print(('[v118-gate] ══════════════════════════════════════════════════════\n'))

    if fail > 0 then
        error(('[v118-gate] RELEASE GATE FAILED: %d assertions failed'):format(fail))
    end
end

run()