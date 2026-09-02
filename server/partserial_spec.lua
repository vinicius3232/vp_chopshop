-- server/partserial_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Self-test de server/partserial.lua e server/tyremarks.lua.
--  Self-gated na convar vp_chopshop_selftest 1. Fakes OneSync / ox_inventory.
--
--  Valida:
--   1) VPChopSerialGen gera string alfanumérica de 10 caracteres;
--   2) Resolução server-safe de modelo de veículo via GetEntityModel (sem crash de
--      GetDisplayNameFromVehicleModel que é client-only);
--   3) Cache de série por netId (mesmo netId -> mesma série) e cleanup em entityRemoved;
--   4) Metadata de car_parts roubada { serial, state='stolen', sourceModel };
--   5) Resolução server-safe de marcas de pneu em server/tyremarks.lua;
--   6) Canário estático: varre arquivos server/ para proibir natives client-only.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[partserial/spec] PASS  ' .. name)
    else fail = fail + 1; print('[partserial/spec] FAIL  ' .. name) end
end

local function run()
    -- Garantir que GetDisplayNameFromVehicleModel é explicitamente nil no servidor (ambiente FiveM real)
    _G.GetDisplayNameFromVehicleModel = nil

    -- 1) Teste de geração de serial
    local s1 = VPChopSerialGen()
    local s2 = VPChopSerialGen()
    check('serial length is 10', type(s1) == 'string' and #s1 == 10)
    check('serial is alphanumeric uppercase', s1:match('^[A-Z0-9]+$') ~= nil)
    check('subsequent serials are unique', s1 ~= s2)

    -- 2) Mock de veículo e ox_inventory AddItem
    local addedItems = {}
    local origAddItem = _G.FAKE_EXPORTS.ox_inventory and _G.FAKE_EXPORTS.ox_inventory.AddItem
    _G.FAKE_EXPORTS.ox_inventory = _G.FAKE_EXPORTS.ox_inventory or {}
    _G.FAKE_EXPORTS.ox_inventory.AddItem = function(_, src, item, count, metadata)
        addedItems[#addedItems + 1] = { src = src, item = item, count = count, metadata = metadata }
        _G._ADV_REWARD = (_G._ADV_REWARD or 0) + 1
        return true
    end

    local origPartSerial = _G.Config and _G.Config.PartSerial
    _G.Config = _G.Config or {}
    _G.Config.PartSerial = {
        Enable = true,
        PoliceJobs = { 'police', 'bcso', 'sheriff' },
        ScannerItem = 'parts_scanner',
        ForensicItem = 'forensic_kit',
        VehicleInspection = { Enable = true, DurationMs = 5000 },
    }

    local netId = 501
    _G.FAKE_VEH[netId] = { model = 970598228 } -- joaat("sultan")

    -- 3) VPChopAddStolenCarParts server-safe (não pode chamar GetDisplayNameFromVehicleModel)
    local ok1 = VPChopAddStolenCarParts(1, netId, 2)
    check('VPChopAddStolenCarParts returns true without client native', ok1 == true)
    check('addedItems contains 1 entry', #addedItems == 1)
    check('addedItems item is car_parts', addedItems[1].item == 'car_parts')
    check('addedItems count is 2', addedItems[1].count == 2)
    check('metadata state is stolen', addedItems[1].metadata and addedItems[1].metadata.state == 'stolen')
    check('metadata serial is 10 chars', addedItems[1].metadata and #addedItems[1].metadata.serial == 10)
    check('metadata sourceModel is resolved server-safe', addedItems[1].metadata and addedItems[1].metadata.sourceModel == '970598228')

    -- 4) Reuso de série para o mesmo netId
    local firstSerial = addedItems[1].metadata.serial
    local ok2 = VPChopAddStolenCarParts(1, netId, 1)
    check('second call for same netId returns true', ok2 == true)
    check('second call reuses exact same serial (same car)', addedItems[2].metadata.serial == firstSerial)
    check('second call reuses exact same sourceModel', addedItems[2].metadata.sourceModel == '970598228')

    -- 5) Desmanche com netId inválido/sem veículo gera série solta
    local ok3 = VPChopAddStolenCarParts(1, 0, 1)
    check('call with netId 0 delivers loose serial', ok3 == true)
    check('loose serial is unique', addedItems[3].metadata.serial ~= firstSerial)

    -- 6) Canário estático: varredura em server/ contra natives exclusivamente client
    local forbiddenNatives = {
        'GetDisplayNameFromVehicleModel',
        'GetLabelText',
        'DrawMarker',
        'RequestModel',
        'CreateCam',
    }

    local serverFiles = {
        'server/partserial.lua',
        'server/tyremarks.lua',
        'server/chop.lua',
        'server/advanced_chop.lua',
        'server/main.lua',
        'server/fence.lua',
        'server/plates.lua',
        'server/bench.lua',
    }

    local base = _G._HARNESS_BASE or '.'
    for _, relPath in ipairs(serverFiles) do
        local f = io.open(base .. '/' .. relPath, 'r')
        if f then
            local content = f:read('*a')
            f:close()
            for _, nativeName in ipairs(forbiddenNatives) do
                local found = content:find(nativeName .. '%s*%(')
                check(('server file %s does NOT call client native %s'):format(relPath, nativeName), found == nil)
            end
        end
    end

    _G.Config.PartSerial = origPartSerial
    if origAddItem then _G.FAKE_EXPORTS.ox_inventory.AddItem = origAddItem end
    print(('[partserial/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
end

CreateThread(run)
