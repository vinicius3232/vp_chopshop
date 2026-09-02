-- server/dispatch_bridge_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.3 / P4.3.1] Testes Unitários e Comportamentais de DispatchBridge
--  Gated na convar vp_chopshop_selftest 1
-- ═══════════════════════════════════════════════════════════════════════════════

local function run()
    if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

    local pass = 0
    local fail = 0
    local total = 0

    local function check(label, condition)
        total = total + 1
        if condition then
            pass = pass + 1
            print(('[dispatch/spec] PASS  %s'):format(label))
        else
            fail = fail + 1
            print(('[dispatch/spec] FAIL  %s'):format(label))
        end
    end

    local origDispatchConfig = Config.Dispatch
    local origGetResourceState = _G.GetResourceState
    local origIsDuplicityVersion = _G.IsDuplicityVersion
    local origExports = _G.exports
    local origTriggerServerEvent = _G.TriggerServerEvent
    local origDoesEntityExist = _G.DoesEntityExist
    local origGetEntityCoords = _G.GetEntityCoords
    local origGetPlayerPed = _G.GetPlayerPed
    local origPlayerPedId = _G.PlayerPedId

    local mockResourceStates = {}
    local mockServerEvents = {}
    local mockExports = {}

    _G.GetResourceState = function(resName)
        return mockResourceStates[resName] or 'missing'
    end

    local function restoreEnv()
        Config.Dispatch = origDispatchConfig
        _G.GetResourceState = origGetResourceState
        _G.IsDuplicityVersion = origIsDuplicityVersion
        _G.exports = origExports
        _G.TriggerServerEvent = origTriggerServerEvent
        _G.DoesEntityExist = origDoesEntityExist
        _G.GetEntityCoords = origGetEntityCoords
        _G.GetPlayerPed = origGetPlayerPed
        _G.PlayerPedId = origPlayerPedId
        DispatchBridge._test.reset()
    end

    -- ─── 1. DISPATCH-CUSTOM-CTX: Client/Server VM Split & Registration ─────────
    do
        DispatchBridge._test.reset()

        -- DISPATCH-CUSTOM-CTX-01: Server context (IsDuplicityVersion == true) rejeita com wrong_context
        _G.IsDuplicityVersion = function() return true end
        local sOk, sErr = DispatchBridge.RegisterProvider('custom', 'vp_chopshop', function() return true end)
        check('DISPATCH-CUSTOM-CTX-01 server context rejects RegisterProvider with wrong_context', sOk == false and sErr == 'wrong_context')

        -- DISPATCH-CUSTOM-CTX-02: Client context (IsDuplicityVersion == false) aceita registro
        _G.IsDuplicityVersion = function() return false end
        local cOk, cErr = DispatchBridge.RegisterProvider('custom', 'vp_chopshop', function() return true end)
        check('DISPATCH-CUSTOM-CTX-02 client context accepts RegisterProvider', cOk == true and cErr == nil)

        -- DISPATCH-CUSTOM-CTX-03: Hijack por outro resource é impedido
        local hOk, hErr = DispatchBridge.RegisterProvider('custom', 'malicious_resource', function() return true end)
        check('DISPATCH-CUSTOM-CTX-03 provider hijack attempt rejected with already_registered', hOk == false and hErr == 'already_registered')

        -- DISPATCH-CUSTOM-CTX-04: Handler exception no custom provider é fail-soft
        DispatchBridge._test.reset()
        DispatchBridge.RegisterProvider('custom', 'vp_chopshop', function(_) error('custom crash') end)
        mockResourceStates['custom'] = 'started'
        Config.Dispatch = { Enable = true, Provider = 'custom' }
        local fOk, _ = DispatchBridge.SendAlert({ title = 'Test' })
        check('DISPATCH-CUSTOM-CTX-04 custom handler exception returns false without crashing', fOk == false)
    end

    -- ─── 2. DISPATCH-COORD: Hierarquia de Coordenadas ─────────────────────────
    do
        DispatchBridge._test.reset()
        local capturedCoords = nil
        DispatchBridge._test.setProvider('custom', function(data)
            capturedCoords = data.coords
            return true
        end)
        Config.Dispatch = { Enable = true, Provider = 'custom' }

        -- Mock de veículo na posição (100, 200, 30)
        _G.DoesEntityExist = function(ent) return ent == 70001 or ent == 100 end
        _G.GetEntityCoords = function(ent)
            if ent == 70001 then return { x = 100.0, y = 200.0, z = 30.0 } end
            if ent == 100 then return { x = 50.0, y = 50.0, z = 5.0 } end
            return { x = 0.0, y = 0.0, z = 0.0 }
        end
        _G.PlayerPedId = function() return 100 end

        -- DISPATCH-COORD-01: Veículo válido tem prioridade sobre coords manuais
        DispatchBridge.SendAlert({ veh = 70001, coords = { x = 999.0, y = 999.0, z = 999.0 } })
        check('DISPATCH-COORD-01 vehicle coords take precedence over manual coords',
            capturedCoords and capturedCoords.x == 100.0 and capturedCoords.y == 200.0)

        -- DISPATCH-COORD-02: Coords manuais válidas usadas quando veh é nil
        DispatchBridge.SendAlert({ veh = nil, coords = { x = 555.0, y = 666.0, z = 77.0 } })
        check('DISPATCH-COORD-02 explicit coords used when veh is nil',
            capturedCoords and capturedCoords.x == 555.0 and capturedCoords.y == 666.0)

        -- DISPATCH-COORD-03: Player ped coords usadas quando veh e coords manuais são nil
        DispatchBridge.SendAlert({ veh = nil, coords = nil })
        check('DISPATCH-COORD-03 player ped coords used when veh and coords are nil',
            capturedCoords and capturedCoords.x == 50.0 and capturedCoords.y == 50.0)

        -- DISPATCH-COORD-04: Coordenadas corrompidas (NaN/Inf/string) caem no fallback seguro (0, 0, 0)
        _G.DoesEntityExist = function(_) return false end
        local nanVal = 0 / 0
        DispatchBridge.SendAlert({ veh = nil, coords = { x = nanVal, y = math.huge, z = 'invalid' } })
        check('DISPATCH-COORD-04 corrupted NaN/Inf coords fall back to zero vector safely',
            capturedCoords and capturedCoords.x == 0.0 and capturedCoords.y == 0.0 and capturedCoords.z == 0.0)
    end

    -- ─── 3. DISPATCH-TIME: Semântica de Duração de Blip (Minutos Canônicos) ───
    do
        check('DISPATCH-TIME-01 canonical 5.0 minutes resolved cleanly', DispatchBridge.ResolveBlipDuration(5) == 5.0)
        check('DISPATCH-TIME-02 string "10" converted to 10.0 minutes', DispatchBridge.ResolveBlipDuration('10') == 10.0)
        check('DISPATCH-TIME-03 zero or negative duration falls back to 5.0', DispatchBridge.ResolveBlipDuration(0) == 5.0 and DispatchBridge.ResolveBlipDuration(-1) == 5.0)
        check('DISPATCH-TIME-04 NaN/Inf duration falls back to 5.0', DispatchBridge.ResolveBlipDuration(0/0) == 5.0 and DispatchBridge.ResolveBlipDuration(math.huge) == 5.0)
        check('DISPATCH-TIME-05 duration clamped to max 60.0 minutes', DispatchBridge.ResolveBlipDuration(120) == 60.0)
    end

    -- ─── 4. DISPATCH-PS: Contrato Upstream ps-dispatch ────────────────────────
    do
        DispatchBridge._test.reset()
        mockResourceStates = { ['ps-dispatch'] = 'started' }
        Config.Dispatch = {
            Enable = true,
            Provider = 'ps-dispatch',
            Jobs = { 'police', 'sheriff' },
            DefaultCode = '10-90',
            DefaultTitle = '10-90 - Desmanche Ilegal',
            DefaultMessage = 'Desmanche em andamento.',
            Blip = { sprite = 530, scale = 1.0, color = 1, time = 5, radius = 25 },
        }

        local psCaptured = nil
        _G.exports = {
            ['ps-dispatch'] = {
                CustomAlert = function(self, payload)
                    psCaptured = payload
                    return true
                end,
            }
        }

        local okPs, provPs = DispatchBridge.SendAlert({
            coords = { x = 10.0, y = 20.0, z = 30.0 },
            title = 'Alerta Desmanche',
            message = 'Veiculo sendo cortado.',
            code = '10-90',
            type = 'catalytic',
            plate = 'PS123',
            model = 'sultan',
        })

        check('DISPATCH-PS-01 ps-dispatch SendAlert succeeds', okPs == true and provPs == 'ps-dispatch')
        check('DISPATCH-PS-01 dispatchCode is stable codeName (vp_chopshop_catalytic)', psCaptured and psCaptured.dispatchCode == 'vp_chopshop_catalytic')
        check('DISPATCH-PS-01 code is radio code (10-90)', psCaptured and psCaptured.code == '10-90')
        check('DISPATCH-PS-01 jobs and recipientList are correctly populated', psCaptured and psCaptured.jobs and psCaptured.jobs[1] == 'police' and psCaptured.recipientList[2] == 'sheriff')
        check('DISPATCH-PS-01 message is title and information is message', psCaptured and psCaptured.message == 'Alerta Desmanche' and psCaptured.information == 'Veiculo sendo cortado.')
        check('DISPATCH-PS-01 length is in canonical minutes (5)', psCaptured and psCaptured.length == 5)
        check('DISPATCH-PS-01 plate and model forwarded', psCaptured and psCaptured.plate == 'PS123' and psCaptured.model == 'sultan')

        -- DISPATCH-PS-02: Export exception é fail-soft
        _G.exports['ps-dispatch'].CustomAlert = function() error('ps-dispatch internal crash') end
        local okPsErr, _ = DispatchBridge.SendAlert({ title = 'Crash' })
        check('DISPATCH-PS-02 ps-dispatch exception returns false without crash', okPsErr == false)
    end

    -- ─── 5. DISPATCH-CD: Contrato Upstream cd_dispatch ────────────────────────
    do
        DispatchBridge._test.reset()
        mockResourceStates = { ['cd_dispatch'] = 'started' }
        Config.Dispatch = {
            Enable = true,
            Provider = 'cd_dispatch',
            Jobs = { 'police', 'sheriff', 'bcso' },
            Blip = { sprite = 530, scale = 1.0, color = 3, text = '911', time = 5, radius = 0 },
        }

        local cdCapturedEvent = nil
        local cdCapturedData = nil
        _G.TriggerServerEvent = function(eventName, data)
            cdCapturedEvent = eventName
            cdCapturedData = data
        end

        local okCd, provCd = DispatchBridge.SendAlert({
            coords = { x = 111.0, y = 222.0, z = 33.0 },
            title = 'CD Desmanche',
            message = 'Noticia de desmanche.',
        })

        check('DISPATCH-CD-01 cd_dispatch SendAlert succeeds', okCd == true and provCd == 'cd_dispatch')
        check('DISPATCH-CD-01 event is cd_dispatch:AddNotification', cdCapturedEvent == 'cd_dispatch:AddNotification')
        check('DISPATCH-CD-01 job_table is forwarded', cdCapturedData and cdCapturedData.job_table and cdCapturedData.job_table[1] == 'police')
        check('DISPATCH-CD-01 blip contains colour and time in minutes',
            cdCapturedData and cdCapturedData.blip and cdCapturedData.blip.colour == 3 and cdCapturedData.blip.time == 5)
    end

    -- ─── 6. DISPATCH-QS: Contrato Upstream qs-dispatch ────────────────────────
    do
        DispatchBridge._test.reset()
        mockResourceStates = { ['qs-dispatch'] = 'started' }
        Config.Dispatch = {
            Enable = true,
            Provider = 'qs-dispatch',
            Jobs = { 'police' },
            Blip = { sprite = 530, scale = 1.0, color = 1, time = 5 },
        }

        local qsCapturedEvent = nil
        local qsCapturedData = nil
        _G.TriggerServerEvent = function(eventName, data)
            qsCapturedEvent = eventName
            qsCapturedData = data
        end

        local okQs, provQs = DispatchBridge.SendAlert({
            coords = { x = 300.0, y = 400.0, z = 50.0 },
            title = 'QS Desmanche',
            message = 'Alerta QS.',
            code = '10-90',
        })

        check('DISPATCH-QS-01 qs-dispatch SendAlert succeeds', okQs == true and provQs == 'qs-dispatch')
        check('DISPATCH-QS-01 event is qs-dispatch:server:CreateDispatchCall', qsCapturedEvent == 'qs-dispatch:server:CreateDispatchCall')
        check('DISPATCH-QS-01 callLocation and callCode snippet populated',
            qsCapturedData and qsCapturedData.callLocation and qsCapturedData.callCode and qsCapturedData.callCode.code == '10-90')
        check('DISPATCH-QS-01 blip.time is converted to milliseconds (300000 ms)',
            qsCapturedData and qsCapturedData.blip and qsCapturedData.blip.time == 300000)
    end

    -- ─── 7. DISPATCH-OP: Contrato Upstream op-dispatch ────────────────────────
    do
        DispatchBridge._test.reset()
        mockResourceStates = { ['op-dispatch'] = 'started' }
        Config.Dispatch = {
            Enable = true,
            Provider = 'op-dispatch',
            Jobs = { 'police', 'sheriff' },
        }

        local opEvents = {}
        _G.TriggerServerEvent = function(eventName, job, title, text, coords, panic, id)
            table.insert(opEvents, {
                eventName = eventName,
                job = job,
                title = title,
                text = text,
                coords = coords,
                panic = panic,
                id = id,
            })
        end

        local okOp, provOp = DispatchBridge.SendAlert({
            coords = { x = 12.0, y = 34.0, z = 56.0 },
            title = 'OP Desmanche',
            message = 'Alerta OP.',
        })

        check('DISPATCH-OP-01 op-dispatch SendAlert succeeds', okOp == true and provOp == 'op-dispatch')
        check('DISPATCH-OP-01 triggers Opto_dispatch:Server:SendAlert for each job (2 events)', #opEvents == 2)
        check('DISPATCH-OP-01 first event job is police', opEvents[1] and opEvents[1].job == 'police' and opEvents[1].eventName == 'Opto_dispatch:Server:SendAlert')
        check('DISPATCH-OP-01 second event job is sheriff', opEvents[2] and opEvents[2].job == 'sheriff')
        check('DISPATCH-OP-01 panic is false and coords forwarded', opEvents[1] and opEvents[1].panic == false and opEvents[1].coords.x == 12.0)
    end

    -- ─── 8. DISPATCH-CORE: Contrato Upstream core_dispatch (Client sendAlert) ─
    do
        DispatchBridge._test.reset()
        mockResourceStates = { ['core_dispatch'] = 'started' }
        Config.Dispatch = {
            Enable = true,
            Provider = 'core_dispatch',
            Jobs = { 'police' },
            Blip = { sprite = 530, color = 1, time = 5 },
        }

        local coreArgs = nil
        _G.exports = {
            ['core_dispatch'] = {
                sendAlert = function(self, code, title, pos, priority, jobs, extraInfo, timeMs, sprite, color)
                    coreArgs = {
                        code = code,
                        title = title,
                        pos = pos,
                        priority = priority,
                        jobs = jobs,
                        extraInfo = extraInfo,
                        timeMs = timeMs,
                        sprite = sprite,
                        color = color,
                    }
                    return true
                end,
            }
        }

        local okCore, provCore = DispatchBridge.SendAlert({
            coords = { x = 70.0, y = 80.0, z = 90.0 },
            title = 'Core Desmanche',
            message = 'Alerta Core.',
            code = '10-90',
        })

        check('DISPATCH-CORE-01 core_dispatch SendAlert succeeds using sendAlert export', okCore == true and provCore == 'core_dispatch')
        check('DISPATCH-CORE-01 sendAlert received code 10-90 and title Core Desmanche', coreArgs and coreArgs.code == '10-90' and coreArgs.title == 'Core Desmanche')
        check('DISPATCH-CORE-01 sendAlert duration is in milliseconds (300000 ms)', coreArgs and coreArgs.timeMs == 300000)
    end

    -- ─── 9. DISPATCH-NONE & AUTO Order ────────────────────────────────────────
    do
        DispatchBridge._test.reset()
        mockResourceStates = { ['ps-dispatch'] = 'started', ['cd_dispatch'] = 'started' }
        Config.Dispatch = { Enable = true, Provider = 'none' }
        local okNone, provNone = DispatchBridge.SendAlert({ title = 'None Test' })
        check('DISPATCH-NONE-01 Provider=none produces zero alerts (returns false, none)', okNone == false and provNone == 'none')

        Config.Dispatch = { Enable = true, Provider = 'auto', AutoOrder = { 'cd_dispatch', 'ps-dispatch' } }
        check('DISPATCH-AUTO-01 auto order prioritizes first started resource (cd_dispatch)', DispatchBridge.GetProvider() == 'cd_dispatch')
    end

    -- ─── 10. DISPATCH-CANARY: Canaries Arquiteturais e de Sintaxe ─────────────
    do
        local f = io.open('bridge/dispatch.lua', 'r')
        local content = f and f:read('*all') or ''
        if f then f:close() end

        check('DISPATCH-CANARY-01 bridge/dispatch.lua ZERO exports[op-dispatch]:SendAlert', not content:find("exports%['op%-dispatch'%]:SendAlert", 1, false))
        check('DISPATCH-CANARY-02 bridge/dispatch.lua ZERO core_dispatch:addCall', not content:find("core_dispatch.*addCall", 1, false))
        check('DISPATCH-CANARY-03 bridge/dispatch.lua contains Opto_dispatch:Server:SendAlert', content:find("Opto_dispatch:Server:SendAlert", 1, true) ~= nil)
        check('DISPATCH-CANARY-04 bridge/dispatch.lua contains CustomAlert with code and jobs', content:find("dispatchCode = codeName", 1, true) ~= nil and content:find("code = code", 1, true) ~= nil)
    end

    restoreEnv()
    print(('[dispatch/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then
        error('dispatch_bridge_spec falhou com ' .. fail .. ' erros')
    end
end

CreateThread(run)
