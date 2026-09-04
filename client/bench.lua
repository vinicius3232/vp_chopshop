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
-- [FIX-1.3] PEÇA POSICIONADA NA BANCADA — 1 por bancada, prop na superfície.
-- Fluxo: carregar peça nos braços → "Colocar peça na bancada" → prop fica na
-- bancada e as ações (desmanchar / limpar serial / desmontar catalisador)
-- passam a aparecer. Ao terminar (ou com ALT) o jogador pega a peça de volta.
-- Estado só client-side espelhando o server (_benchParts). Some no restart.
-- ─────────────────────────────────────────────────────────────────────────────
BenchPartProps = BenchPartProps or {}  ---@type table<number, { prop:integer, partKey:string, entitlementId:string }>

--- Coloca o prop da peça em cima da bancada (superfície ~= topo do prop da bancada).
local function spawnBenchSurfaceProp(benchId, partKey)
    local benchEnt = BenchEntities[benchId]
    if not benchEnt or not DoesEntityExist(benchEnt) then return nil end
    local pCfg = (Config.PhysicalCarry and Config.PhysicalCarry.Props and Config.PhysicalCarry.Props[partKey])
    local model = pCfg and pCfg.model
    if not model then return nil end
    local hash = type(model) == 'number' and model or GetHashKey(model)
    RequestModel(hash)
    local t0 = GetGameTimer()
    while not HasModelLoaded(hash) and (GetGameTimer() - t0 < 3000) do Wait(20) end
    if not HasModelLoaded(hash) then return nil end

    -- topo da bancada = coords + max.z do bounding box do modelo (robusto a origem
    -- no centro ou na base do prop). Pequeno recuo p/ trás p/ sentar sobre a mesa.
    local _, maxDim = GetModelDimensions(GetEntityModel(benchEnt))
    local topZ = (maxDim and maxDim.z) or 0.9
    local bc  = GetEntityCoords(benchEnt)
    local fwd = GetEntityForwardVector(benchEnt)
    local pos = vector3(bc.x - fwd.x * 0.10, bc.y - fwd.y * 0.10, bc.z + topZ + 0.04)

    local prop = CreateObject(hash, pos.x, pos.y, pos.z, true, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not prop or prop == 0 then return nil end
    SetEntityHeading(prop, GetEntityHeading(benchEnt))
    SetEntityCoordsNoOffset(prop, pos.x, pos.y, pos.z, false, false, false)
    FreezeEntityPosition(prop, true)
    SetEntityCollision(prop, false, false)
    SetEntityAsMissionEntity(prop, true, true)
    return prop
end

local function clearBenchPart(benchId)
    local slot = BenchPartProps[benchId]
    if slot and slot.prop and DoesEntityExist(slot.prop) then
        DeleteEntity(slot.prop)
    end
    BenchPartProps[benchId] = nil
end

--- "Colocar peça na bancada": tira dos braços e posiciona o prop na bancada.
local function placePartOnBench(benchId)
    if not (VPChopCarryingPart and VPChopCarryingPart.isPart and VPChopCarryingPart.entitlementId) then
        VPChopNotify(L('notify_generic_error'), 'error'); return
    end
    if BenchPartProps[benchId] then
        VPChopNotify(L('bench_occupied'), 'error'); return
    end
    local partKey = VPChopCarryingPart.partKey
    local entId   = VPChopCarryingPart.entitlementId
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:bench:placePart', false, benchId, entId)
    if not cbOk or not res or not res.ok then
        VPChopNotify(VPChopLocaleErr(res and res.err) or L('notify_generic_error'), 'error'); return
    end
    VPChopDropCarryPart()  -- limpa braços + prop da mão
    local prop = spawnBenchSurfaceProp(benchId, partKey)
    BenchPartProps[benchId] = { prop = prop, partKey = partKey, entitlementId = entId }
    VPChopNotify(L('bench_part_placed'), 'inform')
end

--- "Pegar peça da bancada" (menu ou ALT): volta pros braços.
local function takePartFromBench(benchId)
    local slot = BenchPartProps[benchId]
    if not slot then return end
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:bench:takePart', false, benchId)
    if not cbOk or not res or not res.ok then
        VPChopNotify(VPChopLocaleErr(res and res.err) or L('notify_generic_error'), 'error'); return
    end
    clearBenchPart(benchId)
    if _G.VPChopSpawnCarriedPartInHands then
        _G.VPChopSpawnCarriedPartInHands(res.partKey, nil, res.entitlementId)
    end
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

--- [PR-4] Prop de marreta na mão durante o desmonte. Retorna o handle (ou nil).
local function spawnHammerProp()
    local cfg = ((Config.PhysicalCarry or {}).Teardown or {}).HammerProp
    if type(cfg) ~= 'table' or not cfg.model then return nil end
    local model = cfg.model
    if type(IsModelInCdimage) == 'function' and not IsModelInCdimage(model) then return nil end
    local hash = type(model) == 'number' and model or GetHashKey(model)
    RequestModel(hash)
    local t0 = GetGameTimer()
    while not HasModelLoaded(hash) and (GetGameTimer() - t0 < 1500) do Wait(20) end
    if not HasModelLoaded(hash) then return nil end
    local ped  = PlayerPedId()
    local pos  = GetEntityCoords(ped)
    local prop = CreateObject(hash, pos.x, pos.y, pos.z, true, true, false)
    SetModelAsNoLongerNeeded(hash)
    if not prop or prop == 0 then return nil end
    SetEntityAsMissionEntity(prop, true, true)
    local off = cfg.offset   or { 0.10, 0.02, 0.0 }
    local rot = cfg.rotation or { 0, 0, 0 }
    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, 28422),
        off[1], off[2], off[3], rot[1], rot[2], rot[3], true, true, false, true, 1, true)
    return prop
