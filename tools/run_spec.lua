-- Harness standalone p/ rodar os self-tests de server/session/*_spec.lua fora do
-- FiveM.  Uso:  lua tools/run_spec.lua [caminho-do-resource]   (default ".")
-- Stub dos globals CFX que os módulos/specs tocam. O seam EntityAPI isola OneSync.
--
-- EXIT CODE: os specs antigos só IMPRIMEM "FAIL" (não levantam erro), então uma
-- falha passava despercebida no exit code (== 0). O interceptor de `print` abaixo
-- observa as linhas de status "] PASS  " / "] FAIL  " emitidas por TODOS os specs
-- e força `os.exit(1)` se qualquer uma falhar — sem depender de cada spec chamar
-- error(). O critério de sucesso do CI é o exit code, nunca um número fixo.
local _print = print
local SPEC = { pass = 0, fail = 0 }
function print(...)
    local strArgs = {}
    local n = select('#', ...)
    for i = 1, n do
        strArgs[i] = tostring(select(i, ...))
    end
    local line = table.concat(strArgs, '\t')
    if line:find('%] PASS  ') then SPEC.pass = SPEC.pass + 1
    elseif line:find('%] FAIL  ') then SPEC.fail = SPEC.fail + 1 end
    return _print(...)
end

local threads = {}
function CreateThread(fn) threads[#threads+1] = fn end
function Wait(_) end
local _eventHandlers = {}
_G.AddEventHandler = function(name, fn)
    if not _eventHandlers[name] then _eventHandlers[name] = {} end
    table.insert(_eventHandlers[name], fn)
end
AddEventHandler = _G.AddEventHandler

_G.TriggerEvent = function(name, ...)
    if _eventHandlers[name] then
        for _, fn in ipairs(_eventHandlers[name]) do
            fn(...)
        end
    end
end
TriggerEvent = _G.TriggerEvent
function GetPlayerName(src) return src and ('player_'..tostring(src)) or nil end
function GetNumPlayerIdentifiers(src) return 1 end
function GetPlayerIdentifier(src, i) return 'license:test_' .. tostring(src) end
function GetHashKey(str)
    if not str then return 0 end
    if type(str) == 'number' then return str end
    local hash = 0
    for i = 1, #str do
        hash = (hash * 31 + string.byte(str, i)) % 2147483647
    end
    return hash
end
function GetConvarInt(_, _) return 1 end             -- ativa os self-tests
function GetConvar(_, _) return '1' end              -- expõe ChopSession._test
local _t0 = os.clock()
_G._CUSTOM_TIMER = nil
function GetGameTimer()
    if _G._CUSTOM_TIMER then return _G._CUSTOM_TIMER end
    return math.floor((os.clock() - _t0) * 1000)
end
if not _G.json then
    _G.json = {
        encode = function(v)
            if type(v) == 'table' then
                local parts = {}
                for k, val in pairs(v) do
                    local valStr
                    if type(val) == 'table' then
                        valStr = _G.json.encode(val)
                    elseif type(val) == 'string' then
                        valStr = '"' .. val .. '"'
                    else
                        valStr = tostring(val)
                    end
                    parts[#parts + 1] = ('"%s":%s'):format(tostring(k), valStr)
                end
                return '{' .. table.concat(parts, ',') .. '}'
            end
            return tostring(v)
        end,
        decode = function(s)
            if type(s) == 'table' then return s end
            if type(s) ~= 'string' or s == '' then return {} end
            local pos = 1
            local len = #s

            local function skipWhitespace()
                while pos <= len do
                    local c = s:sub(pos, pos)
                    if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
                        pos = pos + 1
                    else
                        break
                    end
                end
            end

            local parseValue

            local function parseString()
                pos = pos + 1
                local start = pos
                while pos <= len do
                    local c = s:sub(pos, pos)
                    if c == '\\' then
                        pos = pos + 2
                    elseif c == '"' then
                        local str = s:sub(start, pos - 1)
                        pos = pos + 1
                        return str
                    else
                        pos = pos + 1
                    end
                end
                return s:sub(start)
            end

            local function parseNumber()
                local start = pos
                while pos <= len do
                    local c = s:sub(pos, pos)
                    if c:find('[%d%.%-%+eE]') then
                        pos = pos + 1
                    else
                        break
                    end
                end
                return tonumber(s:sub(start, pos - 1)) or 0
            end

            local function parseObject()
                pos = pos + 1
                local obj = {}
                skipWhitespace()
                if pos <= len and s:sub(pos, pos) == '}' then
                    pos = pos + 1
                    return obj
                end
                while pos <= len do
                    skipWhitespace()
                    if s:sub(pos, pos) ~= '"' then break end
                    local key = parseString()
                    skipWhitespace()
                    if s:sub(pos, pos) == ':' then pos = pos + 1 end
                    skipWhitespace()
                    local val = parseValue()
                    obj[key] = val
                    skipWhitespace()
                    local c = s:sub(pos, pos)
                    if c == ',' then
                        pos = pos + 1
                    elseif c == '}' then
                        pos = pos + 1
                        break
                    else
                        break
                    end
                end
                return obj
            end

            local function parseArray()
                pos = pos + 1
                local arr = {}
                skipWhitespace()
                if pos <= len and s:sub(pos, pos) == ']' then
                    pos = pos + 1
                    return arr
                end
                while pos <= len do
                    skipWhitespace()
                    local val = parseValue()
                    table.insert(arr, val)
                    skipWhitespace()
                    local c = s:sub(pos, pos)
                    if c == ',' then
                        pos = pos + 1
                    elseif c == ']' then
                        pos = pos + 1
                        break
                    else
                        break
                    end
                end
                return arr
            end

            parseValue = function()
                skipWhitespace()
                if pos > len then return nil end
                local c = s:sub(pos, pos)
                if c == '"' then
                    return parseString()
                elseif c == '{' then
                    return parseObject()
                elseif c == '[' then
                    return parseArray()
                elseif c == 't' and s:sub(pos, pos + 3) == 'true' then
                    pos = pos + 4
                    return true
                elseif c == 'f' and s:sub(pos, pos + 4) == 'false' then
                    pos = pos + 5
                    return false
                elseif c == 'n' and s:sub(pos, pos + 3) == 'null' then
                    pos = pos + 4
                    return nil
                else
                    return parseNumber()
                end
            end

            local ok, res = pcall(parseValue)
            if ok and type(res) == 'table' then return res end
            return {}
        end,
    }
end
function SetTimeout(_, _) end          -- [PR-D] retries de deleção não rodam no static test
-- Mundo falso p/ os specs que tocam natives CRUS (server/chop.lua não usa o seam
_G.FAKE_VEH = {}
_G.FAKE_TRUCK = {}
function NetworkGetEntityFromNetworkId(netId)
    if not netId or netId == 0 then return 0 end
    if _G.FAKE_TRUCK and _G.FAKE_TRUCK[netId] then return netId + 90000 end
    return FAKE_VEH[netId] and (netId + 70000) or 0
end
function NetworkGetNetworkIdFromEntity(h)
    if not h or h == 0 then return 0 end
    if h >= 90000 then return h - 90000 end
    return h - 70000
end
function DoesEntityExist(h)
    if h == nil or h == 0 then return false end
    if h >= 90000 then
        local n = h - 90000
        return _G.FAKE_TRUCK and _G.FAKE_TRUCK[n] ~= nil
    end
    local n = h - 70000
    -- handles no padrão +70000 seguem FAKE_VEH; outros (testes que passam um handle
    -- solto) mantêm o comportamento antigo (nonzero = existe).
    if FAKE_VEH[n] ~= nil then return true end
    return (h > 0 and h < 70000)
end
function GetEntityModel(h)
    if not h or h == 0 then return 0 end
    if h >= 90000 then
        local n = h - 90000
        return _G.FAKE_TRUCK and _G.FAKE_TRUCK[n] and _G.FAKE_TRUCK[n].model or 0
    end
    local n = (h or 0) - 70000
    return FAKE_VEH[n] and FAKE_VEH[n].model or 0
end
function GetVehicleNumberPlateText(_) return 'PLATE' end
function GetVehicleClass(h)
    if h == nil or h == 0 then return 0 end
    local n = (h or 0) - 70000
    if FAKE_VEH[n] and FAKE_VEH[n].vehicleClass ~= nil then
        return FAKE_VEH[n].vehicleClass
    end
    return 0
end
function GetVehicleClassFromName(model)
    return 0
end
function Entity(h)
    local n = (h or 0) - 70000
    local v = FAKE_VEH[n] or {}
    return { state = setmetatable(
        { set = function(_, k, val) v[k] = val end },
        { __index = function(_, k) return v[k] end }) }
end
_G.NEAR = true                                                -- specs alternam p/ testar 'distance'
function ValidatePlayerNearVehicle(_, _, _) return _G.NEAR ~= false end
function ValidatePlayerNearPoint(_, _, _) return _G.NEAR ~= false end
function ValidatePlayerNearCoords(_, _, _) return _G.NEAR ~= false end
_G.HAS_TOOL = true                                            -- serra (wantDrill=false)
_G.HAS_DRILL = true                                           -- chave de fenda (wantDrill=true)
function VPChopHasTool(_, wantDrill)
    if wantDrill == true then return _G.HAS_DRILL ~= false end
    return _G.HAS_TOOL ~= false
end
function VPChopConsumeTool(_, _) _G._TOOL_CONSUMED = (_G._TOOL_CONSUMED or 0) + 1; return true end
function ServerPlayerIsReady(src) return src ~= nil and GetPlayerName(src) ~= nil end
function ServerChopPlayerKey(src) return 'qbx:player_' .. tostring(src or 1) end
_G.CapturedCallbacks = {}
_G.lib = {
    callback = {
        register = function(name, fn) _G.CapturedCallbacks[name] = fn end,
        await = function(name, ...)
            if _G.CapturedCallbacks[name] then return _G.CapturedCallbacks[name](...) end
        end,
    }
}
_G.GetClockHours = function() return 12 end
_G.VPChopGetProgression = function(src) return { tier = 4, xp = 1000 } end
_G.VPChopHeatGetLabel = function(plate) return 'frio' end
_G.MySQL = _G.MySQL or {
    single = { await = function(q, p) return nil end },
    query = { await = function(q, p) return { affectedRows = 1 } end },
    insert = { await = function(q, p) return 1 end },
    update = { await = function(q, p) return 1 end },
}
-- [PR-G] stubs p/ server/advanced_chop.lua (commit helpers + kind specs advanced)
_G.ServerWelders = {}
function GetPlayers() return {} end
function GetPlayerPed(_) return 0 end
function GetEntityCoords(_) return { x = 0, y = 0, z = 0 } end
function TriggerClientEvent(_, _, ...) end
function VPChopAddStolenCarParts(_, _, _) _G._ADV_REWARD = (_G._ADV_REWARD or 0) + 1; return true end
function InvAdd(_, _, _) _G._ADV_REWARD = (_G._ADV_REWARD or 0) + 1; return true end
function InvRemove(_, _, _) return true end
function InvCount(_, _) return 1 end
function VPChopLeaveEvidence(_, _, _, _) end
function VPChopArmTyreWindow(_, _) end
function VPChopChopPartCommit(_, _, _) return { ok = true } end  -- overridden pelo spec de tyre

-- [PR-D] Stubs de resource/export p/ bridge/server_vehicle.lua (discard ownership).
_G.FAKE_RESOURCES = { qbx_core = 'started', qbx_vehicles = 'started' }
_G.FAKE_EXPORTS   = {
    qbx_core = {
        GetPlayer = function(self, src)
            if not src or src <= 0 then return nil end
            return { citizenid = 'player_' .. tostring(src) }
        end,
    }
}
function GetResourceState(r) return _G.FAKE_RESOURCES[r] or 'missing' end
_G.exports = setmetatable({}, {
    __index = function(_, res)
        return _G.FAKE_EXPORTS[res] or setmetatable({}, { __index = function() return function() end end })
    end,
    __call = function(_, exportName, fn)
        _G.FAKE_EXPORTS[exportName] = fn
    end,
})
_G.VPChopMDT = { GetRealPlate = function(p) return p end }
_G.VPChopDBReady = true   -- [PR-D] default do harness: DB pronto (specs sobrescrevem p/ testar nil/false)
function SetEntityAsMissionEntity(_, _, _) end
function DeleteEntity(h) local n = (h or 0) - 70000; FAKE_VEH[n] = nil end
_G.VPChopEvt = setmetatable({}, { __index = function(_, k) return 'vpevt:' .. k end })
function LogSuspicious(_, _, _) end
_G._TRIGGERED = {}
function TriggerEvent(evt, ...)
    _G._TRIGGERED[#_G._TRIGGERED + 1] = { evt = evt, args = { ... } }
    if _eventHandlers and _eventHandlers[evt] then
        for _, fn in ipairs(_eventHandlers[evt]) do
            fn(...)
        end
    end
end
_G.TriggerEvent = TriggerEvent
_G.Config = {
    Debug = false,
    VehicleNearLiftRadius = 5.0,
    ChopSession = {
        Enable = true, Debug = false, EnforceRaised = true,
        SessionTimeoutMs = 15 * 60 * 1000, OrphanWarnAfterMs = 60 * 60 * 1000,
        SweepIntervalMs = 30 * 1000,
    },
    Discard = {
        Enable = true, MinPartsToDiscard = 4, DefaultPayout = 1500,
        OwnedPolicy = 'deny', PayoutByModel = {},
        CopsBonus = { Enable = false },
    },
    TyreSelling = { Enable = true, MaxTyresInTruck = 4, PickupTruckModels = { 'bison', 'sadler', 'bobcatxl' } },   -- [PR-E]
    ActionSession = {                                       -- [PR-F / PR-G]
        Enable = true, RequireBaseTyres = true, RequireAdvanced = true,
        ActionTtlMs = 45000,
        MinDurationMs = { tyre = 1500, door = 1500, engine = 2000, carcass = 2500 },
        StartRateLimitMs = 0, CompleteRateLimitMs = 0,
        SweepIntervalMs = 5000, RetentionMs = 120000, Debug = false,
    },
    AdvancedChop = {                                        -- [PR-G] default OFF (base_state_spec
        Enable = false, WelderRadius = 8.0,                 -- roda door via base chop); action_session_spec liga.
        DoorReward = { item = 'car_parts', amount = 1 },
        EngineReward = { item = 'car_parts', amount = 5 },
        CarcassRewards = { { item = 'car_parts', amount = 3, chance = 1.0 } },
        EngineAnim = {
            dict = 'mini@repair',
            clip = 'fixing_a_player',
            flag = 1,
            prop = {
                model    = 'prop_tool_drill',
                offset   = { 0.12, 0.04, -0.02 },
                rotation = { -80.0, 0.0, 0.0 },
            },
        },
    },
    Tools = {
        ['mechanic_drill'] = {
            MaxUses = 10,
            dispatchChance = 0.0,
            speedMult = 0.7,
            HandProp = {
                model    = 'prop_tool_drill',
                offset   = { 0.12, 0.04, -0.02 },
                rotation = { -80.0, 0.0, 0.0 },
            },
        },
    },
    CarPartRewards = {
        wheel_lf = { rubber = { amount = 2, chance = 1.0 } },
        wheel_rf = { rubber = { amount = 2, chance = 1.0 } },
        wheel_lr = { rubber = { amount = 2, chance = 1.0 } },
        wheel_rr = { rubber = { amount = 2, chance = 1.0 } },
        bonnet   = { steel  = { amount = 3, chance = 1.0 } },
        boot     = { steel  = { amount = 3, chance = 1.0 } },
    },
    PhysicalCarry = {
        Enable = true,
        Props = {
            door_dside_f = { model = 'prop_car_door_01',   offset = { 0.10, 0.18, 0.15 }, rotation = { 0.0, -20.0, 90.0 } },
            door_pside_f = { model = 'prop_car_door_01',   offset = { 0.10, 0.18, 0.15 }, rotation = { 0.0, -20.0, 90.0 } },
            door_dside_r = { model = 'prop_car_door_01',   offset = { 0.10, 0.18, 0.15 }, rotation = { 0.0, -20.0, 90.0 } },
            door_pside_r = { model = 'prop_car_door_01',   offset = { 0.10, 0.18, 0.15 }, rotation = { 0.0, -20.0, 90.0 } },
            bonnet       = { model = 'prop_car_bonnet_01', offset = { 0.12, 0.18, 0.10 }, rotation = { 0.0, 10.0, 0.0 } },
            adv_engine          = { model = 'prop_car_engine_01',  offset = { 0.10, 0.22, 0.12 }, rotation = { 0.0, 0.0, 180.0 } },
            catalytic_converter = { model = 'prop_car_exhaust_01', offset = { 0.10, 0.20, 0.12 }, rotation = { 0.0, 0.0, 90.0 } },
        },
        CarryAnim = { dict = 'anim@heists@box_carry@', clip = 'idle', flag = 49 },
    },
    Jackstand = {
        Enable = true,
        BlockOwnVehicle = false,
        Item = 'chopshop_jackstand',
    },
    CatalyticTheft = {
        Enable = true,
        BlockOwnVehicle = false,
        Bones = { 'exhaust', 'exhaust_2', 'chassis' },
        PoliceAlertChance = 40,
        ProgressMs = 7000,
        Payout = { min = 1200, max = 2200 },
        BenchMaterials = {
            copper     = { amount = 4, chance = 1.0 },
            metalscrap = { amount = 6, chance = 1.0 },
            steel      = { amount = 2, chance = 1.0 },
            car_parts  = { amount = 1, chance = 1.0 },
        },
    },
    Fence = {
        RotationMinutes = 45,
        Locations = {
            { coords = { x = 0, y = 0, z = 0, w = 0 }, scenario = 'WORLD_HUMAN_CLIPBOARD', label = 'TestLoc' },
        },
        BasePrices = {
            metalscrap = 80,
            copper = 150,
            steel = 100,
            rubber = 120,
            car_parts = 400,
            chopshop_tyre = 400,
            stolen_plate = 250,
        },
        XpPerDelivery = 20,
        XpOrderBonus = 80,
        TrustXpPerLevel = { [1] = 100, [2] = 300, [3] = 600, [4] = 1000 },
        WholeCarBasePayout = 8000,
        NightBonus = {
            Enable = true,
            StartHour = 21,
            EndHour = 6,
            Multiplier = 1.3,
        },
        OrderTemplates = {
            { items = { metalscrap = 20, copper = 8, rubber = 5 }, mult = 1.4, hours = 6 },
            { items = { car_parts = 5, steel = 15 }, mult = 1.5, hours = 8 },
            { items = { aluminum = 20, glass = 3 }, mult = 1.35, hours = 4 },
            { items = { copper = 12, plastic = 15, rubber = 8 }, mult = 1.45, hours = 5 },
        },
    },
    Progression = {
        FencePriceMult = { [1] = 1.0, [2] = 1.0, [3] = 1.0, [4] = 1.10 },
    },
    Broker = {
        Enable = true,
        Debug = false,
        Market = {
            DemandFloor = 0.40,
            DemandCeiling = 1.30,
            PriceFloor = 0.40,
            PriceCeiling = 2.50,
            Jitter = 0.03,
            FlushIntervalSec = 300,
        },
        Commodities = {
            catalytic_converter = {
                basePrice = 1600,
                salePressure = 0.04,
                recoveryPerHour = 0.15,
            },
            adv_engine = {
                basePrice = 2500,
                salePressure = 0.05,
                recoveryPerHour = 0.12,
            },
            tyre = {
                basePrice = 400,
                salePressure = 0.015,
                recoveryPerHour = 0.20,
            },
            stolen_plate = {
                basePrice = 250,
                salePressure = 0.03,
                recoveryPerHour = 0.15,
            },
            body_panel = {
                basePrice = 600,
                salePressure = 0.03,
                recoveryPerHour = 0.15,
            },
            metalscrap = {
                basePrice = 80,
                salePressure = 0.002,
                recoveryPerHour = 0.25,
            },
            steel = {
                basePrice = 100,
                salePressure = 0.003,
                recoveryPerHour = 0.25,
            },
            aluminum = {
                basePrice = 130,
                salePressure = 0.004,
                recoveryPerHour = 0.20,
            },
            copper = {
                basePrice = 150,
                salePressure = 0.005,
                recoveryPerHour = 0.20,
            },
            car_parts = {
                basePrice = 400,
                salePressure = 0.004,
                recoveryPerHour = 0.20,
            },
        },
        Integration = {
            ItemToCommodity = {
                metalscrap    = 'metalscrap',
                steel         = 'steel',
                aluminum      = 'aluminum',
                copper        = 'copper',
                car_parts     = 'car_parts',
                stolen_plate  = 'stolen_plate',
                chopshop_tyre = 'tyre',
            },
            PhysicalPartToCommodity = {
                catalytic_converter = 'catalytic_converter',
                adv_engine          = 'adv_engine',
                bonnet              = 'body_panel',
                boot                = 'body_panel',
                door_dside_f        = 'body_panel',
                door_pside_f        = 'body_panel',
                door_dside_r        = 'body_panel',
                door_pside_r        = 'body_panel',
            },
            LegacyStaticItems = {
                rubber  = true,
                plastic = true,
                glass   = true,
            },
        },
        Contracts = {
            Enable = true,
            MinTrust = 3,
            GlobalSlots = 3,
            PersonalSlots = 3,
            GlobalTTL = 7200,
            PersonalTTL = 3600,
            RewardMultMin = 1.05,
            RewardMultMax = 1.80,
            BonusCashMax = 15000,
            HighValueTargets = {
                adv_engine          = true,
                catalytic_converter = true,
            },
            VehicleClasses = {
                [0]  = 'compacts',
                [1]  = 'sedans',
                [2]  = 'suvs',
                [3]  = 'coupes',
                [4]  = 'muscle',
                [5]  = 'sports_classics',
                [6]  = 'sports',
                [7]  = 'super',
                [8]  = 'motorcycles',
                [9]  = 'offroad',
                [10] = 'industrial',
                [11] = 'utility',
                [12] = 'vans',
                [13] = 'cycles',
                [14] = 'boats',
                [15] = 'helicopters',
                [16] = 'planes',
                [17] = 'service',
                [18] = 'emergency',
                [19] = 'military',
                [20] = 'commercial',
                [21] = 'trains',
                [22] = 'open_wheel',
            },
            Pools = {
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
            },
        },
        Workshop = {
            Enable = true,
            Provider = 'none',
            ProviderResource = nil,
            MaxPrice = 50000,
            PrepareMaxTtlSec = 60,
            ReconcileIntervalSec = 15,
            MaxReconcileAttempts = 4,
            Debug = false,
        },
    },
}
-- [UX-A] Stubs de client/NUI/Câmera/Vector3 p/ testes do Interaction Core
if not _G.vector3 then
    local v3meta = {
        __add = function(a, b) return vector3(a.x + b.x, a.y + b.y, a.z + b.z) end,
        __sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end,
        __mul = function(a, b)
            if type(a) == 'number' then return vector3(a * b.x, a * b.y, a * b.z)
            elseif type(b) == 'number' then return vector3(a.x * b, a.y * b, a.z * b)
            else return vector3(a.x * b.x, a.y * b.y, a.z * b.z) end
        end,
        __div = function(a, b) return vector3(a.x / b, a.y / b, a.z / b) end,
        __unm = function(a) return vector3(-a.x, -a.y, -a.z) end,
        __len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end,
        __tostring = function(a) return ('vector3(%s, %s, %s)'):format(a.x, a.y, a.z) end,
    }
    function vector3(x, y, z)
        return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, v3meta)
    end
end
if not _G.vector4 then
    function vector4(x, y, z, w)
        return { x = x or 0, y = y or 0, z = z or 0, w = w or 0 }
    end
end
function RegisterNUICallback(_, _) end
function SendNUIMessage(_) end
function SetNuiFocus(_, _) end
function PlaySoundFrontend(_, _, _, _) end
function RequestAnimDict(_) end
function HasAnimDictLoaded(_) return true end
function TaskPlayAnim(_, _, _, _, _, _, _, _, _, _, _) end
function TaskTurnPedToFaceEntity(_, _, _) end
function ClearPedTasks(_) end
function GetHeadingFromVector_2d(dx, dy) return math.deg(math.atan(dy, dx)) end
function SetEntityCoordsNoOffset(_, _, _, _, _, _, _) end
function SetEntityHeading(_, _) end
function PlayerPedId() return 1 end
function IsPedDeadOrDying(_, _) return false end
function GetCurrentResourceName() return 'vp_chopshop' end
function GetModelDimensions(_) return vector3(-1.0, -2.5, -0.5), vector3(1.0, 2.5, 1.0) end
function GetOffsetFromEntityInWorldCoords(_, x, y, z) return vector3(x or 0, y or 0, z or 0) end
function GetEntityForwardVector(_) return vector3(0.0, 1.0, 0.0) end
function PlaceObjectOnGroundProperly(_) return true end
function L(key) return key end
function VPChopNotify(_, _) end
function IsControlJustPressed(_, _) return false end
function IsDisabledControlJustPressed(_, _) return false end
function IsControlPressed(_, _) return false end
function IsDisabledControlPressed(_, _) return false end
function DisableControlAction(_, _, _) end
function RegisterKeyMapping(_, _, _, _) end
function RegisterCommand(_, _, _) end
function IsPlayerAceAllowed(_, _) return false end

local base = arg[1] or '.'
_G.BASE_RESOURCE_PATH = base
_G._HARNESS_BASE = base
dofile(base .. '/shared/registry/tools.lua')          -- [P1.1] VPChopToolRegistry
dofile(base .. '/shared/registry/parts.lua')          -- [P1.1] VPChopPartRegistry
dofile(base .. '/shared/part_class.lua')              -- [P2.1] VPChopPartGtaClass
dofile(base .. '/shared/action_gate.lua')             -- [PR-G] VPChopActionMode{Tyre,Advanced}
dofile(base .. '/server/partserial.lua')              -- [SERIAL] provê VPChopSerialGen / VPChopAddStolenCarParts
dofile(base .. '/client/minigame/camera.lua')        -- [UX-A] CameraController
dofile(base .. '/client/minigame/projection.lua')    -- [UX-A] ProjectionHelper
dofile(base .. '/client/minigame/profiles/panels.lua')-- [UX-C] Panel Profiles
dofile(base .. '/client/minigame/profiles/engine.lua')-- [UX-D] Engine Profile
dofile(base .. '/client/minigame/profiles/carcass.lua')-- [UX-E] Carcass Profile
dofile(base .. '/client/minigame/profiles.lua')      -- [UX-A] Profiles Registry
dofile(base .. '/client/minigame/fallback.lua')      -- [UX-A] Minigame Fallback
dofile(base .. '/client/minigame/core.lua')          -- [UX-A] VPChopDismantleMinigame Core
dofile(base .. '/server/session/chop_session.lua')   -- provê ChopSession (+ sweeper thread [1])
dofile(base .. '/server/session/adv_gate.lua')        -- provê VPChopAdvRequireRaisedSession
dofile(base .. '/server/session/base_state.lua')      -- provê VPChopBaseState
dofile(base .. '/server/session/advanced_state.lua')  -- provê VPChopAdvancedState
dofile(base .. '/server/session/discard_state.lua')   -- [PR-D] provê VPChopDiscardState
dofile(base .. '/bridge/server_framework.lua')        -- provê BridgeAddCash / IsValidSource etc.
dofile(base .. '/bridge/server_vehicle.lua')          -- [PR-D] provê BridgeResolveVehiclePersistence / BridgeDeleteWorldVehicle
dofile(base .. '/server/logistics/tyre_entitlement.lua')  -- [PR-E] provê TyreEntitlement
dofile(base .. '/server/logistics/truck_storage.lua')     -- [PR-E] provê TruckStorage
dofile(base .. '/server/logistics/part_entitlement.lua')  -- [v1.16 SEC-1] provê PartEntitlement
dofile(base .. '/server/session/action_session.lua')     -- [PR-F] provê ActionSession
dofile(base .. '/server/session/deliver_car_util.lua')   -- [PR-H] provê VPChopDeliverCar (marker + retry)
dofile(base .. '/server/session/carcass_ledger.lua')     -- [P0.4] provê VPChopCarcassLedger (DB seam nil no harness)
dofile(base .. '/server/chop.lua')                    -- provê VPChopServerTryPart etc. (delega a base_state)
dofile(base .. '/server/advanced_chop.lua')           -- [PR-G] provê VPChopAdv{Door,Engine,Carcass}Commit + VPChopWelderNearVehicle
dofile(base .. '/server/action/base_tyre.lua')        -- [PR-F] registra kind/executor 'tyre' (spec sobrescreve o executor)
dofile(base .. '/server/action/advanced_chop.lua')    -- [PR-G] registra kinds/executores adv_*
dofile(base .. '/bridge/vp_gangs.lua')                -- [INT-01A] provê VPChopGangs* (ponte vp_chopshop→vp_gangs)
dofile(base .. '/bridge/evidence.lua')                -- [v1.18 FORENSICS V2] provê EvidenceBridge e VPChopLeaveEvidence
dofile(base .. '/server/broker/market.lua')              -- [v1.17 BROKER-1] provê BrokerMarket
dofile(base .. '/server/broker/contracts.lua')           -- [v1.17 BROKER-3] provê BrokerContracts
dofile(base .. '/bridge/workshop.lua')                   -- [v1.17 BROKER-4] provê WorkshopBridge
dofile(base .. '/server/tracker.lua')                  -- [v1.18 P4.2] provê TrackerManager
dofile(base .. '/server/fence.lua')                   -- provê callbacks do Fence (sellItems, fulfillOrder, etc.)

-- Threads criados até aqui são os SWEEPERS dos módulos (loops infinitos com Wait
-- no-op) — nunca rodar. Só os corpos dos specs, registrados a partir daqui.
local specStart = #threads + 1

dofile(base .. '/server/session/chop_session_spec.lua')
dofile(base .. '/server/session/adv_gate_spec.lua')
dofile(base .. '/server/session/base_state_spec.lua')
dofile(base .. '/server/session/advanced_state_spec.lua')
dofile(base .. '/server/session/discard_state_spec.lua')  -- [PR-D]
dofile(base .. '/server/logistics/tyre_entitlement_spec.lua')  -- [PR-E]
dofile(base .. '/server/logistics/part_entitlement_spec.lua')  -- [v1.16 SEC-1]
dofile(base .. '/server/session/deliver_car_spec.lua')         -- [PR-H]
dofile(base .. '/server/session/carcass_ledger_spec.lua')      -- [P0.4]
dofile(base .. '/server/session/action_session_spec.lua')      -- [PR-F/G]
dofile(base .. '/shared/registry/registry_spec.lua')          -- [SPIKE PR-I]
dofile(base .. '/bridge/vp_gangs_spec.lua')                   -- [INT-01A]
dofile(base .. '/server/partserial_spec.lua')                 -- [UX-0 QA findings]
dofile(base .. '/client/minigame/minigame_spec.lua')         -- [UX-A Interaction Core]
dofile(base .. '/server/session/fence_payment_spec.lua')     -- [v1.16-FENCE-PAY-1]
dofile(base .. '/server/broker/market_sim_spec.lua')         -- [v1.17 BROKER-1]
dofile(base .. '/server/broker/fence_integration_spec.lua')     -- [v1.17 BROKER-2]
dofile(base .. '/server/broker/contracts_spec.lua')         -- [v1.17 BROKER-3]
dofile(base .. '/server/broker/workshop_spec.lua')          -- [v1.17 BROKER-4]
dofile(base .. '/server/broker/npc_context_spec.lua')       -- [v1.17 BROKER-5]
dofile(base .. '/server/evidence_bridge_spec.lua')          -- [v1.18 FORENSICS V2]
dofile(base .. '/server/tracker_spec.lua')                  -- [v1.18 P4.2 GPS Tracker]

local anyFail = false
for i = specStart, #threads do
    local ok, err = pcall(threads[i])
    if not ok then _print('THREAD ERROR: ' .. tostring(err)); anyFail = true end
end

_print(('\n═══ TOTAL: %d PASS / %d FAIL / %d asserts ═══')
    :format(SPEC.pass, SPEC.fail, SPEC.pass + SPEC.fail))
-- Sanity gate: se o interceptor não contou NENHUM assert, o formato de saída dos
-- specs provavelmente mudou e o contador quebrou silenciosamente. CI verde com
-- 0 testes executados é inaceitável.
if (SPEC.pass + SPEC.fail) == 0 then
    _print('═══ RESULTADO: FALHA — 0 asserts contados (formato de output mudou?) (exit 1) ═══')
    os.exit(1)
end
if anyFail or SPEC.fail > 0 then
    _print('═══ RESULTADO: FALHA (exit 1) ═══')
    os.exit(1)
end
_print('═══ RESULTADO: OK (exit 0) ═══')
