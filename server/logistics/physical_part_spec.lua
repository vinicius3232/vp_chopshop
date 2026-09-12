-- server/logistics/physical_part_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.19 P5.4] PHYSICAL PART DOMAIN SPEC SUITE
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[physical_part/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[physical_part/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local PP = dofile('server/logistics/physical_part.lua')
    local partsDb = {}

    local mockDb = {
        query = {
            await = function(sql, params)
                params = params or {}
                -- SELECT by part_id
                if sql:find('SELECT', 1, true) and sql:find('WHERE `part_id` = ?', 1, true) then
                    local pId = params[1]
                    if partsDb[pId] then
                        return { partsDb[pId] }
                    end
                    return {}
                end

                -- SELECT WHERE `bench_id` IS NOT NULL
                if sql:find('WHERE `bench_id` IS NOT NULL', 1, true) then
                    local rows = {}
                    for _, p in pairs(partsDb) do
                        if p.bench_id ~= nil then
                            table.insert(rows, p)
                        end
                    end
                    return rows
                end

                -- INSERT
                if sql:find('INSERT INTO `vp_chop_physical_parts`', 1, true) then
                    local pId = params[1]
                    partsDb[pId] = {
                        part_id       = pId,
                        part_type     = params[2],
                        serial        = params[3],
                        source_vsid   = params[4],
                        source_model  = params[5],
                        vehicle_class = params[6],
                        condition_pct = params[7],
                        quality_tier  = params[8],
                        legal_state   = params[9],
                        owner_key     = params[10],
                        bench_id      = params[11],
                    }
                    return { affectedRows = 1 }
                end

                -- UPDATE bench_id and owner_key
                if sql:find('UPDATE `vp_chop_physical_parts` SET `bench_id` = ?, `owner_key` = ? WHERE `part_id` = ?', 1, true) then
                    local pId = params[3]
                    if partsDb[pId] then
                        partsDb[pId].bench_id = params[1]
                        partsDb[pId].owner_key = params[2]
                        return { affectedRows = 1 }
                    end
                    return { affectedRows = 0 }
                end

                -- UPDATE bench_id = NULL
                if sql:find('UPDATE `vp_chop_physical_parts` SET `bench_id` = NULL WHERE `bench_id` = ?', 1, true) then
                    local bId = params[1]
                    local count = 0
                    for _, p in pairs(partsDb) do
                        if p.bench_id == bId then
                            p.bench_id = nil
                            count = count + 1
                        end
                    end
                    return { affectedRows = count }
                end

                -- UPDATE state
                if sql:find('UPDATE `vp_chop_physical_parts` SET', 1, true) and sql:find('WHERE `part_id` = ?', 1, true) then
                    local pId = params[#params]
                    if partsDb[pId] then
                        return { affectedRows = 1 }
                    end
                    return { affectedRows = 0 }
                end

                -- DELETE
                if sql:find('DELETE FROM `vp_chop_physical_parts` WHERE `part_id` = ?', 1, true) then
                    local pId = params[1]
                    if partsDb[pId] then
                        partsDb[pId] = nil
                        return { affectedRows = 1 }
                    end
                    return { affectedRows = 0 }
                end

                return {}
            end
        }
    }

    PP.Init(mockDb, function() return 1700000000 end)
    check('PP-INIT-01 PhysicalPart initialized and ready', PP.IsReady() == true)

    -- ─── 1. Criação de Peça Física ──────────────────────────────────────────────
    local res1 = PP.Create({
        partType     = 'adv_engine',
        serial       = 'ENG-7721-Z',
        sourceVsid   = 'vsid_test_99',
        sourceModel  = 'sultan',
        vehicleClass = 7,
        conditionPct = 95.5,
        legalState   = 'stolen',
    })
    check('PP-CREATE-01 Create returns ok', res1.ok == true and res1.part ~= nil)
    check('PP-CREATE-02 Generated unique partId', res1.part.partId and res1.part.partId:find('^part_') ~= nil)
    check('PP-CREATE-03 Condition clamped correctly', res1.part.conditionPct == 95.5)
    check('PP-CREATE-04 Serial preserved in record', res1.part.serial == 'ENG-7721-Z')

    local partId1 = res1.part.partId

    -- ─── 2. Consulta de Peça Física ─────────────────────────────────────────────
    local fetched = PP.Get(partId1)
    check('PP-GET-01 Get returns persisted part', fetched ~= nil and fetched.partId == partId1)
    check('PP-GET-02 Fields match persisted data', fetched.sourceModel == 'sultan' and fetched.legalState == 'stolen')

    -- ─── 3. Vinculação e Desvinculação de Bancada ───────────────────────────────
    local okPlace = PP.PlaceOnBench(partId1, 42, 'license:player_1')
    check('PP-BENCH-01 PlaceOnBench succeeds', okPlace == true)
    check('PP-BENCH-02 Bench ID updated in DB', partsDb[partId1].bench_id == 42)

    local benchParts = PP.LoadBenchParts()
    check('PP-BENCH-03 LoadBenchParts returns part on bench', #benchParts >= 1 and benchParts[1].partId == partId1)

    local okTake = PP.TakeFromBench(42, 'license:player_1')
    check('PP-BENCH-04 TakeFromBench clears bench_id', okTake == true and partsDb[partId1].bench_id == nil)

    -- ─── 4. Atualização de Estado ───────────────────────────────────────────────
    local okUpd = PP.UpdateState(partId1, { legalState = 'scratched', conditionPct = 80.0 })
    check('PP-UPD-01 UpdateState succeeds', okUpd == true)

    -- ─── 5. Consumo Terminal ───────────────────────────────────────────────────
    local okConsume = PP.Consume(partId1, 'scrapped')
    check('PP-CONSUME-01 Consume deletes part', okConsume == true and partsDb[partId1] == nil)
    check('PP-GET-03 Get returns nil after consumption', PP.Get(partId1) == nil)

    print(('─── RESUMO PHYSICAL PART: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('physical_part_spec failed: %d assertions failed'):format(fail))
end

run()