end

--- [PR-4] Desmonte na marreta antes de processar a peça roubada (profile
--- bench_teardown, primitive 'strike'). Retorna true se pode seguir para o
--- benchProcessPart, + o token server-side (nil no fluxo legacy/isento).
---@return boolean ok, string|nil token
local function runTeardownGate(benchId, partKey, entId, benchProp)
    local td = (Config.PhysicalCarry or {}).Teardown
    if not td or td.Enable == false then return true, nil end
    if td.ExemptParts and td.ExemptParts[partKey] then return true, nil end

    local hammerItem = td.HammerItem or 'hammer'
    if (exports.ox_inventory:Search('count', hammerItem) or 0) < 1 then
        VPChopNotify(L('bench_teardown_no_hammer'), 'error')
        return false, nil
    end

    local sOk, st = pcall(lib.callback.await, 'vp_chopshop:bench:teardownStart', false, benchId, entId)
    if not sOk or not st or not st.ok then
        VPChopNotify(VPChopLocaleErr(st and st.err) or L('notify_generic_error'), 'error')
        return false, nil
    end

    local minMs = tonumber(st.minDurationMs) or 5000
    local startMs = GetGameTimer()
    local prop = spawnHammerProp()

    -- [FIX-1.3] profile por peça (catalisador usa 'bench_catalytic'); fallback: td.Profile
    local profileName = (td.PartProfiles and td.PartProfiles[partKey]) or td.Profile or 'bench_teardown'

    -- [FIX-1.3] âncora do minigame = prop da peça NA BANCADA (câmera de trabalho na
    -- superfície), com fallback pro ped se o prop não existir.
    local anchor = (benchProp and DoesEntityExist(benchProp)) and benchProp or cache.ped

    local done
    if VPChopDismantleMinigame and VPChopDismantleMinigame.Start then
        done = VPChopDismantleMinigame.Start(anchor, profileName, {
            timeout = minMs + 20000,
            anim    = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
        })
    else
        done = lib.progressBar({
            duration = minMs, label = L('bench_processing_part'), useWhileDead = false,
            canCancel = true, disable = { move = true, car = true, combat = true },
            anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
        })
    end

    if prop and DoesEntityExist(prop) then DetachEntity(prop, true, true); DeleteEntity(prop) end

    if not done then
        pcall(lib.callback.await, 'vp_chopshop:bench:teardownCancel', false, st.token)
        return false, nil
    end

    -- [SEC] o server rejeita 'too_fast' abaixo de minDurationMs — espera o restante.
    local elapsed = GetGameTimer() - startMs
    if elapsed < minMs then Wait(minMs - elapsed + 150) end
    return true, st.token
end

local function executeBenchPartMode(benchId, mode)
    -- [FIX-1.3] opera sobre a peça POSICIONADA na bancada (não mais nos braços).
    local slot = BenchPartProps[benchId]
    if not slot or not slot.entitlementId then
        VPChopNotify(L('bench_no_part_placed'), 'error')
        return
    end
    local entId   = slot.entitlementId
    local partKey = slot.partKey

    local gateOk, teardownToken = runTeardownGate(benchId, partKey, entId, slot.prop)
    if not gateOk then return end

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

    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:benchProcessPart', false, benchId, entId, mode, teardownToken)
    if not cbOk or not res or not res.ok then
        VPChopNotify(VPChopLocaleErr(res and res.err) or L('notify_generic_error'), 'error')
        return
    end

    clearBenchPart(benchId)  -- peça consumida → some da bancada
    VPChopNotify(L('bench_part_processed'), 'success')
end

