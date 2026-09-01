-- client/bench.lua
-- Bancada de desmanche / crafting: processamento de peças carregadas, forja de placas,
-- gerenciamento de séries e fabricação de insumos.
-- Expõe: VPChopUpsertBench(bench), VPChopRemoveBench(id), VPChopForgeFakePlate(benchId, plate)

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

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. FORJA DE PLACA FALSA
-- ─────────────────────────────────────────────────────────────────────────────

---@param benchId integer
---@param sourcePlate string|nil Placa-fonte escolhida (metadata da stolen_plate)
function VPChopForgeFakePlate(benchId, sourcePlate)
    local ok = lib.progressBar({
        duration = 8000,
        label = L('fake_plate_forge_progress'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    })
    if not ok then return end
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:forgeFakePlate', false, sourcePlate)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopNotify(L('fake_plate_forge_success'), 'success')
    else
        local errKey = ({
            tier      = 'fake_plate_forge_tier',
            inputs    = 'fake_plate_forge_inputs',
            no_source = 'fake_plate_forge_no_source',
            distance  = 'fake_plate_too_far',
            cooldown  = 'fake_plate_cooldown',
            inventory = 'fake_plate_forge_generic',
            remove    = 'fake_plate_forge_generic',
        })[(res and res.err) or ''] or 'fake_plate_forge_generic'
        VPChopNotify(L(errKey), 'error')
    end
end

local function openFakePlatePicker(benchId)
    local slots = exports.ox_inventory:Search('slots', 'stolen_plate')
    if type(slots) ~= 'table' or #slots == 0 then
        VPChopNotify(L('fake_plate_forge_no_source'), 'error')
        return
    end

    if #slots == 1 then
        local sourcePlate = slots[1].metadata and slots[1].metadata.plate
        VPChopForgeFakePlate(benchId, sourcePlate)
        return
    end

    local seen, menuOpts = {}, {}
    for i = 1, #slots do
        local pl = slots[i].metadata and slots[i].metadata.plate
        if pl and not seen[pl] then
            seen[pl] = true
            menuOpts[#menuOpts + 1] = {
                title = ('Placa: %s'):format(pl),
                description = 'Usar esta placa roubada como matriz',
                icon = 'fa-solid fa-car',
                onSelect = function()
                    VPChopForgeFakePlate(benchId, pl)
                end,
            }
        end
    end

    lib.registerContext({
        id = 'vp_chop_forge_fake_pick',
        title = L('fake_plate_forge_pick_title'),
        menu = 'vp_chop_bench_main_' .. tostring(benchId),
        options = menuOpts,
    })
    lib.showContext('vp_chop_forge_fake_pick')
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. FABRICAÇÃO / CRAFTING
-- ─────────────────────────────────────────────────────────────────────────────

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

local function openBenchCraftingMenu(benchId)
    local menuOpts = {}
    for index, recipe in ipairs(Config.BenchRecipes or {}) do
        local idx = index
        local inputsDesc = {}
        if recipe.inputs then
            for item, count in pairs(recipe.inputs) do
                inputsDesc[#inputsDesc + 1] = ('%dx %s'):format(count, item)
            end
        end

        menuOpts[#menuOpts + 1] = {
            title = benchRecipeLabel(recipe),
            description = #inputsDesc > 0 and ('Requer: %s'):format(table.concat(inputsDesc, ', ')) or nil,
            icon = 'fa-solid fa-hammer',
            onSelect = function()
                craftOnBench(benchId, idx, recipe)
            end,
        }
    end

    lib.registerContext({
        id = 'vp_chop_bench_crafting_' .. tostring(benchId),
        title = L('bench_menu_crafting_title') or 'Fabricar Ferramentas & Materiais',
        menu = 'vp_chop_bench_main_' .. tostring(benchId),
        options = menuOpts,
    })
    lib.showContext('vp_chop_bench_crafting_' .. tostring(benchId))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. GERENCIAMENTO DE SÉRIES (INVENTÁRIO)
-- ─────────────────────────────────────────────────────────────────────────────

local function openSerialManagementMenu(benchId)
    local menuOpts = {
        {
            title = L('serial_scratch_label'),
            description = 'Raspar e descaracterizar números de série de peças do inventário',
            icon = 'fa-solid fa-eraser',
            onSelect = function()
                if VPChopSerialDoScratch then
                    VPChopSerialDoScratch()
                end
            end,
        },
        {
            title = L('serial_forge_label'),
            description = 'Remarcar peças com novo número de série legítimo forjado',
            icon = 'fa-solid fa-stamp',
            onSelect = function()
                if VPChopSerialDoForge then
                    VPChopSerialDoForge()
                end
            end,
        },
    }

    lib.registerContext({
        id = 'vp_chop_bench_serial_' .. tostring(benchId),
        title = L('serial_menu_title') or 'Gerenciamento de Séries (Inventário)',
        menu = 'vp_chop_bench_main_' .. tostring(benchId),
        options = menuOpts,
    })
    lib.showContext('vp_chop_bench_serial_' .. tostring(benchId))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. PROCESSAMENTO DE PEÇA FÍSICA CARREGADA
-- ─────────────────────────────────────────────────────────────────────────────

local function executeBenchPartMode(benchId, mode)
    if not VPChopCarryingPart or not VPChopCarryingPart.isPart then return end
    local entId = VPChopCarryingPart.entitlementId
    if not entId then
        VPChopNotify(L('notify_generic_error'), 'error')
        return
    end

    local labels = {
        raw_materials = L('bench_progress_raw') or 'Desmanchando peça em matérias-primas...',
        clean_serial  = L('bench_progress_clean') or 'Raspando e limpando número de série...',
        stolen_serial = L('bench_progress_stolen') or 'Acondicionando peça com serial roubado...',
    }
    local ok = lib.progressBar({
        duration = 4000,
        label = labels[mode] or L('bench_processing_part'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    })
    if not ok then return end

    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:benchProcessPart', false, benchId, entId, mode)
    if not cbOk or not res or not res.ok then
        VPChopNotify(VPChopLocaleErr(res and res.err) or L('notify_generic_error'), 'error')
        return
    end

    VPChopDropCarryPart()
    VPChopNotify(L('bench_part_processed'), 'success')
end

local function doProcessCarriedPartOnBench(benchId)
    if not VPChopCarryingPart or not VPChopCarryingPart.isPart then return end
    local partKey = VPChopCarryingPart.partKey

    -- Catalisador tem fluxo direto de reciclagem em matérias-primas
    if partKey == 'catalytic_converter' then
        executeBenchPartMode(benchId, 'raw_materials')
        return
    end

    -- Menu unificado com as 3 opções claras para peças de lataria e motor
    lib.registerContext({
        id = 'vp_chop_bench_part_action_menu',
        title = L('bench_process_part'),
        options = {
            {
                title = L('bench_opt_raw_materials'),
                description = L('bench_desc_raw_materials'),
                icon = 'fa-solid fa-recycle',
                onSelect = function()
                    executeBenchPartMode(benchId, 'raw_materials')
                end,
            },
            {
                title = L('bench_opt_clean_serial'),
                description = L('bench_desc_clean_serial'),
                icon = 'fa-solid fa-spray-can-sparkles',
                onSelect = function()
                    executeBenchPartMode(benchId, 'clean_serial')
                end,
            },
            {
                title = L('bench_opt_stolen_serial'),
                description = L('bench_desc_stolen_serial'),
                icon = 'fa-solid fa-skull-crossbones',
                onSelect = function()
                    executeBenchPartMode(benchId, 'stolen_serial')
                end,
            },
        }
    })
    lib.showContext('vp_chop_bench_part_action_menu')
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. MENU PRINCIPAL UNIFICADO DA BANCADA
-- ─────────────────────────────────────────────────────────────────────────────

local function openBenchMainMenu(benchId)
    local options = {}

    -- Destaque se estiver carregando peça física
    if VPChopCarryingPart and VPChopCarryingPart.isPart then
        options[#options + 1] = {
            title = L('bench_process_part'),
            description = 'Desmanchar, limpar serial ou guardar a peça física que você está carregando',
            icon = 'fa-solid fa-recycle',
            iconColor = '#48bb78',
            onSelect = function()
                doProcessCarriedPartOnBench(benchId)
            end,
        }
    end

    -- Fabricação / Crafting
    if Config.BenchRecipes and #Config.BenchRecipes > 0 then
        options[#options + 1] = {
            title = L('bench_menu_crafting_title') or 'Fabricar Ferramentas & Materiais',
            description = L('bench_menu_crafting_desc') or 'Compactar sucata, separar cobre, montar kits e ferramentas',
            icon = 'fa-solid fa-gears',
            onSelect = function()
                openBenchCraftingMenu(benchId)
            end,
        }
    end

    -- Forja de Placas Falsas
    if Config.Plates and Config.Plates.Enable then
        local count = exports.ox_inventory:Search('count', 'stolen_plate') or 0
        if count and count > 0 then
            options[#options + 1] = {
                title = L('fake_plate_forge_label'),
                description = 'Forjar placa clonada a partir de uma placa roubada do inventário',
                icon = 'fa-solid fa-id-card-clip',
                onSelect = function()
                    openFakePlatePicker(benchId)
                end,
            }
        end
    end

    -- Gerenciamento de Séries (peças de inventário)
    if Config.PartSerial and Config.PartSerial.Enable then
        local countParts = exports.ox_inventory:Search('count', 'car_parts') or 0
        if countParts and countParts > 0 then
            options[#options + 1] = {
                title = L('serial_menu_title') or 'Gerenciamento de Séries (Inventário)',
                description = L('serial_menu_desc') or 'Raspar ou forjar números de série em peças do inventário',
                icon = 'fa-solid fa-stamp',
                onSelect = function()
                    openSerialManagementMenu(benchId)
                end,
            }
        end
    end

    -- Recolher Bancada
    options[#options + 1] = {
        title = L('target_pickup_bench'),
        description = 'Desmontar e recolher esta bancada de volta para o inventário',
        icon = 'fa-solid fa-hand',
        onSelect = function()
            local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:pickupBench', false, benchId)
            if not cbOk then res = nil end
            if res and res.ok then
                VPChopNotify(L('notify_installed'), 'success')
            else
                local errKey = ({
                    not_owner = 'err_pickup_not_owner',
                    has_parts = 'err_pickup_has_parts',
                })[(res and res.err) or ''] or 'notify_generic_error'
                VPChopNotify(L(errKey), 'error')
            end
        end,
    }

    lib.registerContext({
        id = 'vp_chop_bench_main_' .. tostring(benchId),
        title = L('bench_menu_title') or 'Bancada de Trabalho',
        options = options,
    })
    lib.showContext('vp_chop_bench_main_' .. tostring(benchId))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. OX_TARGET REGISTRATION
-- ─────────────────────────────────────────────────────────────────────────────

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

    -- 1. [PHYSICAL CARRY] Desmanchar peça que o jogador está carregando nos braços
    options[#options + 1] = {
        name = ('vp_chop_bench_process_part_%s'):format(bench.id),
        label = L('bench_process_part'),
        icon = 'fa-solid fa-recycle',
        distance = Config.InteractDistance,
        canInteract = function()
            if GetVehiclePedIsIn(cache.ped, false) ~= 0 then return false end
            return VPChopCarryingPart and VPChopCarryingPart.isPart == true
        end,
        onSelect = function()
            doProcessCarriedPartOnBench(bench.id)
        end,
    }

    -- 2. Menu Principal Unificado da Bancada
    options[#options + 1] = {
        name = ('vp_chop_bench_menu_%s'):format(bench.id),
        label = L('bench_menu_title') or 'Acessar Bancada',
        icon = 'fa-solid fa-toolbox',
        distance = Config.InteractDistance,
        canInteract = function()
            return GetVehiclePedIsIn(cache.ped, false) == 0
        end,
        onSelect = function()
            openBenchMainMenu(bench.id)
        end,
    }

    -- 3. Recolher Bancada (Acesso direto no target)
    options[#options + 1] = {
        name = ('vp_chop_bench_pickup_%s'):format(bench.id),
        label = L('target_pickup_bench'),
        icon = 'fa-solid fa-hand',
        distance = Config.InteractDistance,
        canInteract = function()
            return GetVehiclePedIsIn(cache.ped, false) == 0
        end,
        onSelect = function()
            local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:pickupBench', false, bench.id)
            if not cbOk then res = nil end
            if res and res.ok then
                VPChopNotify(L('notify_installed'), 'success')
            else
                local errKey = ({
                    not_owner = 'err_pickup_not_owner',
                    has_parts = 'err_pickup_has_parts',
                })[(res and res.err) or ''] or 'notify_generic_error'
                VPChopNotify(L(errKey), 'error')
            end
        end,
    }

    exports.ox_target:addLocalEntity(ent, options)
end

function VPChopRemoveBench(id)
    clearBench(id)
end
