-- server/forensic_scanner_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.4] Testes Unitários e Comportamentais de Perícia Forense e
--  Inutilização Veicular Anti-Farm (vp_chopshop:inspectVehicle / inspectParts)
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
            print(('[forensic/spec] PASS  %s'):format(label))
        else
            fail = fail + 1
            print(('[forensic/spec] FAIL  %s'):format(label))
        end
    end

    local origPartSerialCfg   = Config.PartSerial
    local origCatalyticCfg    = Config.CatalyticTheft
    local origBridgeIsPolice  = _G.BridgeIsPolice
    local origInvCount        = _G.InvCount
    local origVPChopIsVinScratched = _G.VPChopIsVinScratched

    local mockInventory = {}
    local mockPolice = {}
    local mockVinScratched = {}

    _G.BridgeIsPolice = function(src, _) return mockPolice[src] == true end
    _G.InvCount = function(src, item) return (mockInventory[src] and mockInventory[src][item]) or 0 end
    _G.VPChopIsVinScratched = function(plate) return mockVinScratched[plate] == true end

    local function restoreEnv()
        Config.PartSerial = origPartSerialCfg
        Config.CatalyticTheft = origCatalyticCfg
        _G.BridgeIsPolice = origBridgeIsPolice
        _G.InvCount = origInvCount
        _G.VPChopIsVinScratched = origVPChopIsVinScratched
        _G._CUSTOM_TIMER = nil
    end

    -- Recupera o handler do callback registrado no lib.callback
    local callbacks = _G.CapturedCallbacks or _G.LIB_CALLBACKS or {}
    local inspectVehCb = callbacks['vp_chopshop:inspectVehicle']
    local inspectPartsCb = callbacks['vp_chopshop:inspectParts']

    -- ─── 1. FORENSIC-AUTH: Gate Policial Server-Authoritative ──────────────────
    do
        _G._CUSTOM_TIMER = 1000
        mockPolice = { [1] = false, [2] = true }
        mockInventory = { [1] = { parts_scanner = 1 }, [2] = { parts_scanner = 1 } }
        _G.FAKE_VEH[101] = { model = 970598228, plate = 'POLTEST1', exists = true }

        -- Policial falso / civil tenta inspecionar veículo
        local resCivVeh = inspectVehCb(1, 101)
        check('FORENSIC-AUTH-01 civilian inspectVehicle rejected with not_police', resCivVeh.ok == false and resCivVeh.err == 'not_police')

        -- Policial falso tenta inspecionar peças
        local resCivParts = inspectPartsCb(1, 2)
        check('FORENSIC-AUTH-01 civilian inspectParts rejected with not_police', resCivParts.ok == false and resCivParts.err == 'not_police')

        -- Policial autêntico sem ferramenta de scan
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        mockInventory[2] = { parts_scanner = 0, forensic_kit = 0 }
        local resNoTool = inspectVehCb(2, 101)
        check('FORENSIC-TOOL-01 police without scanner or forensic kit rejected with no_tool', resNoTool.ok == false and resNoTool.err == 'no_tool')
    end

    -- ─── 2. FORENSIC-VEH: Perícia em Veículo (Chassi, Motor, Catalisador) ──────
    do
        mockPolice = { [2] = true }
        mockInventory = { [2] = { parts_scanner = 1 } }

        -- Cenário 1: Veículo 100% íntegro de fábrica
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[201] = { model = 970598228, plate = 'CLEAN01', exists = true }
        mockVinScratched['CLEAN01'] = false

        local resClean = inspectVehCb(2, 201)
        check('FORENSIC-VEH-01 clean vehicle inspection succeeds', resClean.ok == true)
        check('FORENSIC-VEH-01 clean vehicle engine is NOT missing', resClean.data and resClean.data.engineMissing == false)
        check('FORENSIC-VEH-01 clean vehicle catalytic is NOT stolen', resClean.data and resClean.data.catalyticStolen == false)
        check('FORENSIC-VEH-01 clean vehicle VIN is NOT scratched', resClean.data and resClean.data.vinScratched == false)
        check('FORENSIC-VEH-01 clean vehicle plate is NOT disguised', resClean.data and resClean.data.plateDisguised == false)

        -- Cenário 2: Veículo com motor arrancado no desmanche (vpChopEngineMissing)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[202] = { model = 970598228, plate = 'CHOP01', exists = true, vpChopEngineMissing = true }
        local resEngineMissing = inspectVehCb(2, 202)
        check('FORENSIC-VEH-02 engineMissing correctly detected', resEngineMissing.ok == true and resEngineMissing.data.engineMissing == true)

        -- Cenário 3: Veículo com catalisador furtado (catalyticStolen)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[203] = { model = 970598228, plate = 'NOCAT01', exists = true, catalyticStolen = true }
        local resCatStolen = inspectVehCb(2, 203)
        check('FORENSIC-VEH-03 catalyticStolen correctly detected', resCatStolen.ok == true and resCatStolen.data.catalyticStolen == true)

        -- Cenário 4: Veículo com VIN raspado e placa disfarçada
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[204] = { model = 970598228, plate = 'FAKE999', exists = true, vpChopPlateOriginal = 'ORIGINAL1' }
        mockVinScratched['FAKE999'] = true
        local resVinScratched = inspectVehCb(2, 204)
        check('FORENSIC-VEH-04 vinScratched correctly detected', resVinScratched.ok == true and resVinScratched.data.vinScratched == true)
        check('FORENSIC-VEH-04 plate disguise correctly exposed', resVinScratched.data and resVinScratched.data.plateDisguised == true and resVinScratched.data.plateOriginal == 'ORIGINAL1')

        -- Cenário 5: Rastreador GPS ativo detectado
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[205] = { model = 970598228, plate = 'TRK01', exists = true, vpChopTrackerId = 'TRK-999' }
        local resTrkActive = inspectVehCb(2, 205)
        check('FORENSIC-VEH-05 active tracker state detected', resTrkActive.ok == true and resTrkActive.data.trackerStatus == 'active')
    end

    -- ─── 3. FORENSIC-DISABLE: Inutilização Veicular & Anti-Farm ────────────────
    do
        local vehNet = 301
        _G.FAKE_VEH[vehNet] = { model = 970598228, plate = 'DISABLE1', exists = true }

        -- Cria sessão legítima e registra remoção do capô (bonnet)
        local s = ChopSession.Create(vehNet, 1)
        if s then
            ChopSession.AddParticipant(s.id, 1)
            ChopSession.MarkRaised(s.id, 1)
            VPChopAdvancedState.markPart(s.id, 1, 'bonnet')
        end

        local commitRes = s and VPChopAdvEngineCommit(1, vehNet, s.id) or { ok = false }
        check('FORENSIC-DISABLE-01 VPChopAdvEngineCommit succeeds', commitRes.ok == true)
        check('FORENSIC-DISABLE-01 statebag vpChopEngineMissing set to true', _G.FAKE_VEH[vehNet].vpChopEngineMissing == true)
    end

    -- ─── 4. FORENSIC-LOCALE: Paridade de Chaves em Todos os 5 Idiomas ─────────
    do
        local requiredKeys = {
            'err_engine_missing',
            'err_catalytic_stolen_drive',
            'forensic_target_inspect',
            'forensic_inspecting',
            'forensic_report_title',
            'forensic_engine_ok',
            'forensic_engine_missing',
            'forensic_catalytic_ok',
            'forensic_catalytic_stolen',
            'forensic_vin_ok',
            'forensic_vin_scratched',
            'forensic_tracker_active',
            'forensic_tracker_cut',
            'forensic_tracker_none',
            'forensic_plate_disguised',
        }

        local languages = { 'en', 'pt', 'es', 'fr', 'tr' }
        for _, lang in ipairs(languages) do
            Config.Locale = lang
            for _, key in ipairs(requiredKeys) do
                local val = L(key)
                check(('FORENSIC-LOCALE-01 Key %s present in %s'):format(key, lang), val ~= nil and val ~= key and val ~= '')
            end
        end
        Config.Locale = 'en'
    end

    -- ─── 5. FORENSIC-CANARY: Canaries de Integridade ──────────────────────────
    do
        local fServer = io.open('server/partserial.lua', 'r')
        local cServer = fServer and fServer:read('*all') or ''
        if fServer then fServer:close() end

        check('FORENSIC-CANARY-01 server/partserial.lua contains inspectVehicle callback', cServer:find("vp_chopshop:inspectVehicle", 1, true) ~= nil)
        check('FORENSIC-CANARY-02 server/partserial.lua checks BridgeIsPolice', cServer:find("BridgeIsPolice", 1, true) ~= nil)

        local fClient = io.open('client/partserial.lua', 'r')
        local cClient = fClient and fClient:read('*all') or ''
        if fClient then fClient:close() end

        check('FORENSIC-CANARY-03 client/partserial.lua adds global vehicle target', cClient:find("addGlobalVehicle", 1, true) ~= nil)
        check('FORENSIC-CANARY-04 client/partserial.lua uses showVehicleInspectResult', cClient:find("showVehicleInspectResult", 1, true) ~= nil)
    end

    restoreEnv()
    print(('[forensic/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then
        error('forensic_scanner_spec falhou com ' .. fail .. ' erros')
    end
end

CreateThread(run)