local function doProcessCarriedPartOnBench(benchId)
    local slot = BenchPartProps[benchId]
    if not slot then
        VPChopNotify(L('bench_no_part_placed'), 'error'); return
    end
    local partKey = slot.partKey

    -- [FIX-1.3] Catalisador: opção própria de desmonte na bancada (minigame de
    -- flange + marreta via runTeardownGate) antes de reciclar em matérias-primas.
    if partKey == 'catalytic_converter' then
        lib.registerContext({
            id = 'vp_chop_bench_catalytic_menu',
            title = L('bench_process_part'),
            options = {
                {
                    title = L('bench_opt_catalytic_dismantle'),
                    description = L('bench_desc_catalytic_dismantle'),
                    icon = 'fa-solid fa-fire-flame-curved',
                    onSelect = function()
                        executeBenchPartMode(benchId, 'raw_materials')
                    end,
                },
            },
        })
        lib.showContext('vp_chop_bench_catalytic_menu')
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

--- [FIX-1.3] "Acessar bancada" — utilidades que NÃO dependem de peça na bancada.
local function openBenchAccessMenu(benchId)
    local options = {}

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
        id = 'vp_chop_bench_access_' .. tostring(benchId),
        title = L('bench_menu_access') or 'Acessar Bancada',
        options = options,
    })
    lib.showContext('vp_chop_bench_access_' .. tostring(benchId))
end

--- [FIX-1.3] Menu topo: ações da peça (só com peça na bancada) + colocar + acessar.
local function openBenchMainMenu(benchId)
    local options = {}
    local slot = BenchPartProps[benchId]

    if slot then
        options[#options + 1] = {
            title = L('bench_process_part'),
            description = L('bench_process_part_desc') or 'Desmanchar / limpar serial / desmontar a peça na bancada',
            icon = 'fa-solid fa-recycle',
            iconColor = '#48bb78',
            onSelect = function() doProcessCarriedPartOnBench(benchId) end,
        }
        options[#options + 1] = {
            title = L('bench_take_part'),
            description = L('bench_take_part_desc') or 'Pegar a peça de volta para os braços',
            icon = 'fa-solid fa-hand-holding',
            onSelect = function() takePartFromBench(benchId) end,
        }
    elseif VPChopCarryingPart and VPChopCarryingPart.isPart then
        options[#options + 1] = {
            title = L('bench_place_part'),
            description = L('bench_place_part_desc') or 'Pôr a peça que você carrega em cima da bancada',
            icon = 'fa-solid fa-download',
            iconColor = '#48bb78',
            onSelect = function() placePartOnBench(benchId) end,
        }
    end

    options[#options + 1] = {
        title = L('bench_menu_access') or 'Acessar Bancada',
        description = L('bench_menu_access_desc') or 'Fabricar, gerenciar séries de inventário, recolher',
        icon = 'fa-solid fa-toolbox',
        onSelect = function() openBenchAccessMenu(benchId) end,
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

    -- [FIX-1.3] Uma opção só: a bancada. O menu decide o que mostrar (colocar peça /
    -- ações da peça / acessar). "Pegar peça" também via ALT (thread abaixo).
    exports.ox_target:addLocalEntity(ent, {
        {
            name = ('vp_chop_bench_menu_%s'):format(bench.id),
            label = L('bench_menu_title') or 'Bancada de Trabalho',
            icon = 'fa-solid fa-toolbox',
            distance = Config.InteractDistance,
            canInteract = function()
                return GetVehiclePedIsIn(cache.ped, false) == 0
            end,
            onSelect = function()
                openBenchMainMenu(bench.id)
            end,
        },
    })
end

-- [FIX-1.3] ALT (control 19) perto de uma bancada com peça → pega a peça de volta.
CreateThread(function()
    local altShown = false
    local function hideAlt() if altShown then lib.hideTextUI(); altShown = false end end
    while true do
        local wait = 800
        local occupied
        for id, slot in pairs(BenchPartProps) do
            if slot and slot.prop and DoesEntityExist(slot.prop) then occupied = id; break end
        end
        local near = false
        if occupied and not (VPChopCarryingPart and VPChopCarryingPart.isPart)
            and GetVehiclePedIsIn(cache.ped, false) == 0 then
            local prop = BenchPartProps[occupied].prop
            near = #(GetEntityCoords(cache.ped) - GetEntityCoords(prop)) < 2.2
        end
        if near then
            wait = 0
            if not altShown then
                lib.showTextUI('[ALT] ' .. (L('bench_take_part') or 'Pegar peça'), { position = 'left-center', icon = 'hand-holding' })
                altShown = true
            end
            if IsControlJustReleased(0, 19) then  -- INPUT_CHARACTER_WHEEL (Left Alt)
                hideAlt()
                takePartFromBench(occupied)
                wait = 500
            end
        else
            hideAlt()
        end
        Wait(wait)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(BenchPartProps) do clearBenchPart(id) end
end)

function VPChopRemoveBench(id)
    clearBench(id)
end
