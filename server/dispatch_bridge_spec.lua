-- server/dispatch_bridge_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.3] Testes Unitários de DispatchBridge (Multi-Framework Police Alerts)
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
    local mockResourceStates = {}

    _G.GetResourceState = function(resName)
        return mockResourceStates[resName] or 'missing'
    end

    local function restoreEnv()
        Config.Dispatch = origDispatchConfig
        _G.GetResourceState = origGetResourceState
        DispatchBridge._test.reset()
    end

    -- ─── DISPATCH-REG: Validação de Registro de Custom Provider ───────────────
    do
        DispatchBridge._test.reset()
        local regOk1, regErr1 = DispatchBridge.RegisterProvider('', 'vp_chopshop', function() end)
        check('DISPATCH-REG-01 nome vazio rejeitado', regOk1 == false and regErr1 == 'invalid_name')

        local regOk2, regErr2 = DispatchBridge.RegisterProvider('custom', 'vp_chopshop', 'not_a_func')
        check('DISPATCH-REG-01 handler invalido rejeitado', regOk2 == false and regErr2 == 'invalid_handler')

        local regOk3, _ = DispatchBridge.RegisterProvider('custom', 'vp_chopshop', function() return true end)
        check('DISPATCH-REG-01 registro legitimo de custom provider tem sucesso', regOk3 == true)
    end

    -- ─── DISPATCH-PROV: Resolução de Provedores ───────────────────────────────
    do
        DispatchBridge._test.reset()
        mockResourceStates = {}

        -- 1. Explicit provider 'ps-dispatch' started
        mockResourceStates['ps-dispatch'] = 'started'
        Config.Dispatch = { Enable = true, Provider = 'ps-dispatch' }
        check('DISPATCH-PROV-01 explicit ps-dispatch started resolves ps-dispatch', DispatchBridge.GetProvider() == 'ps-dispatch')
        check('DISPATCH-PROV-01 IsAvailable retorna true', DispatchBridge.IsAvailable() == true)

        -- 2. Explicit provider missing -> none
        mockResourceStates['ps-dispatch'] = 'missing'
        check('DISPATCH-PROV-01 explicit missing provider returns none', DispatchBridge.GetProvider() == 'none')
        check('DISPATCH-PROV-01 IsAvailable retorna false quando missing', DispatchBridge.IsAvailable() == false)

        -- 3. Auto mode probe: primeiro na ordem (ps-dispatch missing, cd_dispatch started)
        mockResourceStates['ps-dispatch'] = 'missing'
        mockResourceStates['cd_dispatch'] = 'started'
        mockResourceStates['qs-dispatch'] = 'started'
        Config.Dispatch = { Enable = true, Provider = 'auto', AutoOrder = { 'ps-dispatch', 'cd_dispatch', 'qs-dispatch' } }
        check('DISPATCH-PROV-02 auto mode probes in order and selects cd_dispatch', DispatchBridge.GetProvider() == 'cd_dispatch')

        -- 4. Auto mode probe com custom provider registrado
        DispatchBridge.RegisterProvider('custom', 'vp_chopshop', function() return true end)
        Config.Dispatch = { Enable = true, Provider = 'auto', AutoOrder = { 'custom', 'cd_dispatch' } }
        check('DISPATCH-PROV-02 auto mode probes custom before cd_dispatch if ordered', DispatchBridge.GetProvider() == 'custom')

        -- 5. Provider = 'none' ou Enable = false
        Config.Dispatch = { Enable = false, Provider = 'auto' }
        check('DISPATCH-PROV-03 Enable=false returns none', DispatchBridge.GetProvider() == 'none')

        Config.Dispatch = { Enable = true, Provider = 'none' }
        check('DISPATCH-PROV-03 Provider=none returns none', DispatchBridge.GetProvider() == 'none')

        -- 6. Unknown provider fallback
        Config.Dispatch = { Enable = true, Provider = 'unsupported_resource_xyz' }
        check('DISPATCH-PROV-05 unknown provider returns none fail-soft', DispatchBridge.GetProvider() == 'none')

        -- 7. Legacy Config.Dispatch.System compatibility
        DispatchBridge._test.reset()
        mockResourceStates = { ['qs-dispatch'] = 'started' }
        Config.Dispatch = { Enable = true, System = 'qs-dispatch' }
        check('DISPATCH-LEGACY-01 legacy System=qs-dispatch is supported', DispatchBridge.GetProvider() == 'qs-dispatch')
    end

    -- ─── DISPATCH-ALERT: Envio e Sanitização de Alertas ────────────────────────
    do
        DispatchBridge._test.reset()
        local alertReceived = nil
        DispatchBridge._test.setProvider('custom', function(data)
            alertReceived = data
            return true
        end)

        Config.Dispatch = {
            Enable = true,
            Provider = 'custom',
            Jobs = { 'police', 'sheriff' },
            DefaultCode = '10-90',
            DefaultTitle = '10-90 - Desmanche Ilegal',
            DefaultMessage = 'Atividade suspeita de desmanche.',
            Blip = { sprite = 530, scale = 1.0, color = 1, flashes = false, text = '911', time = 5, radius = 0 },
        }

        local alertInput = {
            coords = { x = 120.0, y = 450.0, z = 30.0 },
            title = '10-90 - Furto de Catalisador',
            message = 'Corte de catalisador em andamento.',
            code = '10-90',
            type = 'catalytic',
            plate = 'TESTCAT1',
        }

        local sendOk, provUsed = DispatchBridge.SendAlert(alertInput)
        check('DISPATCH-ALERT-01 SendAlert successfully triggers custom provider', sendOk == true and provUsed == 'custom')
        check('DISPATCH-ALERT-01 payload contains correct title and message',
            alertReceived and alertReceived.title == '10-90 - Furto de Catalisador' and alertReceived.message == 'Corte de catalisador em andamento.')
        check('DISPATCH-ALERT-01 payload contains correct plate and code',
            alertReceived and alertReceived.plate == 'TESTCAT1' and alertReceived.code == '10-90')
        check('DISPATCH-ALERT-01 payload contains coords',
            alertReceived and alertReceived.coords and alertReceived.coords.x == 120.0)

        -- Teste de fallback de coordenadas: quando coords é nil e veh existe
        local sendOkVeh, _ = DispatchBridge.SendAlert({ veh = 70001, title = 'Alarm' })
        check('DISPATCH-ALERT-02 SendAlert executes without error for vehicle alert', sendOkVeh == true)

        -- Teste fail-soft: custom provider lança erro/exception
        DispatchBridge._test.setProvider('custom', function(_)
            error('unexpected crash inside custom dispatch provider')
        end)
        local sendOkError, _ = DispatchBridge.SendAlert({ title = 'Crash test' })
        check('DISPATCH-ALERT-03 exception inside provider caught fail-soft (returns false, no crash)', sendOkError == false)
    end

    restoreEnv()
    print(('[dispatch/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then
        error('dispatch_bridge_spec falhou com ' .. fail .. ' erros')
    end
end

CreateThread(run)
