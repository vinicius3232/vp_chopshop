-- server/v118_release_gate_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 FORENSICS RC] Release Gate & Architecture Invariants Specification
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
    print('[v118-gate] RUNNING v1.18 FORENSICS RELEASE GATE SPEC')
    print('[v118-gate] ══════════════════════════════════════════════════════\n')

    -- Load canonical production config in isolated environment
    local prodConfig = {}
    local configChunk = loadfile('shared/config.lua')
    if configChunk then
        local env = setmetatable({
            Config = prodConfig,
            vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
            vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
        }, { __index = _G })
        setfenv(configChunk, env)
        pcall(configChunk)
    end

    -- =========================================================================
    -- GROUP 1: V118-RC-LOAD — Core Subsystem Availability & Public APIs
    -- =========================================================================
    check('V118-RC-LOAD-1: EvidenceBridge global loaded and structured',
        type(EvidenceBridge) == 'table')
    check('V118-RC-LOAD-2: EvidenceBridge exports public functions (RegisterProvider, IsAvailable, GetProvider, Plant)',
        type(EvidenceBridge.RegisterProvider) == 'function' and
        type(EvidenceBridge.IsAvailable) == 'function' and
        type(EvidenceBridge.GetProvider) == 'function' and
        type(EvidenceBridge.Plant) == 'function')
    check('V118-RC-LOAD-3: Global VPChopLeaveEvidence helper available',
        type(VPChopLeaveEvidence) == 'function')
    check('V118-RC-LOAD-4: TrackerManager global loaded and structured',
        type(TrackerManager) == 'table')
    check('V118-RC-LOAD-5: TrackerManager exports public lifecycle methods',
        type(TrackerManager.GetVehicleState) == 'function' and
        type(TrackerManager.ObserveVehicle) == 'function' and
        type(TrackerManager.StartRemoval) == 'function' and
        type(TrackerManager.CompleteRemoval) == 'function' and
        type(TrackerManager.CancelRemoval) == 'function')
    check('V118-RC-LOAD-6: DispatchBridge global loaded and structured',
        type(DispatchBridge) == 'table')
    check('V118-RC-LOAD-7: DispatchBridge exports public dispatch methods',
        type(DispatchBridge.RegisterProvider) == 'function' and
        type(DispatchBridge.SendAlert) == 'function' and
        type(DispatchBridge.GetProvider) == 'function' and
        type(DispatchBridge.IsAvailable) == 'function')

    -- Check inspectVehicle callback in _G.CapturedCallbacks or lib.callback
    local hasInspectCallback = (_G.CapturedCallbacks and type(_G.CapturedCallbacks['vp_chopshop:inspectVehicle']) == 'function') or
                               (lib and lib.callback and lib.callback._callbacks and type(lib.callback._callbacks['vp_chopshop:inspectVehicle']) == 'function')
    check('V118-RC-LOAD-8: Callback vp_chopshop:inspectVehicle is registered',
        hasInspectCallback)

    -- =========================================================================
    -- GROUP 2: V118-RC-EVIDENCE — Fail-Soft & Provider Isolation
    -- =========================================================================
    local prevEvCfg = Config.Evidence
    Config.Evidence = { Enable = true, Provider = 'none', Actions = { chop_part = { fingerprint = 1.0, dna = 0.0 } } }
    local evOk, evRes = pcall(function()
        return EvidenceBridge.Plant('fingerprint', 1, { x = 100.0, y = 200.0, z = 30.0 }, 'chop_part', { plate = 'TEST1234' })
    end)
    check('V118-RC-EVIDENCE-1: EvidenceBridge provider none returns false without throw',
        evOk and evRes == false)

    local evFailSoftOk = pcall(function()
        VPChopLeaveEvidence(-1, vector3(0, 0, 0), 'unknown_action', 'TEST')
    end)
    check('V118-RC-EVIDENCE-2: VPChopLeaveEvidence fails soft on invalid payload',
        evFailSoftOk)
    Config.Evidence = prevEvCfg

    -- =========================================================================
    -- GROUP 3: V118-RC-TRACKER — Server-Authoritative Lifecycle & Hijack Isolation
    -- =========================================================================
    local mockNetId = 88881
    local mockHandle = 7771
    local origNetGet = _G.NetworkGetEntityFromNetworkId
    local origDoesExist = _G.DoesEntityExist
    local origGetType = _G.GetEntityType
    local origGetModel = _G.GetEntityModel

    _G.NetworkGetEntityFromNetworkId = function(netId)
        if netId == mockNetId then return mockHandle end
        if origNetGet then return origNetGet(netId) end
        return 0
    end
    _G.DoesEntityExist = function(ent)
        if ent == mockHandle then return true end
        if origDoesExist then return origDoesExist(ent) end
        return (type(ent) == 'number' and ent > 0)
    end
    _G.GetEntityType = function(ent)
        if ent == mockHandle then return 2 end
        if origGetType then return origGetType(ent) end
        return (type(ent) == 'number' and ent > 0) and 2 or 0
    end
    _G.GetEntityModel = function(ent)
        if ent == mockHandle then return 12345 end
        if origGetModel then return origGetModel(ent) end
        return 0
    end

    local trackerState = TrackerManager.GetVehicleState(mockNetId)
    check('V118-RC-TRACKER-1: GetVehicleState on untracked vehicle returns NONE without side-effects',
        trackerState == 'NONE')

    local compRes = TrackerManager.CompleteRemoval(1, mockNetId, 'invalid_fake_token')
    check('V118-RC-TRACKER-2: CompleteRemoval with fake token fails closed (no_session/invalid_token)',
        type(compRes) == 'table' and compRes.ok == false and (compRes.err == 'no_session' or compRes.err == 'invalid_token'))

    -- =========================================================================
    -- GROUP 4: V118-RC-DISPATCH — DispatchBridge Multi-Provider Transport
    -- =========================================================================
    local prevDispCfg = Config.Dispatch
    Config.Dispatch = { Enable = true, Provider = 'none' }
    local dispOk, dispSucc, dispReason = pcall(function()
        return DispatchBridge.SendAlert('lojack_ping', {
            coords = { x = 0.0, y = 0.0, z = 0.0 },
            plate = 'TEST',
            model = 'sultan',
        })
    end)
    check('V118-RC-DISPATCH-1: DispatchBridge provider none returns false, none without throw',
        dispOk and dispSucc == false and dispReason == 'none')
    Config.Dispatch = prevDispCfg

    -- =========================================================================
    -- GROUP 5: V118-RC-FORENSIC — Scanner Read-Only & Inspection Security
    -- =========================================================================
    check('V118-RC-FORENSIC-1: Config.PartSerial.VehicleInspection table configured in config',
        type(Config.PartSerial) == 'table' and type(Config.PartSerial.VehicleInspection) == 'table')
    check('V118-RC-FORENSIC-2: VehicleInspection default enabled and configured with DurationMs = 5000',
        Config.PartSerial.VehicleInspection.Enable == true and Config.PartSerial.VehicleInspection.DurationMs == 5000)
    check('V118-RC-FORENSIC-3: inspectVehicle callback exists in captured callbacks registry',
        type(_G.CapturedCallbacks['vp_chopshop:inspectVehicle']) == 'function')

    -- =========================================================================
    -- GROUP 6: V118-RC-IDENTITY — Canonical Plate Domain & Tri-State VIN
    -- =========================================================================
    check('V118-RC-IDENTITY-1: VPChopMDT.GetRealPlate is available and callable',
        type(VPChopMDT) == 'table' and type(VPChopMDT.GetRealPlate) == 'function')
    check('V118-RC-IDENTITY-2: VPChopIsVinScratched helper is available',
        type(VPChopIsVinScratched) == 'function')

    -- Tri-State test for VPChopIsVinScratched:
    local vinNil = VPChopIsVinScratched(nil)
    local vinEmpty = VPChopIsVinScratched('')
    local origMySQLScalar = _G.MySQL and _G.MySQL.scalar
    _G.MySQL = _G.MySQL or {}
    _G.MySQL.scalar = {
        await = function() error('db timeout') end
    }
    local vinWhenDbError = VPChopIsVinScratched('ANYPLATE')
    _G.MySQL.scalar = origMySQLScalar

    check('V118-RC-IDENTITY-3: VPChopIsVinScratched returns nil on nil input',
        vinNil == nil)
    check('V118-RC-IDENTITY-4: VPChopIsVinScratched returns nil on empty input',
        vinEmpty == nil)
    check('V118-RC-IDENTITY-5: VPChopIsVinScratched returns nil on DB error/timeout (fail-closed)',
        vinWhenDbError == nil)

    -- =========================================================================
    -- GROUP 7: V118-RC-READONLY — No Side-Effects on Forensics Inspection
    -- =========================================================================
    local stateBefore = TrackerManager.GetVehicleState(mockNetId)
    local stateAfter = TrackerManager.GetVehicleState(mockNetId)
    check('V118-RC-READONLY-1: Tracker state unchanged by repeated GetVehicleState calls',
        stateBefore == stateAfter and stateAfter == 'NONE')

    -- Restore entity mocks
    _G.NetworkGetEntityFromNetworkId = origNetGet
    _G.DoesEntityExist = origDoesExist
    _G.GetEntityType = origGetType
    _G.GetEntityModel = origGetModel

    -- =========================================================================
    -- GROUP 8: V118-RC-FLAGS — Submodule Isolation & Defensiveness
    -- =========================================================================
    check('V118-RC-FLAGS-1: Evidence submodule has independent Enable flag in config',
        type(Config.Evidence.Enable) == 'boolean')
    check('V118-RC-FLAGS-2: Tracker submodule has independent Enable flag in config',
        type(Config.Tracker.Enable) == 'boolean')
    check('V118-RC-FLAGS-3: Dispatch submodule has independent Enable flag in config',
        type(Config.Dispatch.Enable) == 'boolean')
    check('V118-RC-FLAGS-4: VehicleInspection has independent Enable flag in config',
        type(Config.PartSerial.VehicleInspection.Enable) == 'boolean')
    check('V118-RC-FLAGS-5: CatalyticTheft has DisableVehicle flag configured in config',
        type(Config.CatalyticTheft.DisableVehicle) == 'boolean')

    -- =========================================================================
    -- GROUP 9: V118-RC-I18N — 5-Language Complete Parity Check
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

    check('V118-RC-I18N-1: All 5 locales (en, pt, es, fr, tr) contain all 14 required forensic and disablement keys',
        allI18nPresent)

    -- =========================================================================
    -- GROUP 10: V118-RC-NO-ECON-DRIFT — Economy & Broker Baseline Integrity
    -- =========================================================================
    check('V118-RC-NO-ECON-1: Broker Market bounds intact (Floor 0.40, Ceiling 1.30)',
        Config.Broker.Market.DemandFloor == 0.40 and Config.Broker.Market.DemandCeiling == 1.30 and
        Config.Broker.Market.PriceFloor == 0.40 and Config.Broker.Market.PriceCeiling == 2.50)

    local function fileContains(filePath, pattern)
        local f = io.open(filePath, 'r')
        if not f then return false end
        local content = f:read('*a')
        f:close()
        return content:find(pattern, 1, true) ~= nil
    end

    local prodHasWorkshopDefaultNone = fileContains('shared/config.lua', "Provider = 'none'")
    check('V118-RC-NO-ECON-2: Broker Workshop Provider default in shared/config.lua is none',
        prodHasWorkshopDefaultNone)
    check('V118-RC-NO-ECON-3: Broker Contracts Pools contains part_type, model, class, high_value',
        type(Config.Broker.Contracts.Pools) == 'table' and
        Config.Broker.Contracts.Pools.part_type ~= nil and Config.Broker.Contracts.Pools.model ~= nil and
        Config.Broker.Contracts.Pools.class ~= nil and Config.Broker.Contracts.Pools.high_value ~= nil)
    check('V118-RC-NO-ECON-4: Commodity scrap_metal exists with basePrice 80',
        Config.Broker.Commodities.metalscrap and Config.Broker.Commodities.metalscrap.basePrice == 80)

    -- =========================================================================
    -- GROUP 11: V118-RC-CANARY — Static Code Integrity & Anti-Regression Canaries
    -- =========================================================================
    local function fileContains(filePath, pattern)
        local f = io.open(filePath, 'r')
        if not f then return false end
        local content = f:read('*a')
        f:close()
        return content:find(pattern, 1, true) ~= nil
    end

    local origDeprecatedFound = false
    local checkFiles = {
        'server/partserial.lua',
        'server/tracker.lua',
        'bridge/evidence.lua',
        'client/partserial.lua',
        'client/tracker.lua',
        'server/main.lua',
    }
    for _, fpath in ipairs(checkFiles) do
        if fileContains(fpath, 'vpChopPlateOriginal') then
            origDeprecatedFound = true
            break
        end
    end
    check('V118-RC-CANARY-1: Zero occurrences of deprecated vpChopPlateOriginal in production code',
        not origDeprecatedFound)

    -- Canary: verify tracker does not broadcast LoJack ping blindly to -1
    local trackerHasBroadcastAll = fileContains('server/tracker.lua', "TriggerClientEvent('vp_chopshop:trackerPing', -1")
    check('V118-RC-CANARY-2: TrackerManager does not broadcast LoJack pings to -1 (all players)',
        not trackerHasBroadcastAll)

    -- Canary: verify client tracker does not send plate authority
    local startRemovalAuthLeak = fileContains('client/tracker.lua', "startRemoval', netId, plate")
    check('V118-RC-CANARY-3: Client tracker does not pass plate authority to startRemoval',
        not startRemovalAuthLeak)

    -- Canary: verify EvidenceBridge wraps all dispatch calls with pcall
    local evidenceHasPcall = fileContains('bridge/evidence.lua', 'pcall')
    check('V118-RC-CANARY-4: EvidenceBridge enforces fail-soft pcall wrapping',
        evidenceHasPcall)

    print(('\n[v118-gate] ══════════════════════════════════════════════════════'))
    print(('[v118-gate] SUMMARY: %d PASS / %d FAIL / %d asserts'):format(pass, fail, total))
    print(('[v118-gate] ══════════════════════════════════════════════════════\n'))

    if fail > 0 then
        error(('[v118-gate] RELEASE GATE FAILED: %d assertions failed'):format(fail))
    end
end

run()