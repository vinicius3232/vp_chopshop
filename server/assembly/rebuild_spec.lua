-- server/assembly/rebuild_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.21 P7.5 / P7.6] VEHICLE REBUILD ENGINE SPEC SUITE
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[rebuild/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[rebuild/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local Rebuild = dofile('server/assembly/rebuild.lua')

    -- In-memory DB mock for Rebuild
    local dbStore = {}
    local nextInsertId = 100

    local mockDb = {
        query = {
            await = function(q, p) return {} end
        },
        insert = {
            await = function(q, p)
                local id = nextInsertId
                nextInsertId = nextInsertId + 1
                dbStore[id] = {
                    project_id = id,
                    owner_key = p[1],
                    chassis_model = p[2],
                    chassis_serial = p[3],
                    status = 'in_progress',
                    installed_parts = '{}',
                    created_at_ts = os.time(),
                }
                return id
            end
        },
        single = {
            await = function(q, p)
                local pKey = p[1]
                for _, row in pairs(dbStore) do
                    if row.owner_key == pKey and row.status == 'in_progress' then
                        return {
                            project_id = row.project_id,
                            owner_key = row.owner_key,
                            chassis_model = row.chassis_model,
                            chassis_serial = row.chassis_serial,
                            status = row.status,
                            installed_parts = row.installed_parts,
                            created_at_ts = row.created_at_ts,
                        }
                    end
                end
                return nil
            end
        },
        update = {
            await = function(q, p)
                if q:find('`installed_parts`') then
                    local partsJson = p[1]
                    local pId = p[2]
                    if dbStore[pId] then
                        dbStore[pId].installed_parts = partsJson
                        return 1
                    end
                elseif q:find("SET `status` = 'completed'") then
                    local pId = p[1]
                    if dbStore[pId] and dbStore[pId].status == 'in_progress' then
                        dbStore[pId].status = 'completed'
                        return 1
                    end
                end
                return 0
            end
        }
    }

    Rebuild.Init(mockDb, os.time)
    check('REBUILD-INIT-01 Rebuild is ready with valid DB mock', Rebuild.IsReady() == true)

    -- ─── 1. Project Creation ────────────────────────────────────────────────────
    local src = 1
    local origPlayerKey = _G.ServerChopPlayerKey
    _G.ServerChopPlayerKey = function(s) return 'citizen_test_' .. tostring(s) end

    local invalidSrc = Rebuild.StartProject(-1, 'sultanrs', 'CHAS-001')
    check('REBUILD-START-01 Rejects invalid source', invalidSrc.ok == false and invalidSrc.err == 'invalid_source')

    local invalidModel = Rebuild.StartProject(src, '', 'CHAS-001')
    check('REBUILD-START-02 Rejects empty chassis model', invalidModel.ok == false and invalidModel.err == 'invalid_chassis_model')

    local startRes = Rebuild.StartProject(src, 'sultanrs', 'CHAS-001')
    check('REBUILD-START-03 Successfully starts new rebuild project', startRes.ok == true and startRes.projectId == 100)

    -- Tentativa de iniciar segundo projeto simultâneo
    local dupRes = Rebuild.StartProject(src, 'banshee', 'CHAS-002')
    check('REBUILD-START-04 Rejects starting second active project for same player', dupRes.ok == false and dupRes.err == 'project_already_in_progress')

    -- ─── 2. GetActiveProject ────────────────────────────────────────────────────
    local active = Rebuild.GetActiveProject(src)
    check('REBUILD-ACTIVE-01 Retrieves active project correctly', active ~= nil and active.projectId == 100 and active.chassisModel == 'sultanrs')

    -- ─── 3. Physical Part Installation ──────────────────────────────────────────
    local physicalStore = {
        ['PART-ENG-01'] = {
            partId = 'PART-ENG-01',
            partType = 'adv_engine',
            serial = 'ENG-SER-001',
            conditionPct = 85.0,
            legalState = 'refurbished',
            ownerKey = 'citizen_test_1',
            sourceModel = 'sultanrs',
            vehicleClass = 7,
            installedVehicleId = false,
        },
        ['PART-ENG-WORN'] = {
            partId = 'PART-ENG-WORN',
            partType = 'adv_engine',
            serial = 'ENG-SER-WORN',
            conditionPct = 40.0,
            legalState = 'stolen',
            ownerKey = 'citizen_test_1',
            sourceModel = 'sultanrs',
            vehicleClass = 7,
            installedVehicleId = false,
        },
        ['PART-DOOR-OTHER'] = {
            partId = 'PART-DOOR-OTHER',
            partType = 'door_dside_f',
            serial = 'DOOR-SER-OTHER',
            conditionPct = 90.0,
            legalState = 'clean',
            ownerKey = 'citizen_other_player',
            sourceModel = 'sultanrs',
            vehicleClass = 7,
            installedVehicleId = false,
        },
    }

    local consumedParts = {}
    _G.PhysicalPart = {
        Get = function(id) return physicalStore[id] end,
        UpdateState = function(id, updates)
            if physicalStore[id] then
                for k, v in pairs(updates) do
                    physicalStore[id][k] = v
                end
                return true
            end
            return false
        end,
        Consume = function(id, reason)
            consumedParts[id] = reason
            if physicalStore[id] then
                physicalStore[id].consumed = true
            end
            return true
        end,
    }

    -- Tentar instalar peça de outro dono
    local notOwnerRes = Rebuild.InstallPart(100, src, 'door_dside_f', 'PART-DOOR-OTHER')
    check('REBUILD-INST-01 Rejects part belonging to another owner', notOwnerRes.ok == false and notOwnerRes.err == 'not_part_owner')

    -- Tentar instalar peça com condição insuficiente
    local wornRes = Rebuild.InstallPart(100, src, 'adv_engine', 'PART-ENG-WORN')
    check('REBUILD-INST-02 Rejects engine with condition below min threshold', wornRes.ok == false and wornRes.err == 'insufficient_condition')

    -- Instalar motor válido
    local instEng = Rebuild.InstallPart(100, src, 'adv_engine', 'PART-ENG-01')
    check('REBUILD-INST-03 Installs valid engine successfully', instEng.ok == true and instEng.slot == 'adv_engine')
    check('REBUILD-INST-04 Physical part is locked to projectId', physicalStore['PART-ENG-01'].installedVehicleId == 100)

    -- Tentar instalar outro motor no mesmo slot
    local dupSlotRes = Rebuild.InstallPart(100, src, 'adv_engine', 'PART-ENG-01')
    check('REBUILD-INST-05 Rejects installation when slot is already occupied', dupSlotRes.ok == false and dupSlotRes.err == 'slot_already_occupied')

    -- ─── 4. Part Removal ────────────────────────────────────────────────────────
    local removeRes = Rebuild.RemovePart(100, src, 'adv_engine')
    check('REBUILD-REM-01 Removes installed part from slot', removeRes.ok == true and removeRes.removedPartId == 'PART-ENG-01')
    check('REBUILD-REM-02 Physical part is unlocked (installedVehicleId == false)', physicalStore['PART-ENG-01'].installedVehicleId == false)

    local remEmptyRes = Rebuild.RemovePart(100, src, 'adv_engine')
    check('REBUILD-REM-03 Rejects removal from empty slot', remEmptyRes.ok == false and remEmptyRes.err == 'slot_is_empty')

    -- ─── 5. Finalize Assembly & Anti-Dupe Terminal Destruction ──────────────────
    -- Re-instalar o motor
    Rebuild.InstallPart(100, src, 'adv_engine', 'PART-ENG-01')

    -- Tentar finalizar com componentes faltando
    local prematureFinalize = Rebuild.FinalizeAssembly(100, src)
    check('REBUILD-FIN-01 Rejects assembly when required components are missing', prematureFinalize.ok == false and prematureFinalize.err == 'missing_required_components')

    -- Preencher todos os slots obrigatórios
    local requiredSlots = {
        'catalytic_converter',
        'door_dside_f',
        'door_pside_f',
        'bonnet',
        'boot',
        'tyre_lf',
        'tyre_rf',
        'tyre_lr',
        'tyre_rr',
    }

    for _, slot in ipairs(requiredSlots) do
        local pId = 'PART-' .. slot:upper()
        physicalStore[pId] = {
            partId = pId,
            partType = slot,
            serial = 'SER-' .. slot,
            conditionPct = 80.0,
            legalState = 'clean',
            ownerKey = 'citizen_test_1',
            sourceModel = 'sultanrs',
            vehicleClass = 7,
            installedVehicleId = false,
        }
        local instOk = Rebuild.InstallPart(100, src, slot, pId)
        assert(instOk.ok == true, 'Failed to install test part: ' .. slot)
    end

    -- Mock do VINRebirth e BridgeRegisterCivilVehicle
    _G.BridgeRegisterCivilVehicle = function(cid, model, plate, vin, props)
        return true, nil, 42
    end

    local finalRes = Rebuild.FinalizeAssembly(100, src)
    check('REBUILD-FIN-02 Finalizes assembly when all parts installed', finalRes.ok == true and finalRes.completed == true)
    check('REBUILD-FIN-03 Project status updated to completed in DB', dbStore[100].status == 'completed')

    -- Verificar destruição terminal anti-dupe de todas as 10 peças
    local allConsumed = true
    if not consumedParts['PART-ENG-01'] then allConsumed = false end
    for _, slot in ipairs(requiredSlots) do
        local pId = 'PART-' .. slot:upper()
        if not consumedParts[pId] then allConsumed = false end
    end
    check('REBUILD-FIN-04 All installed physical parts terminal consumed (Anti-Dupe)', allConsumed == true)

    -- Verificar geração de placa e VIN via rebirth
    check('REBUILD-FIN-05 Returns rebirth vehicle data with plate and VIN', finalRes.vehicle ~= nil and finalRes.vehicle.plate ~= nil and #finalRes.vehicle.vin == 17)

    -- Teardown
    _G.PhysicalPart = nil
    _G.ServerChopPlayerKey = origPlayerKey
    _G.BridgeRegisterCivilVehicle = nil

    print(('─── RESUMO REBUILD SPEC: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('rebuild_spec failed: %d assertions failed'):format(fail))
end

run()
