-- server/forensic_scanner_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 P4.4.1] Forensic Domain Integration & Read-Only Hardening Spec
--  Tests real domain contracts (Plates, VIN/Heat, TrackerManager, PartSerial),
--  tri-state VIN lookups, strict netId boundaries, read-only guarantees,
--  i18n parity, and static architecture canaries.
--  Gated on convar vp_chopshop_selftest 1
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
    local origMySQLScalar     = MySQL and MySQL.scalar and MySQL.scalar.await
    local origMDT             = _G.VPChopMDT
    local origSerialGen       = _G.VPChopSerialGen

    local mockInventory = {}
    local mockPolice = {}
    local mockVinDb = {}
    local mockFakePlatesDb = {}
    local serialGenCalls = 0

    Config.PartSerial = {
        Enable = true,
        PoliceJobs = { 'police', 'bcso', 'sheriff' },
        ScannerItem = 'parts_scanner',
        ForensicItem = 'forensic_kit',
        InspectCooldownSeconds = 5,
        VehicleInspection = {
            Enable = true,
            DurationMs = 5000,
        },
    }

    _G.BridgeIsPolice = function(src, _) return mockPolice[src] == true end
    _G.InvCount = function(src, item) return (mockInventory[src] and mockInventory[src][item]) or 0 end

    _G.VPChopSerialGen = function()
        serialGenCalls = serialGenCalls + 1
        return origSerialGen and origSerialGen() or ('GEN-%04d'):format(serialGenCalls)
    end

    _G.MySQL = _G.MySQL or {}
    _G.MySQL.scalar = _G.MySQL.scalar or {}
    _G.MySQL.scalar.await = function(query, params)
        if query and query:find('vp_chop_vin_scratched') then
            local plate = params and params[1]
            if plate == 'DB_ERROR' then
                error('MySQL timeout')
            end
            return mockVinDb[plate] and 1 or nil
        end
        if query and query:find('vp_chop_fake_plates') then
            local fake = params and params[1]
            return mockFakePlatesDb[fake] or nil
        end
        if origMySQLScalar then
            return origMySQLScalar(query, params)
        end
        return nil
    end

    _G.VPChopMDT = _G.VPChopMDT or {}
    _G.VPChopMDT.GetRealPlate = function(visiblePlate)
        if not visiblePlate or visiblePlate == '' then return visiblePlate end
        return mockFakePlatesDb[visiblePlate] or visiblePlate
    end

    local function restoreEnv()
        Config.PartSerial = origPartSerialCfg
        Config.CatalyticTheft = origCatalyticCfg
        _G.BridgeIsPolice = origBridgeIsPolice
        _G.InvCount = origInvCount
        _G.VPChopSerialGen = origSerialGen
        if MySQL and MySQL.scalar then
            MySQL.scalar.await = origMySQLScalar
        end
        _G.VPChopMDT = origMDT
        _G._CUSTOM_TIMER = nil
        _G._MOCK_ENTITY_TYPES = nil
        if TrackerManager and TrackerManager._test then
            TrackerManager._test.reset()
        end
    end

    -- Recupera o handler do callback registrado no lib.callback
    local callbacks = _G.CapturedCallbacks or _G.LIB_CALLBACKS or {}
    local inspectVehCb = callbacks['vp_chopshop:inspectVehicle']
    local inspectPartsCb = callbacks['vp_chopshop:inspectParts']

    -- ─── 1. FORENSIC-AUTH & TOOL: Gate Policial e Ferramenta ─────────────────
    do
        _G._CUSTOM_TIMER = (_G._CUSTOM_TIMER or 100000) + 10000
        mockPolice = { [1] = false, [2] = true }
        mockInventory = { [1] = { parts_scanner = 1 }, [2] = { parts_scanner = 1 } }
        _G.FAKE_VEH[101] = { model = 970598228, plate = 'POLTEST1', exists = true }

        -- Policial falso / civil tenta inspecionar veículo
        local resCivVeh = inspectVehCb(1, 101)
        check('FORENSIC-AUTH-01 civilian inspectVehicle rejected with not_police', resCivVeh.ok == false and resCivVeh.err == 'not_police')

        -- Policial falso tenta inspecionar peças de jogador
        local resCivParts = inspectPartsCb(1, 2)
        check('FORENSIC-AUTH-02 civilian inspectParts rejected with not_police', resCivParts.ok == false and resCivParts.err == 'not_police')

        -- Policial autêntico sem ferramenta de scan
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        mockInventory[2] = { parts_scanner = 0, forensic_kit = 0 }
        local resNoTool = inspectVehCb(2, 101)
        check('FORENSIC-TOOL-01 police without scanner or forensic kit rejected with no_tool', resNoTool.ok == false and resNoTool.err == 'no_tool')

        -- Policial autêntico com forensic_kit
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        mockInventory[2] = { parts_scanner = 0, forensic_kit = 1 }
        local resKit = inspectVehCb(2, 101)
        check('FORENSIC-TOOL-02 police with forensic_kit succeeds with forensic=true', resKit.ok == true and resKit.forensic == true)
    end

    -- ─── 2. FORENSIC-FLAG: Feature Flags Server-Side ─────────────────────────
    do
        mockPolice = { [2] = true }
        mockInventory = { [2] = { parts_scanner = 1 } }
        _G.FAKE_VEH[102] = { model = 970598228, plate = 'FLAGTEST', exists = true }

        -- VehicleInspection.Enable = false
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        Config.PartSerial.VehicleInspection.Enable = false
        local resFlagVehOff = inspectVehCb(2, 102)
        check('FORENSIC-FLAG-01 VehicleInspection.Enable=false returns disabled', resFlagVehOff.ok == false and resFlagVehOff.err == 'disabled')

        -- PartSerial.Enable = false
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        Config.PartSerial.VehicleInspection.Enable = true
        Config.PartSerial.Enable = false
        local resFlagAllOff = inspectVehCb(2, 102)
        check('FORENSIC-FLAG-02 PartSerial.Enable=false returns disabled', resFlagAllOff.ok == false and resFlagAllOff.err == 'disabled')

        -- Restaura flags
        Config.PartSerial.Enable = true
        Config.PartSerial.VehicleInspection.Enable = true
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        local resFlagOn = inspectVehCb(2, 102)
        check('FORENSIC-FLAG-03 both flags true proceeds', resFlagOn.ok == true)
    end

    -- ─── 3. FORENSIC-NET & ENTITY: Trust Boundary do NetId & Tipo de Entidade ─
    do
        mockPolice = { [2] = true }
        mockInventory = { [2] = { parts_scanner = 1 } }
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000

        check('FORENSIC-NET-01 string netId rejected', inspectVehCb(2, "102").ok == false and inspectVehCb(2, "102").err == 'invalid_net')
        check('FORENSIC-NET-02 zero netId rejected', inspectVehCb(2, 0).ok == false and inspectVehCb(2, 0).err == 'invalid_net')
        check('FORENSIC-NET-03 negative netId rejected', inspectVehCb(2, -102).ok == false and inspectVehCb(2, -102).err == 'invalid_net')
        check('FORENSIC-NET-04 float netId rejected', inspectVehCb(2, 102.5).ok == false and inspectVehCb(2, 102.5).err == 'invalid_net')
        check('FORENSIC-NET-05 NaN netId rejected', inspectVehCb(2, 0/0).ok == false and inspectVehCb(2, 0/0).err == 'invalid_net')
        check('FORENSIC-NET-06 math.huge netId rejected', inspectVehCb(2, math.huge).ok == false and inspectVehCb(2, math.huge).err == 'invalid_net')

        -- Validação de tipo de entidade (GetEntityType: 1=ped, 2=vehicle, 3=object)
        _G.FAKE_VEH[103] = { model = 970598228, plate = 'PEDENT', exists = true }
        _G.FAKE_VEH[104] = { model = 970598228, plate = 'OBJENT', exists = true }
        _G.FAKE_VEH[105] = { model = 970598228, plate = 'VEHENT', exists = true }

        local origGetEntityType = _G.GetEntityType
        _G.GetEntityType = function(h)
            if h == 70103 then return 1 end -- Ped
            if h == 70104 then return 3 end -- Object
            return 2 -- Vehicle
        end

        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        local resPed = inspectVehCb(2, 103)
        check('FORENSIC-ENTITY-01 ped entity rejected with not_a_vehicle', resPed.ok == false and resPed.err == 'not_a_vehicle')

        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        local resObj = inspectVehCb(2, 104)
        check('FORENSIC-ENTITY-02 object entity rejected with not_a_vehicle', resObj.ok == false and resObj.err == 'not_a_vehicle')

        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        local resVeh = inspectVehCb(2, 105)
        check('FORENSIC-ENTITY-03 vehicle entity accepted', resVeh.ok == true)

        _G.GetEntityType = origGetEntityType
    end

    -- ─── 4. FORENSIC-PLATE: Resolução Canônica de Placas e Disfarces ─────────
    do
        mockPolice = { [2] = true }
        mockInventory = { [2] = { parts_scanner = 1 } }

        -- Cenário 1: Fake plate real mapping FAKE999 -> REAL777
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[201] = { model = 970598228, plate = 'FAKE999', exists = true }
        mockFakePlatesDb['FAKE999'] = 'REAL777'

        local resDisguised = inspectVehCb(2, 201)
        check('FORENSIC-PLATE-REAL-01 fake plate maps to canonical real plate', resDisguised.ok == true)
        check('FORENSIC-PLATE-REAL-01 visible plate is FAKE999', resDisguised.data and resDisguised.data.plate == 'FAKE999')
        check('FORENSIC-PLATE-REAL-01 original plate is REAL777', resDisguised.data and resDisguised.data.plateOriginal == 'REAL777')
        check('FORENSIC-PLATE-REAL-01 plateDisguised is true', resDisguised.data and resDisguised.data.plateDisguised == true)

        -- Cenário 2: Placa limpa (visible == canonical)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[202] = { model = 970598228, plate = 'CLEAN01', exists = true }
        mockFakePlatesDb['CLEAN01'] = nil

        local resClean = inspectVehCb(2, 202)
        check('FORENSIC-PLATE-CLEAN-01 visible plate is CLEAN01', resClean.data and resClean.data.plate == 'CLEAN01')
        check('FORENSIC-PLATE-CLEAN-01 plateOriginal is nil', resClean.data and resClean.data.plateOriginal == nil)
        check('FORENSIC-PLATE-CLEAN-01 plateDisguised is false', resClean.data and resClean.data.plateDisguised == false)

        -- Cenário 3: Confirmação de que vpChopPlateOriginal NÃO é lido
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[203] = { model = 970598228, plate = 'NOMOCK', exists = true, vpChopPlateOriginal = 'FAKE_STATEBAG' }
        mockFakePlatesDb['NOMOCK'] = nil
        local resNoMock = inspectVehCb(2, 203)
        check('FORENSIC-PLATE-MOCK-01 ignores vpChopPlateOriginal statebag', resNoMock.data and resNoMock.data.plateOriginal == nil and resNoMock.data.plateDisguised == false)
    end

    -- ─── 5. FORENSIC-VIN: Tri-State VIN Real e Resolução de Placa Real ──────
    do
        mockPolice = { [2] = true }
        mockInventory = { [2] = { parts_scanner = 1 } }

        -- Cenário 1: VIN raspado (row existente em vp_chop_vin_scratched)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[211] = { model = 970598228, plate = 'VINSCRAT', exists = true }
        mockVinDb['VINSCRAT'] = true

        local resVinScratched = inspectVehCb(2, 211)
        check('FORENSIC-VIN-REAL-01 vinStatus is scratched', resVinScratched.data and resVinScratched.data.vinStatus == 'scratched')
        check('FORENSIC-VIN-REAL-01 vinScratched is true', resVinScratched.data and resVinScratched.data.vinScratched == true)

        -- Cenário 2: VIN intacto (row ausente)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[212] = { model = 970598228, plate = 'VININTACT', exists = true }
        mockVinDb['VININTACT'] = false

        local resVinIntact = inspectVehCb(2, 212)
        check('FORENSIC-VIN-REAL-02 vinStatus is intact', resVinIntact.data and resVinIntact.data.vinStatus == 'intact')
        check('FORENSIC-VIN-REAL-02 vinScratched is false', resVinIntact.data and resVinIntact.data.vinScratched == false)

        -- Cenário 3: Falha de DB (pcall captura erro com segurança)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[213] = { model = 970598228, plate = 'DB_ERROR', exists = true }

        local resVinDbErr = inspectVehCb(2, 213)
        check('FORENSIC-VIN-DB-01 DB failure yields vinStatus unknown without crash', resVinDbErr.ok == true and resVinDbErr.data and resVinDbErr.data.vinStatus == 'unknown')
        check('FORENSIC-VIN-DB-01 vinScratched is false on DB error', resVinDbErr.data and resVinDbErr.data.vinScratched == false)

        -- Cenário 4: Placa falsa resolve para REAL antes de consultar VIN
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[214] = { model = 970598228, plate = 'FAKECLONE', exists = true }
        mockFakePlatesDb['FAKECLONE'] = 'REALORIG'
        mockVinDb['FAKECLONE'] = false
        mockVinDb['REALORIG'] = true

        local resVinCanonical = inspectVehCb(2, 214)
        check('FORENSIC-VIN-CANONICAL-01 resolves real plate before VIN check', resVinCanonical.data and resVinCanonical.data.vinStatus == 'scratched' and resVinCanonical.data.vinScratched == true)
    end

    -- ─── 6. FORENSIC-TRK: Consulta Read-Only ao TrackerManager ───────────────
    do
        mockPolice = { [2] = true }
        mockInventory = { [2] = { parts_scanner = 1 } }
        TrackerManager._test.reset()

        -- Cenário 1: Record ACTIVE no TrackerManager
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[221] = { model = 970598228, plate = 'TRKACT', exists = true }
        local obsActive = TrackerManager.ObserveVehicle(221, 'test', 1.0) -- Força 100% chance
        check('FORENSIC-TRK-01 record created as ACTIVE', obsActive.state == 'ACTIVE')

        local resTrkAct = inspectVehCb(2, 221)
        check('FORENSIC-TRK-01 active tracker status is active', resTrkAct.data and resTrkAct.data.trackerStatus == 'active')

        -- Cenário 2: Record NONE no TrackerManager + marcador vpChopTrackerId órfão
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[222] = { model = 970598228, plate = 'TRKNONE', exists = true, vpChopTrackerId = 'ORPHAN-TRK' }
        local obsNone = TrackerManager.ObserveVehicle(222, 'test', 0.0) -- Força 0% chance
        check('FORENSIC-TRK-02 record created as NONE', obsNone.state == 'NONE')

        local resTrkNone = inspectVehCb(2, 222)
        check('FORENSIC-TRK-02 record NONE returns trackerStatus none', resTrkNone.data and resTrkNone.data.trackerStatus == 'none')

        -- Cenário 3: Record REMOVED no TrackerManager (rastreador desarmado)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        mockInventory[2] = { parts_scanner = 1, pliers = 1 }
        _G.FAKE_VEH[223] = { model = 970598228, plate = 'TRKCUT', exists = true }
        local obsCut = TrackerManager.ObserveVehicle(223, 'test', 1.0)
        local startRem = TrackerManager.StartRemoval(2, 223)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 8000
        local compRem = TrackerManager.CompleteRemoval(2, 223, startRem.removalToken)

        local resTrkCut = inspectVehCb(2, 223)
        check('FORENSIC-TRK-03 removed tracker returns trackerStatus cut', resTrkCut.data and resTrkCut.data.trackerStatus == 'cut')

        -- Cenário 4: Marcador isolado sem record server-side
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[224] = { model = 970598228, plate = 'ORPHAN2', exists = true, vpChopTrackerId = 'STALE-999' }
        local resOrphan = inspectVehCb(2, 224)
        check('FORENSIC-TRK-04 orphan statebag without server record is NOT active', resOrphan.data and resOrphan.data.trackerStatus == 'none')

        -- Cenário 5: NetId recycled / Model mismatch
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[225] = { model = 970598228, plate = 'RECYCLE', exists = true }
        TrackerManager.ObserveVehicle(225, 'test', 1.0)
        -- Simula reutilização de netId trocando o modelo do veículo no handle
        _G.FAKE_VEH[225].model = 123456789
        local resRecycled = inspectVehCb(2, 225)
        check('FORENSIC-TRK-05 recycled netId / model mismatch does not return active', resRecycled.data and resRecycled.data.trackerStatus ~= 'active')

        -- Cenário 6 & 7: Scanner causa ZERO chamadas a ObserveVehicle e não muta _trackers
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[226] = { model = 970598228, plate = 'UNOBSERVED', exists = true }
        local trackersBefore = 0
        for _ in pairs(TrackerManager._test.getTrackers()) do trackersBefore = trackersBefore + 1 end

        local origObserve = TrackerManager.ObserveVehicle
        local observeCalls = 0
        TrackerManager.ObserveVehicle = function(...)
            observeCalls = observeCalls + 1
            return origObserve(...)
        end

        local resUnobserved = inspectVehCb(2, 226)
        check('FORENSIC-TRK-06 scanner causes ZERO calls to ObserveVehicle', observeCalls == 0)

        local trackersAfter = 0
        for _ in pairs(TrackerManager._test.getTrackers()) do trackersAfter = trackersAfter + 1 end
        check('FORENSIC-TRK-07 scan does not change tracker table count', trackersAfter == trackersBefore)
        check('FORENSIC-TRK-07 unobserved vehicle returns none', resUnobserved.data and resUnobserved.data.trackerStatus == 'none')

        TrackerManager.ObserveVehicle = origObserve
    end

    -- ─── 7. FORENSIC-READONLY: Scanner é Estritamente Read-Only para Serial ───
    do
        mockPolice = { [2] = true }
        mockInventory = { [2] = { parts_scanner = 1 } }

        -- Cenário 1: Veículo novo sem serial prévio
        serialGenCalls = 0
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[231] = { model = 970598228, plate = 'NOSERIAL', exists = true }

        local resNoSerial = inspectVehCb(2, 231)
        check('FORENSIC-READONLY-01 VPChopSerialGen call count is 0 on vehicle scan', serialGenCalls == 0)
        check('FORENSIC-READONLY-01 scan returns serial=nil for unchopped vehicle', resNoSerial.data and resNoSerial.data.serial == nil)
        check('FORENSIC-READONLY-01 sourceModel is resolved safely', resNoSerial.data and resNoSerial.data.sourceModel ~= nil)

        -- Cenário 2: Veículo que já possui serial em cache (por corte anterior)
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[232] = { model = 970598228, plate = 'HASEXISTING', exists = true }
        _G.VPChopAddStolenCarParts(2, 232, 1) -- Cria entrada no cache VehSerial

        local callsAfterChop = serialGenCalls
        local resWithSerial = inspectVehCb(2, 232)
        check('FORENSIC-READONLY-03 scanner returns existing cached serial without generating new one', resWithSerial.data and resWithSerial.data.serial ~= nil and serialGenCalls == callsAfterChop)
    end

    -- ─── 8. FORENSIC-DISABLE: Inutilização Veicular Anti-Farm ─────────────────
    do
        local vehNet = 301
        _G.FAKE_VEH[vehNet] = { model = 970598228, plate = 'DISABLE1', exists = true }

        local s = ChopSession.Create(vehNet, 1)
        if s then
            ChopSession.AddParticipant(s.id, 1)
            ChopSession.MarkRaised(s.id, 1)
            VPChopAdvancedState.markPart(s.id, 1, 'bonnet')
        end

        local commitRes = s and VPChopAdvEngineCommit(1, vehNet, s.id) or { ok = false }
        check('FORENSIC-DISABLE-01 VPChopAdvEngineCommit succeeds', commitRes.ok == true)
        check('FORENSIC-DISABLE-01 statebag vpChopEngineMissing set to true', _G.FAKE_VEH[vehNet].vpChopEngineMissing == true)

        -- Perícia detecta motor ausente
        mockPolice = { [2] = true }
        mockInventory = { [2] = { parts_scanner = 1 } }
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        local resGutted = inspectVehCb(2, vehNet)
        check('FORENSIC-DISABLE-02 engineMissing correctly detected', resGutted.data and resGutted.data.engineMissing == true)

        -- Catalisador furtado
        _G._CUSTOM_TIMER = _G._CUSTOM_TIMER + 5000
        _G.FAKE_VEH[302] = { model = 970598228, plate = 'CATGUT', exists = true, catalyticStolen = true }
        local resCatGut = inspectVehCb(2, 302)
        check('FORENSIC-DISABLE-03 catalyticStolen correctly detected', resCatGut.data and resCatGut.data.catalyticStolen == true)
    end

    -- ─── 9. FORENSIC-LOCALE: Paridade de Chaves nos 5 Idiomas ─────────────────
    do
        local requiredKeys = {
            'err_engine_missing',
            'err_catalytic_stolen_drive',
            'forensic_target_inspect',
            'forensic_inspecting',
            'forensic_report_title',
            'forensic_engine_ok',
            'forensic_engine_ok_desc',
            'forensic_engine_no_serial_desc',
            'forensic_engine_missing',
            'forensic_engine_missing_desc',
            'forensic_catalytic_ok',
            'forensic_catalytic_ok_desc',
            'forensic_catalytic_stolen',
            'forensic_catalytic_stolen_desc',
            'forensic_vin_ok',
            'forensic_vin_ok_desc',
            'forensic_vin_scratched',
            'forensic_vin_scratched_desc',
            'forensic_vin_unknown',
            'forensic_vin_unknown_desc',
            'forensic_tracker_active',
            'forensic_tracker_active_desc',
            'forensic_tracker_cut',
            'forensic_tracker_cut_desc',
            'forensic_tracker_none',
            'forensic_tracker_none_desc',
            'forensic_plate_disguised',
            'forensic_plate_disguised_desc',
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

    -- ─── 10. FORENSIC-CANARY & I18N: Canaries Estáticos e Arquiteturais ───────
    do
        local fServer = io.open('server/partserial.lua', 'r')
        local cServer = fServer and fServer:read('*all') or ''
        if fServer then fServer:close() end

        local fClient = io.open('client/partserial.lua', 'r')
        local cClient = fClient and fClient:read('*all') or ''
        if fClient then fClient:close() end

        local fHeat = io.open('server/heat.lua', 'r')
        local cHeat = fHeat and fHeat:read('*all') or ''
        if fHeat then fHeat:close() end

        local fTracker = io.open('server/tracker.lua', 'r')
        local cTracker = fTracker and fTracker:read('*all') or ''
        if fTracker then fTracker:close() end

        -- CANARY: ZERO ocorrências de vpChopPlateOriginal no código
        check('FORENSIC-CANARY-01 ZERO occurrences of vpChopPlateOriginal in server/partserial.lua', cServer:find("vpChopPlateOriginal", 1, true) == nil)
        check('FORENSIC-CANARY-01 ZERO occurrences of vpChopPlateOriginal in client/partserial.lua', cClient:find("vpChopPlateOriginal", 1, true) == nil)

        -- CANARY: ZERO chamadas a ObserveVehicle no callback de scan
        check('FORENSIC-CANARY-02 ZERO ObserveVehicle calls in server/partserial.lua', cServer:find("ObserveVehicle", 1, true) == nil)

        -- CANARY: VPChopIsVinScratched helper real em server/heat.lua
        check('FORENSIC-CANARY-03 server/heat.lua defines VPChopIsVinScratched', cHeat:find("function VPChopIsVinScratched", 1, true) ~= nil)

        -- CANARY: TrackerManager.GetVehicleState helper real em server/tracker.lua
        check('FORENSIC-CANARY-04 server/tracker.lua defines TrackerManager.GetVehicleState', cTracker:find("TrackerManager.GetVehicleState", 1, true) ~= nil)

        -- CANARY: Feature flag VehicleInspection.Enable no server e client
        check('FORENSIC-CANARY-05 server/partserial.lua checks VehicleInspection.Enable', cServer:find("VehicleInspection.Enable", 1, true) ~= nil)
        check('FORENSIC-CANARY-05 client/partserial.lua gates addGlobalVehicle with VehicleInspection.Enable', cClient:find("PS.VehicleInspection and PS.VehicleInspection.Enable", 1, true) ~= nil)

        -- CANARY: GetEntityType == 2 check
        check('FORENSIC-CANARY-06 server/partserial.lua checks GetEntityType(veh) ~= 2', cServer:find("GetEntityType(veh) ~= 2", 1, true) ~= nil)

        -- CANARY: ZERO frases em português hardcoded em showVehicleInspectResult
        local showFn = cClient:match("local function showVehicleInspectResult%(res%)(.-)end%s*\n\n")
        check('FORENSIC-I18N-01 showVehicleInspectResult has no hardcoded Portuguese',
            showFn ~= nil and
            showFn:find("O bloco do motor", 1, true) == nil and
            showFn:find("Tubulação de escape", 1, true) == nil and
            showFn:find("Numeração de chassi", 1, true) == nil and
            showFn:find("A placa visível", 1, true) == nil and
            showFn:find("Dispositivo LoJack", 1, true) == nil and
            showFn:find("Fiação de alimentação", 1, true) == nil and
            showFn:find("Veículo não equipado", 1, true) == nil
        )
    end

    restoreEnv()
    print(('[forensic/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then
        error('forensic_scanner_spec falhou com ' .. fail .. ' erros')
    end
end

CreateThread(run)

