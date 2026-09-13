-- server/assembly/compatibility_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.21 P7.2] PART COMPATIBILITY SPEC SUITE
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[compat/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[compat/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local PC = dofile('shared/compatibility.lua')

    -- ─── 1. Engine Family Resolution ────────────────────────────────────────────
    local v8Fam, v8Data = PC.GetEngineFamily('sultanrs', 7)
    check('COMPAT-FAM-01 Identifies v8_heavy family from sultanrs', v8Fam == 'v8_heavy' and v8Data ~= nil)

    local i4Fam, i4Data = PC.GetEngineFamily('blista', 0)
    check('COMPAT-FAM-02 Identifies i4_compact family from blista', i4Fam == 'i4_compact' and i4Data ~= nil)

    local v6Fam, v6Data = PC.GetEngineFamily('baller', 2)
    check('COMPAT-FAM-03 Identifies v6_suv family from baller', v6Fam == 'v6_suv' and v6Data ~= nil)

    -- ─── 2. Engine Compatibility Validation ──────────────────────────────────────
    -- Motor V8 (de Banshee) tentando ser instalado em um Blista (compacto)
    local canFitV8inBlista, reasonV8Blista = PC.CanFit('adv_engine', { sourceModel = 'banshee', vehicleClass = 7 }, 'blista', 0)
    check('COMPAT-ENG-01 Rejects V8 engine in compact Blista', canFitV8inBlista == false and reasonV8Blista:find('incompatible_engine_family') ~= nil)

    -- Motor V8 (de Banshee) tentando ser instalado em um Dominator (muscle)
    local canFitV8inDom, reasonV8Dom = PC.CanFit('adv_engine', { sourceModel = 'banshee', vehicleClass = 7 }, 'dominator', 4)
    check('COMPAT-ENG-02 Approves V8 engine in Dominator muscle chassis', canFitV8inDom == true and reasonV8Dom == 'engine_compatible')

    -- ─── 3. Tyre & Wheel Compatibility ──────────────────────────────────────────
    local canFitTyreCar, _ = PC.CanFit('chopshop_tyre', {}, 'sultanrs', 7)
    check('COMPAT-TYRE-01 Approves tyre in sports car', canFitTyreCar == true)

    local canFitTyreBike, reasonTyreBike = PC.CanFit('chopshop_tyre', {}, 'sanchez', 8)
    check('COMPAT-TYRE-02 Rejects car tyre in motorcycle', canFitTyreBike == false and reasonTyreBike == 'incompatible_tyre_for_bike_class')

    -- ─── 4. Body Panel Compatibility ────────────────────────────────────────────
    -- Porta direta de mesmo modelo
    local canFitDoorDirect, reasonDoorDirect = PC.CanFit('door_dside_f', { sourceModel = 'elegy', vehicleClass = 7 }, 'elegy', 7)
    check('COMPAT-PANEL-01 Approves direct door match for same model', canFitDoorDirect == true and reasonDoorDirect == 'direct_chassis_match')

    -- Porta de SUV tentando ser instalada em um Compacto
    local canFitDoorMismatch, reasonDoorMismatch = PC.CanFit('door_dside_f', { sourceModel = 'baller', vehicleClass = 2 }, 'panto', 0)
    check('COMPAT-PANEL-02 Rejects cross-class panel mismatch (SUV to Compact)', canFitDoorMismatch == false and reasonDoorMismatch == 'panel_class_mismatch')

    -- ─── 5. Catalytic Converter Compatibility ────────────────────────────────────
    local canFitCatCar, reasonCatCar = PC.CanFit('catalytic_converter', {}, 'baller', 2)
    check('COMPAT-CAT-01 Approves catalytic converter on standard vehicle', canFitCatCar == true and reasonCatCar == 'exhaust_compatible')

    local canFitCatBike, reasonCatBike = PC.CanFit('catalytic_converter', {}, 'bmx', 13)
    check('COMPAT-CAT-02 Rejects catalytic converter on bicycle (class 13)', canFitCatBike == false and reasonCatBike == 'exhaust_unsupported_vehicle_type')

    print(('─── RESUMO COMPATIBILITY: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('compatibility_spec failed: %d assertions failed'):format(fail))
end

run()
