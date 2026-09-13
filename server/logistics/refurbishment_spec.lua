-- server/logistics/refurbishment_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.21 P7.3] PART REFURBISHMENT SPEC SUITE
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[refurb/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[refurb/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local Refurb = dofile('server/logistics/refurbishment.lua')

    -- ─── 1. Recipe Lookup ───────────────────────────────────────────────────────
    local engRecipe = Refurb.GetRecipe('adv_engine')
    check('REFURB-RECIPE-01 Retrieves recipe for adv_engine', engRecipe ~= nil and engRecipe.materials.steel == 4 and engRecipe.materials.metalscrap == 8)

    local doorRecipe = Refurb.GetRecipe('door_dside_f')
    check('REFURB-RECIPE-02 Retrieves normalized recipe for door_dside_f', doorRecipe ~= nil and doorRecipe.materials.steel == 3)

    local invalidRecipe = Refurb.GetRecipe('unknown_gyro')
    check('REFURB-RECIPE-03 Returns nil for unregistered part type', invalidRecipe == nil)

    -- ─── 2. Refurbishment Execution ─────────────────────────────────────────────
    local partStore = {
        ['ENG-BEATEN'] = {
            partId = 'ENG-BEATEN',
            partType = 'adv_engine',
            conditionPct = 45.0,
            legalState = 'stolen',
        },
        ['ENG-PRISTINE'] = {
            partId = 'ENG-PRISTINE',
            partType = 'adv_engine',
            conditionPct = 99.0,
            legalState = 'stolen',
        },
    }

    local updatedState = {}
    _G.PhysicalPart = {
        Get = function(id) return partStore[id] end,
        UpdateState = function(id, updates)
            updatedState[id] = updates
            if partStore[id] then
                for k, v in pairs(updates) do
                    partStore[id][k] = v
                end
            end
            return true
        end
    }

    -- Tentar retificar peça já perfeita
    local pristRes = Refurb.RefurbishPart(1, 'ENG-PRISTINE')
    check('REFURB-EXEC-01 Rejects refurbishment for already optimal part', pristRes.ok == false and pristRes.err == 'already_optimal_condition')

    -- Mock de inventário com materiais faltando
    local inventory = { steel = 1, metalscrap = 2, copper = 0 }
    local origInvCount = _G.InvCount
    local origInvRemove = _G.InvRemove

    _G.InvCount = function(src, item)
        return inventory[item] or 0
    end
    _G.InvRemove = function(src, item, count)
        if (inventory[item] or 0) >= count then
            inventory[item] = inventory[item] - count
            return true
        end
        return false
    end

    local missingRes = Refurb.RefurbishPart(1, 'ENG-BEATEN')
    check('REFURB-EXEC-02 Rejects refurbishment when materials are missing', missingRes.ok == false and missingRes.err == 'missing_materials')

    -- Abastecer inventário com os materiais necessários (steel=4, metalscrap=8, copper=2)
    inventory.steel = 10
    inventory.metalscrap = 20
    inventory.copper = 10

    local okRefurb = Refurb.RefurbishPart(1, 'ENG-BEATEN')
    check('REFURB-EXEC-03 Refurbishment succeeds with complete materials', okRefurb.ok == true and okRefurb.newCondition == 98.0 and okRefurb.legalState == 'refurbished')
    check('REFURB-EXEC-04 Part condition updated to 98% in storage', partStore['ENG-BEATEN'].conditionPct == 98.0)
    check('REFURB-EXEC-05 Part legal state updated to refurbished in storage', partStore['ENG-BEATEN'].legalState == 'refurbished')

    -- Teardown
    _G.InvCount = origInvCount
    _G.InvRemove = origInvRemove
    _G.PhysicalPart = nil

    print(('─── RESUMO REFURBISHMENT: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('refurbishment_spec failed: %d assertions failed'):format(fail))
end

run()
