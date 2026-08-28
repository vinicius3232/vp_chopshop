-- Harness standalone p/ rodar os self-tests de server/session/*_spec.lua fora do
-- FiveM.  Uso:  lua tools/run_spec.lua [caminho-do-resource]   (default ".")
-- Stub dos globals CFX que os módulos/specs tocam. O seam EntityAPI isola OneSync.
local threads = {}
function CreateThread(fn) threads[#threads+1] = fn end
function Wait(_) end
function AddEventHandler() end
function GetPlayerName(src) return src and ('player_'..tostring(src)) or nil end
function GetConvarInt(_, _) return 1 end             -- ativa os self-tests
function GetConvar(_, _) return '1' end              -- expõe ChopSession._test
local _t0 = os.clock()
function GetGameTimer() return math.floor((os.clock() - _t0) * 1000) end
function SetTimeout(_, _) end          -- [PR-D] retries de deleção não rodam no static test
-- Mundo falso p/ os specs que tocam natives CRUS (server/chop.lua não usa o seam
-- EntityAPI). base_state_spec aponta o EntityAPI da ChopSession p/ a MESMA tabela.
_G.FAKE_VEH = {}
function NetworkGetEntityFromNetworkId(netId) return FAKE_VEH[netId] and (netId + 70000) or 0 end
function NetworkGetNetworkIdFromEntity(h) return h and (h - 70000) or 0 end
function DoesEntityExist(h)
    if h == nil or h == 0 then return false end
    local n = h - 70000
    -- handles no padrão +70000 seguem FAKE_VEH; outros (testes que passam um handle
    -- solto) mantêm o comportamento antigo (nonzero = existe).
    if FAKE_VEH[n] ~= nil then return true end
    return (h > 0 and h < 70000)
end
function GetEntityModel(h) local n = (h or 0) - 70000; return FAKE_VEH[n] and FAKE_VEH[n].model or 0 end
function GetVehicleNumberPlateText(_) return 'PLATE' end
function GetVehicleClass(_) return 0 end
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
_G.HAS_TOOL = true                                            -- serra (wantDrill=false)
_G.HAS_DRILL = true                                           -- chave de fenda (wantDrill=true)
function VPChopHasTool(_, wantDrill)
    if wantDrill == true then return _G.HAS_DRILL ~= false end
    return _G.HAS_TOOL ~= false
end
function VPChopConsumeTool(_, _) _G._TOOL_CONSUMED = (_G._TOOL_CONSUMED or 0) + 1; return true end
function ServerPlayerIsReady(src) return src ~= nil and GetPlayerName(src) ~= nil end
_G.lib = { callback = { register = function() end } }         -- action_session.lua registra callbacks
-- [PR-G] stubs p/ server/advanced_chop.lua (commit helpers + kind specs advanced)
_G.ServerWelders = {}
function GetPlayers() return {} end
function GetPlayerPed(_) return 0 end
function GetEntityCoords(_) return { x = 0, y = 0, z = 0 } end
function TriggerClientEvent(_, _, ...) end
function VPChopAddStolenCarParts(_, _, _) _G._ADV_REWARD = (_G._ADV_REWARD or 0) + 1; return true end
function InvAdd(_, _, _) _G._ADV_REWARD = (_G._ADV_REWARD or 0) + 1; return true end
function VPChopLeaveEvidence(_, _, _, _) end
function VPChopArmTyreWindow(_, _) end
function VPChopChopPartCommit(_, _, _) return { ok = true } end  -- overridden pelo spec de tyre

-- [PR-D] Stubs de resource/export p/ bridge/server_vehicle.lua (discard ownership).
_G.FAKE_RESOURCES = { qbx_core = 'started', qbx_vehicles = 'started' }
_G.FAKE_EXPORTS   = {}
function GetResourceState(r) return _G.FAKE_RESOURCES[r] or 'missing' end
_G.exports = setmetatable({}, { __index = function(_, res)
    return _G.FAKE_EXPORTS[res] or setmetatable({}, { __index = function() return function() end end })
end })
_G.VPChopMDT = { GetRealPlate = function(p) return p end }
_G.VPChopDBReady = true   -- [PR-D] default do harness: DB pronto (specs sobrescrevem p/ testar nil/false)
function SetEntityAsMissionEntity(_, _, _) end
function DeleteEntity(h) local n = (h or 0) - 70000; FAKE_VEH[n] = nil end
_G.VPChopEvt = setmetatable({}, { __index = function(_, k) return 'vpevt:' .. k end })
_G._TRIGGERED = {}
function TriggerEvent(evt, ...) _G._TRIGGERED[#_G._TRIGGERED + 1] = { evt = evt, args = { ... } } end
function LogSuspicious(_, _, _) end
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
    TyreSelling = { Enable = true, MaxTyresInTruck = 4 },   -- [PR-E]
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
    },
    CarPartRewards = {
        wheel_lf = { rubber = { amount = 2, chance = 1.0 } },
        wheel_rf = { rubber = { amount = 2, chance = 1.0 } },
        wheel_lr = { rubber = { amount = 2, chance = 1.0 } },
        wheel_rr = { rubber = { amount = 2, chance = 1.0 } },
        bonnet   = { steel  = { amount = 3, chance = 1.0 } },
        boot     = { steel  = { amount = 3, chance = 1.0 } },
    },
}
-- [P1.2] ChopParts/ChopPartOrder deixam de ser stub hardcoded — vêm da projeção
-- REAL do registry (shared/chop_parts.lua), carregada logo abaixo.

local base = arg[1] or '.'
dofile(base .. '/shared/registry/tools.lua')          -- [P1.1] VPChopToolRegistry
dofile(base .. '/shared/registry/parts.lua')          -- [P1.1] VPChopPartRegistry
dofile(base .. '/shared/chop_parts.lua')              -- [P1.2] ChopParts/Order = projeção do registry
dofile(base .. '/shared/action_gate.lua')             -- [PR-G] VPChopActionMode{Tyre,Advanced}
dofile(base .. '/server/session/chop_session.lua')   -- provê ChopSession (+ sweeper thread [1])
dofile(base .. '/server/session/adv_gate.lua')        -- provê VPChopAdvRequireRaisedSession
dofile(base .. '/server/session/base_state.lua')      -- provê VPChopBaseState
dofile(base .. '/server/session/advanced_state.lua')  -- provê VPChopAdvancedState
dofile(base .. '/server/session/discard_state.lua')   -- [PR-D] provê VPChopDiscardState
dofile(base .. '/bridge/server_vehicle.lua')          -- [PR-D] provê BridgeResolveVehiclePersistence / BridgeDeleteWorldVehicle
dofile(base .. '/server/logistics/tyre_entitlement.lua')  -- [PR-E] provê TyreEntitlement
dofile(base .. '/server/logistics/truck_storage.lua')     -- [PR-E] provê TruckStorage
dofile(base .. '/server/session/action_session.lua')     -- [PR-F] provê ActionSession
dofile(base .. '/server/session/deliver_car_util.lua')   -- [PR-H] provê VPChopDeliverCar (marker + retry)
dofile(base .. '/server/session/carcass_ledger.lua')     -- [P0.4] provê VPChopCarcassLedger (DB seam nil no harness)
dofile(base .. '/server/chop.lua')                    -- provê VPChopServerTryPart etc. (delega a base_state)
dofile(base .. '/server/advanced_chop.lua')           -- [PR-G] provê VPChopAdv{Door,Engine,Carcass}Commit + VPChopWelderNearVehicle
dofile(base .. '/server/action/base_tyre.lua')        -- [PR-F] registra kind/executor 'tyre' (spec sobrescreve o executor)
dofile(base .. '/server/action/advanced_chop.lua')    -- [PR-G] registra kinds/executores adv_*

-- Threads criados até aqui são os SWEEPERS dos módulos (loops infinitos com Wait
-- no-op) — nunca rodar. Só os corpos dos specs, registrados a partir daqui.
local specStart = #threads + 1

dofile(base .. '/server/session/chop_session_spec.lua')
dofile(base .. '/server/session/adv_gate_spec.lua')
dofile(base .. '/server/session/base_state_spec.lua')
dofile(base .. '/server/session/advanced_state_spec.lua')
dofile(base .. '/server/session/discard_state_spec.lua')  -- [PR-D]
dofile(base .. '/server/logistics/tyre_entitlement_spec.lua')  -- [PR-E]
dofile(base .. '/server/session/deliver_car_spec.lua')         -- [PR-H]
dofile(base .. '/server/session/carcass_ledger_spec.lua')      -- [P0.4]
dofile(base .. '/server/session/action_session_spec.lua')      -- [PR-F/G]
dofile(base .. '/shared/registry/registry_spec.lua')          -- [SPIKE PR-I]

local anyFail = false
for i = specStart, #threads do
    local ok, err = pcall(threads[i])
    if not ok then print('THREAD ERROR: ' .. tostring(err)); anyFail = true end
end
if anyFail then os.exit(1) end
