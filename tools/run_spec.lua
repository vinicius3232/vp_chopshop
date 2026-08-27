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
function NetworkGetEntityFromNetworkId(_) return 0 end
function DoesEntityExist(_) return false end
function GetEntityModel(_) return 0 end
function GetVehicleNumberPlateText(_) return '' end
function GetVehicleClass(_) return 0 end
function Entity(_) return { state = {} } end
_G.Config = { Debug = false, ChopSession = { Enable = true, Debug = false, EnforceRaised = true } }

local base = arg[1] or '.'
dofile(base .. '/server/session/chop_session.lua')   -- provê ChopSession (+ sweeper thread [1])
dofile(base .. '/server/session/adv_gate.lua')        -- provê VPChopAdvRequireRaisedSession
dofile(base .. '/server/session/chop_session_spec.lua')
dofile(base .. '/server/session/adv_gate_spec.lua')

-- threads[1] é o sweeper do módulo (loop infinito com Wait no-op) — pulado.
-- threads[2..N] são os corpos dos specs.
local anyFail = false
for i = 2, #threads do
    local ok, err = pcall(threads[i])
    if not ok then print('THREAD ERROR: ' .. tostring(err)); anyFail = true end
end
if anyFail then os.exit(1) end
