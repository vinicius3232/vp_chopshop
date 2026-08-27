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
-- Mundo falso p/ os specs que tocam natives CRUS (server/chop.lua não usa o seam
-- EntityAPI). base_state_spec aponta o EntityAPI da ChopSession p/ a MESMA tabela.
_G.FAKE_VEH = {}
function NetworkGetEntityFromNetworkId(netId) return FAKE_VEH[netId] and (netId + 70000) or 0 end
function NetworkGetNetworkIdFromEntity(h) return h and (h - 70000) or 0 end
function DoesEntityExist(h) return h ~= nil and h ~= 0 end
function GetEntityModel(h) local n = (h or 0) - 70000; return FAKE_VEH[n] and FAKE_VEH[n].model or 0 end
function GetVehicleNumberPlateText(_) return 'PLATE' end
function GetVehicleClass(_) return 0 end
function Entity(_) return { state = { set = function() end } } end
function ValidatePlayerNearVehicle(_, _, _) return true end   -- base chop: proximidade OK
_G.Config = {
    Debug = false,
    VehicleNearLiftRadius = 5.0,
    ChopSession = {
        Enable = true, Debug = false, EnforceRaised = true,
        SessionTimeoutMs = 15 * 60 * 1000, OrphanWarnAfterMs = 60 * 60 * 1000,
        SweepIntervalMs = 30 * 1000,
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
_G.ChopParts = {
    wheel_lf = { kind = 'tyre' }, wheel_rf = { kind = 'tyre' },
    wheel_lr = { kind = 'tyre' }, wheel_rr = { kind = 'tyre' },
    bonnet = { kind = 'door' }, boot = { kind = 'door' },
}

local base = arg[1] or '.'
dofile(base .. '/server/session/chop_session.lua')   -- provê ChopSession (+ sweeper thread [1])
dofile(base .. '/server/session/adv_gate.lua')        -- provê VPChopAdvRequireRaisedSession
dofile(base .. '/server/session/base_state.lua')      -- provê VPChopBaseState
dofile(base .. '/server/chop.lua')                    -- provê VPChopServerTryPart etc. (delega a base_state)
dofile(base .. '/server/session/chop_session_spec.lua')
dofile(base .. '/server/session/adv_gate_spec.lua')
dofile(base .. '/server/session/base_state_spec.lua')

-- threads[1] é o sweeper do módulo (loop infinito com Wait no-op) — pulado.
-- threads[2..N] são os corpos dos specs.
local anyFail = false
for i = 2, #threads do
    local ok, err = pcall(threads[i])
    if not ok then print('THREAD ERROR: ' .. tostring(err)); anyFail = true end
end
if anyFail then os.exit(1) end
