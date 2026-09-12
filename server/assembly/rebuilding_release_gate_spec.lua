-- server/assembly/rebuilding_release_gate_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.21 P7-RC] VEHICLE REBUILDING & COMPATIBILITY RELEASE GATE SPEC
--  Suite Canônica de Verificação dos 10 Invariantes da Fase 7:
--    INV-P7-01: Engine Family Compatibility (cross-matching across classes)
--    INV-P7-02: Cross-Class Chassis & Body Component Restrictions
--    INV-P7-03: Refurbishment Recipe & Atomic Material Consumption
--    INV-P7-04: Optimal Condition Guard (no refurbishment on pristine parts)
--    INV-P7-05: Rebuild Project Exclusivity & Concurrency Locking
--    INV-P7-06: Quality Gate Thresholds on Component Installation
--    INV-P7-07: Physical Part Locking to Project (anti dual-use during assembly)
--    INV-P7-08: Anti-Dupe Terminal Destruction on Vehicle Finalization
--    INV-P7-09: Clean Identity VIN Rebirth & Framework Registration
--    INV-P7-10: 100% Parameterized SQL & Fail-Closed DB Seams
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[rebuilding_gate/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[rebuilding_gate/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local PC = dofile('shared/compatibility.lua')
    local Refurb = dofile('server/logistics/refurbishment.lua')
    local Rebuild = dofile('server/assembly/rebuild.lua')
    local VIN = dofile('server/assembly/vin_rebirth.lua')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-01: Engine Family Compatibility
    -- ═══════════════════════════════════════════════════════════════════════════
    -- V8 engine can fit into Muscle and Sports
    local v8Part = { partType = 'adv_engine', sourceModel = 'banshee', vehicleClass = 7 }
    local fitV8inMuscle, r1 = PC.CanFit('adv_engine', v8Part, 'dominator', 4)
    check('INV-P7-01a V8 engine fits in muscle car (Dominator)', fitV8inMuscle == true and r1 == 'engine_compatible')

    local fitV8inCompact, r2 = PC.CanFit('adv_engine', v8Part, 'blista', 0)
    check('INV-P7-01b V8 engine rejected in compact car (Blista)', fitV8inCompact == false and r2:find('incompatible_engine_family') ~= nil)

    local i4Part = { partType = 'adv_engine', sourceModel = 'blista', vehicleClass = 0 }
    local fitI4inBlista, r3 = PC.CanFit('adv_engine', i4Part, 'blista', 0)
    check('INV-P7-01c I4 compact engine fits in compact car', fitI4inBlista == true and r3 == 'engine_compatible')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-02: Cross-Class Chassis & Body Component Restrictions
    -- ═══════════════════════════════════════════════════════════════════════════
    -- Tyres in motorcycles
    local fitTyreBike, rTyre = PC.CanFit('chopshop_tyre', {}, 'sanchez', 8)
    check('INV-P7-02a Car tyre rejected on motorcycle', fitTyreBike == false and rTyre == 'incompatible_tyre_for_bike_class')

    -- Doors cross class
    local suvDoor = { partType = 'door_dside_f', sourceModel = 'baller', vehicleClass = 2 }
    local fitDoorCompact, rDoor = PC.CanFit('door_dside_f', suvDoor, 'blista', 0)
    check('INV-P7-02b SUV door rejected on compact chassis', fitDoorCompact == false and rDoor == 'panel_class_mismatch')

    -- Catalytic converter on bicycle
    local fitCatBicycle, rCat = PC.CanFit('catalytic_converter', {}, 'bmx', 13)
    check('INV-P7-02c Catalytic converter rejected on bicycle', fitCatBicycle == false and rCat == 'exhaust_unsupported_vehicle_type')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-03: Refurbishment Recipe & Atomic Material Consumption
    -- ═══════════════════════════════════════════════════════════════════════════
    local partStoreRefurb = {
        ['PART-DMG-01'] = {
            partId = 'PART-DMG-01',
            partType = 'adv_engine',
            conditionPct = 40.0,
            legalState = 'stolen',
        }
    }
    local invItems = { steel = 10, metalscrap = 15, copper = 5 }
    local removedMaterials = {}

    _G.PhysicalPart = {
        Get = function(id) return partStoreRefurb[id] end,
        UpdateState = function(id, updates)
            if partStoreRefurb[id] then
                for k, v in pairs(updates) do
                    partStoreRefurb[id][k] = v
                end
                return true
            end
            return false
        end,
    }

    local origInvCount = _G.InvCount
    local origInvRemove = _G.InvRemove

    _G.InvCount = function(src, item)
        return invItems[item] or 0
    end
    _G.InvRemove = function(src, item, count)
        removedMaterials[item] = (removedMaterials[item] or 0) + count
        invItems[item] = (invItems[item] or 0) - count
        return true
    end

    local refurbRes = Refurb.RefurbishPart(1, 'PART-DMG-01')
    check('INV-P7-03a RefurbishPart succeeds when materials available', refurbRes.ok == true)
    check('INV-P7-03b Steel consumed according to recipe (4 units)', removedMaterials['steel'] == 4)
    check('INV-P7-03c Metalscrap consumed according to recipe (8 units)', removedMaterials['metalscrap'] == 8)
    check('INV-P7-03d Part condition elevated to exactly 98.0%', partStoreRefurb['PART-DMG-01'].conditionPct == 98.0)
    check('INV-P7-03e Part legalState transitioned to refurbished', partStoreRefurb['PART-DMG-01'].legalState == 'refurbished')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-04: Optimal Condition Guard
    -- ═══════════════════════════════════════════════════════════════════════════
    partStoreRefurb['PART-PERFECT'] = {
        partId = 'PART-PERFECT',
        partType = 'adv_engine',
        conditionPct = 99.0,
        legalState = 'refurbished',
    }
    local rejectPristine = Refurb.RefurbishPart(1, 'PART-PERFECT')
    check('INV-P7-04a Part with condition >= target is rejected', rejectPristine.ok == false and rejectPristine.err == 'already_optimal_condition')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-05: Rebuild Project Exclusivity & Concurrency Locking
    -- ═══════════════════════════════════════════════════════════════════════════
    local projectsDb = {}
    local pIdCounter = 200

    local mockDb = {
        query = { await = function(q, p) return {} end },
        insert = {
            await = function(q, p)
                local id = pIdCounter
                pIdCounter = pIdCounter + 1
                projectsDb[id] = {
                    project_id = id,
                    owner_key = p[1],
                    chassis_model = p[2],
                    chassis_serial = p[3],
                    status = 'in_progress',
                    installed_parts = '{}',
                }
                return id
            end
        },
        single = {
            await = function(q, p)
                local pKey = p[1]
                for _, row in pairs(projectsDb) do
                    if row.owner_key == pKey and row.status == 'in_progress' then
                        return {
                            project_id = row.project_id,
                            owner_key = row.owner_key,
                            chassis_model = row.chassis_model,
                            chassis_serial = row.chassis_serial,
                            status = row.status,
                            installed_parts = row.installed_parts,
                            created_at_ts = os.time(),
                        }
                    end
                end
                return nil
            end
        },
        update = {
            await = function(q, p)
                if q:find('`installed_parts`') then
                    local pId = p[2]
                    if projectsDb[pId] then
                        projectsDb[pId].installed_parts = p[1]
                        return 1
                    end
                elseif q:find("SET `status` = 'completed'") then
                    local pId = p[1]
                    if projectsDb[pId] and projectsDb[pId].status == 'in_progress' then
                        projectsDb[pId].status = 'completed'
                        return 1
                    end
                end
                return 0
            end
        }
    }

    Rebuild.Init(mockDb, os.time)
    local origPlayerKey = _G.ServerChopPlayerKey
    _G.ServerChopPlayerKey = function(src) return 'citizen_owner_' .. tostring(src) end

    local p1 = Rebuild.StartProject(1, 'sultanrs', 'SERIAL-CHAS-1')
    check('INV-P7-05a Project 1 created for citizen_owner_1', p1.ok == true and p1.projectId == 200)

    local p1Dup = Rebuild.StartProject(1, 'banshee', 'SERIAL-CHAS-2')
    check('INV-P7-05b Duplicate project for citizen_owner_1 rejected', p1Dup.ok == false and p1Dup.err == 'project_already_in_progress')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-06: Quality Gate Thresholds on Component Installation
    -- ═══════════════════════════════════════════════════════════════════════════
    local partsInventory = {
        ['ENG-SUBPAR'] = {
            partId = 'ENG-SUBPAR',
            partType = 'adv_engine',
            serial = 'ENG-SUB',
            conditionPct = 65.0, -- abaixo de 70.0
            legalState = 'refurbished',
            ownerKey = 'citizen_owner_1',
            sourceModel = 'sultanrs',
            vehicleClass = 7,
            installedVehicleId = false,
        },
        ['ENG-GOOD'] = {
            partId = 'ENG-GOOD',
            partType = 'adv_engine',
            serial = 'ENG-GOOD',
            conditionPct = 85.0, -- acima de 70.0
            legalState = 'refurbished',
            ownerKey = 'citizen_owner_1',
            sourceModel = 'sultanrs',
            vehicleClass = 7,
            installedVehicleId = false,
        },
    }

    local consumedLog = {}
    _G.PhysicalPart = {
        Get = function(id) return partsInventory[id] end,
        UpdateState = function(id, updates)
            if partsInventory[id] then
                for k, v in pairs(updates) do partsInventory[id][k] = v end
                return true
            end
            return false
        end,
        Consume = function(id, reason)
            consumedLog[id] = reason
            return true
        end,
    }

    local subParRes = Rebuild.InstallPart(200, 1, 'adv_engine', 'ENG-SUBPAR')
    check('INV-P7-06a Engine below 70.0% rejected at installation', subParRes.ok == false and subParRes.err == 'insufficient_condition')

    local goodRes = Rebuild.InstallPart(200, 1, 'adv_engine', 'ENG-GOOD')
    check('INV-P7-06b Engine above 70.0% successfully installed', goodRes.ok == true and goodRes.slot == 'adv_engine')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-07: Physical Part Locking to Project
    -- ═══════════════════════════════════════════════════════════════════════════
    check('INV-P7-07a Installed part is marked installedVehicleId = 200', partsInventory['ENG-GOOD'].installedVehicleId == 200)

    -- Tentativa de instalar em outro projeto enquanto já acoplada
    local reInstall = Rebuild.InstallPart(200, 1, 'bonnet', 'ENG-GOOD')
    check('INV-P7-07b Already installed part cannot be reused elsewhere', reInstall.ok == false and reInstall.err == 'part_already_installed_in_vehicle')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-08: Anti-Dupe Terminal Destruction on Vehicle Finalization
    -- ═══════════════════════════════════════════════════════════════════════════
    local slots = {
        'catalytic_converter', 'door_dside_f', 'door_pside_f',
        'bonnet', 'boot', 'tyre_lf', 'tyre_rf', 'tyre_lr', 'tyre_rr'
    }
    for _, s in ipairs(slots) do
        local pid = 'PART-' .. s:upper()
        partsInventory[pid] = {
            partId = pid,
            partType = s,
            serial = 'SER-' .. s,
            conditionPct = 80.0,
            legalState = 'clean',
            ownerKey = 'citizen_owner_1',
            sourceModel = 'sultanrs',
            vehicleClass = 7,
            installedVehicleId = false,
        }
        local iRes = Rebuild.InstallPart(200, 1, s, pid)
        assert(iRes.ok == true, 'Install failed for slot: ' .. s)
    end

    _G.BridgeRegisterCivilVehicle = function(cid, model, plate, vin, props)
        return true, nil, 99
    end

    local finRes = Rebuild.FinalizeAssembly(200, 1)
    check('INV-P7-08a FinalizeAssembly completes project 200', finRes.ok == true and finRes.completed == true)
    check('INV-P7-08b Engine is destroyed in terminal anti-dupe consume', consumedLog['ENG-GOOD'] ~= nil)
    local allSlotsConsumed = true
    for _, s in ipairs(slots) do
        local pid = 'PART-' .. s:upper()
        if not consumedLog[pid] then allSlotsConsumed = false end
    end
    check('INV-P7-08c All other 9 installed components terminal consumed', allSlotsConsumed == true)

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-09: Clean Identity VIN Rebirth & Framework Registration
    -- ═══════════════════════════════════════════════════════════════════════════
    local cleanPlate = VIN.GenerateCleanPlate()
    check('INV-P7-09a Generated clean plate is exactly 8 alphanumeric characters', type(cleanPlate) == 'string' and #cleanPlate == 8)
    check('INV-P7-09b Generated plate has no ambiguous characters (no 0, O, 1, I)', cleanPlate:match('[0O1I]') == nil)

    local cleanVin = VIN.GenerateCleanVIN()
    check('INV-P7-09c Generated clean VIN is exactly 17 characters', type(cleanVin) == 'string' and #cleanVin == 17)
    check('INV-P7-09d Generated clean VIN starts with configured prefix 1G4VP', cleanVin:sub(1, 5) == '1G4VP')

    -- ═══════════════════════════════════════════════════════════════════════════
    --  INV-P7-10: 100% Parameterized SQL & Fail-Closed DB Seams
    -- ═══════════════════════════════════════════════════════════════════════════
    local origMySQL = _G.MySQL
    _G.MySQL = nil
    Rebuild.Init(false)
    local notReadyRes = Rebuild.StartProject(1, 'sultanrs', 'CHAS-FAIL')
    check('INV-P7-10a Rebuild fails closed when DB is uninitialized/unavailable', notReadyRes.ok == false and notReadyRes.err == 'db_not_ready')
    _G.MySQL = origMySQL

    -- Teardown
    _G.InvCount = origInvCount
    _G.InvRemove = origInvRemove
    _G.PhysicalPart = nil
    _G.ServerChopPlayerKey = origPlayerKey
    _G.BridgeRegisterCivilVehicle = nil

    print(('─── RESUMO REBUILDING RELEASE GATE: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('rebuilding_release_gate_spec failed: %d assertions failed'):format(fail))
end

run()
