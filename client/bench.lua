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

-- [GAMEPLAY unificação] Função deliverPartToBench REMOVIDA.
-- A recompensa da Fase 1 agora cai no inventário na hora do desmanche; a bancada não
-- recebe mais peças. O carry prop (visual e necessário pro fluxo de pneu→truck) continua
-- spawnando após o chop — só o REWARD deixou de depender da bancada.

-- [FASE2 placas] Forja de placa falsa: barra de progresso + callback dedicado.
-- benchId é cosmético aqui (servidor valida proximidade de QUALQUER bancada); mantido por clareza.
---@param benchId integer
---@param sourcePlate string|nil  placa-fonte escolhida (metadata da stolen_plate)
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

local function doProcessCarriedPartOnBench(benchId)
    if not VPChopCarryingPart or not VPChopCarryingPart.isPart then return end
    local partKey = VPChopCarryingPart.partKey

    local ok = lib.progressBar({
        duration = 3500,
        label = L('bench_processing_part'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    })
    if not ok then return end

    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:benchProcessPart', false, benchId, partKey)
    if not cbOk or not res or not res.ok then
        VPChopNotify(L('notify_generic_error'), 'error')
        return
    end

    VPChopDropCarryPart()
    VPChopNotify(L('bench_part_processed'), 'success')
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

    -- [PHYSICAL CARRY] Desmanchar peça que o jogador está carregando nos braços
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

    -- [FASE2 placas] Forjar placa falsa — fluxo DEDICADO (não usa Config.BenchRecipes porque
    -- o output herda a placa do `stolen_plate` específico). Só aparece se a feature está on e
    -- o jogador carrega ao menos uma placa roubada. A verdade (tier, proximidade, insumos,
    -- metadata, cooldown) é toda validada no servidor (server/plates.lua).
    if Config.Plates and Config.Plates.Enable then
        options[#options + 1] = {
            name = ('vp_chop_bench_forge_fake_%s'):format(bench.id),
            label = L('fake_plate_forge_label'),
            icon = 'fa-solid fa-id-card-clip',
            distance = Config.InteractDistance,
            canInteract = function()
                if GetVehiclePedIsIn(cache.ped, false) ~= 0 then return false end
                -- UX: só oferece se houver placa roubada no inventário (servidor revalida)
                local count = exports.ox_inventory:Search('count', 'stolen_plate') or 0
                return count and count > 0
            end,
            onSelect = function()
                -- Se houver várias placas roubadas, deixar o jogador escolher a placa-fonte.
                local slots = exports.ox_inventory:Search('slots', 'stolen_plate')
                local sourcePlate = nil
                if type(slots) == 'table' and #slots > 0 then
                    if #slots == 1 then
                        sourcePlate = slots[1].metadata and slots[1].metadata.plate
                    else
                        -- Menu de seleção (ox_lib) entre as placas disponíveis.
                        local seen, menuOpts = {}, {}
                        for i = 1, #slots do
                            local pl = slots[i].metadata and slots[i].metadata.plate
                            if pl and not seen[pl] then
                                seen[pl] = true
                                menuOpts[#menuOpts + 1] = {
                                    title = pl,
                                    icon = 'fa-solid fa-car',
                                    onSelect = function()
                                        VPChopForgeFakePlate(bench.id, pl)
                                    end,
                                }
                            end
                        end
                        lib.registerContext({
                            id = 'vp_chop_forge_fake_pick',
                            title = L('fake_plate_forge_pick_title'),
                            options = menuOpts,
                        })
                        lib.showContext('vp_chop_forge_fake_pick')
                        return
                    end
                end
                VPChopForgeFakePlate(bench.id, sourcePlate)
            end,
        }
    end

    -- [SERIAL] Opções de série na bancada: "Riscar série" / "Forjar série". Só aparecem
    -- quando o servidor confirma elegibilidade (peça elegível + tier). A verdade está nos
    -- callbacks server (vp_chopshop:serial:scratch / :forge). VPChopSerialBenchOptions é
    -- definida em client/partserial.lua (carregado antes de main.lua → bench).
    if Config.PartSerial and Config.PartSerial.Enable and VPChopSerialBenchOptions then
        for _, opt in ipairs(VPChopSerialBenchOptions(bench.id)) do
            options[#options + 1] = opt
        end
    end

    -- [GAMEPLAY unificação] Target "entregar peça" REMOVIDO da bancada.
    -- A recompensa agora é imediata no desmanche; a bancada só faz craft (recipes acima)
    -- e pickup (abaixo). O fluxo de pneu→truck→fence NÃO usa a bancada e segue intacto.

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
