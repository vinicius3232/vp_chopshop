-- Harness standalone p/ rodar server/session/chop_session_spec.lua fora do FiveM.
-- Stub dos globals CFX que o módulo/spec tocam. O seam EntityAPI já isola OneSync.
local threads = {}
function CreateThread(fn) threads[#threads+1] = fn end
function Wait(_) end
function AddEventHandler() end
function GetPlayerName(src) return src and ('player_'..tostring(src)) or nil end
function GetConvarInt(_, _) return 1 end             -- ativa o self-test
function GetConvar(_, _) return '1' end              -- expõe ChopSession._test
local _t0 = os.clock()
function GetGameTimer() return math.floor((os.clock() - _t0) * 1000) end
function NetworkGetEntityFromNetworkId(_) return 0 end
function DoesEntityExist(_) return false end
function GetEntityModel(_) return 0 end
function GetVehicleNumberPlateText(_) return '' end
function GetVehicleClass(_) return 0 end
function Entity(_) return { state = {} } end
_G.Config = { Debug = false, ChopSession = { Enable = true, Debug = false } }

local base = arg[1] or '.'
dofile(base .. '/server/session/chop_session.lua')
dofile(base .. '/server/session/chop_session_spec.lua')

-- Só o último thread registado é o corpo do spec (o 1º é o sweeper do módulo,
-- que teria loop infinito com Wait no-op). O sweeper é server-only, fora deste teste.
local specBody = threads[#threads]
local ok, err = pcall(specBody)
if not ok then print('THREAD ERROR: ' .. tostring(err)); os.exit(1) end
