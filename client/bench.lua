BenchEntities = BenchEntities or {}

---@param recipe { labelKey?: string, label?: string }
---@return string
local function benchRecipeLabel(recipe)
    if recipe.labelKey then return L(recipe.labelKey) end
    return recipe.label or L('notify_generic_error')
end

local function clearBench(id)
    local ent = BenchEntities[id]
    if ent and DoesEntityExist(ent) then
        exports.ox_target:removeLocalEntity(ent)
        DeleteEntity(ent)
    end
    BenchEntities[id] = nil
end

local function deliverPartToBench(benchId)
    if not VPChopCarryingPart then
        VPChopNotify(L('notify_no_part_carrying'), 'error')
        return
    end
    local ok = lib.progressBar({
        duration     = 4000,
        label        = L('progress_delivering_part'),
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    })
    if not ok then return end
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:deliverPart', false, benchId)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopDropCarryPart()
        VPChopNotify(L('notify_part_delivered'), 'success')
    else
        VPChopNotify(
            (res and res.err) and L('notify_bench_fail_fmt', VPChopLocaleErr(res.err)) or L('notify_generic_error'),
            'error'
        )
    end
end

local function craftOnBench(benchId, recipeIndex, recipe)
    local ok = lib.progressBar({
        duration = recipe.duration or 8000,
        label = benchRecipeLabel(recipe),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    })
    if not ok then return end
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:benchCraft', false, benchId, recipeIndex)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopNotify(L('notify_bench_done'), 'success')
    else
        VPChopNotify(
            (res and res.err) and L('notify_bench_fail_fmt', VPChopLocaleErr(res.err)) or L('notify_generic_error'),
            'error'
        )
    end
end

---@param bench { id: integer, x: number, y: number, z: number, heading: number }
function VPChopUpsertBench(bench)
    clearBench(bench.id)

    local coords = vector3(bench.x, bench.y, bench.z)
    local model = Config.BenchModel
    lib.requestModel(model, 8000)
    local ent = CreateObject(model, coords.x, coords.y, coords.z + 1.0, false, false, false)
    if not ent or ent == 0 then
        SetModelAsNoLongerNeeded(model)
        return
    end
    SetEntityHeading(ent, bench.heading + 0.0)
    Wait(50)
    PlaceObjectOnGroundProperly(ent)
    FreezeEntityPosition(ent, true)
    SetEntityAsMissionEntity(ent, true, true)
    BenchEntities[bench.id] = ent
    SetModelAsNoLongerNeeded(model)

    local options = {}
    for index, recipe in ipairs(Config.BenchRecipes) do
        local idx = index
        options[#options + 1] = {
            name = ('vp_chop_bench_%s_%s'):format(bench.id, idx),
            label = benchRecipeLabel(recipe),
            icon = 'fa-solid fa-gears',
            distance = Config.InteractDistance,
            onSelect = function()
                craftOnBench(bench.id, idx, recipe)
            end,
        }
    end

    options[#options + 1] = {
        name = ('vp_chop_bench_deliver_%s'):format(bench.id),
        label = L('target_deliver_part'),
        icon = 'fa-solid fa-box-archive',
        distance = Config.InteractDistance,
        canInteract = function()
            return VPChopCarryingPart ~= nil
        end,
        onSelect = function()
            deliverPartToBench(bench.id)
        end,
    }

    options[#options + 1] = {
        name = ('vp_chop_bench_pickup_%s'):format(bench.id),
        label = L('target_pickup_bench'),
        icon = 'fa-solid fa-hand',
        distance = Config.InteractDistance,
        canInteract = function()
            return GetVehiclePedIsIn(PlayerPedId(), false) == 0
        end,
        onSelect = function()
            local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:pickupBench', false, bench.id)
            if not cbOk then res = nil end
            if res and res.ok then
                VPChopNotify(L('notify_installed'), 'success')
            else
                VPChopNotify(
                    (res and res.err) and L('notify_chop_failed_fmt', VPChopLocaleErr(res.err)) or L('notify_generic_error'),
                    'error'
                )
            end
        end,
    }

    exports.ox_target:addLocalEntity(ent, options)
end

function VPChopRemoveBench(id)
    clearBench(id)
end
