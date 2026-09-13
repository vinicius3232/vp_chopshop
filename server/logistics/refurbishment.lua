-- server/logistics/refurbishment.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.21 P7.3] PART REFURBISHMENT & BENCH TEARDOWN V2
--  Processamento físico e retífica de componentes automotivos danificados
--  na bancada (chopshop_bench). Consome ferramentas e materiais nobres para
--  elevar a saúde da peça durável e transitar para o estado 'refurbished'.
-- ═══════════════════════════════════════════════════════════════════════════════

Refurbishment = Refurbishment or {}

local _mock = nil

local function getCfg()
    local cfg = Config and Config.Refurbishment
    if type(cfg) ~= 'table' then
        return {
            Enable = true,
            MinConditionToRepair = 10.0,
            TargetCondition = 98.0,
            ToolRequired = 'mechanic_drill',
            Materials = {
                adv_engine = { steel = 4, metalscrap = 8, copper = 2 },
                catalytic_converter = { steel = 2, copper = 4 },
                door = { steel = 3, metalscrap = 4 },
                bonnet = { steel = 3, metalscrap = 4 },
                boot = { steel = 3, metalscrap = 4 },
            }
        }
    end
    return cfg
end

--- Retorna a receita de materiais e ferramentas para retificar um componente
---@param partType string
---@return table? recipe
function Refurbishment.GetRecipe(partType)
    if not partType or type(partType) ~= 'string' then return nil end
    local cfg = getCfg()
    if not cfg.Materials then return nil end

    if cfg.Materials[partType] then
        return {
            tool = cfg.ToolRequired or 'mechanic_drill',
            materials = cfg.Materials[partType],
            targetCondition = cfg.TargetCondition or 98.0,
        }
    end

    -- Normalização para classes de portas
    if partType:find('^door_') and cfg.Materials.door then
        return {
            tool = cfg.ToolRequired or 'mechanic_drill',
            materials = cfg.Materials.door,
            targetCondition = cfg.TargetCondition or 98.0,
        }
    end

    return nil
end

--- Executa a retífica física de uma peça na bancada
---@param src number
---@param partId string
---@return table { ok: boolean, err?: string, newCondition?: number, legalState?: string }
function Refurbishment.RefurbishPart(src, partId)
    if not src or type(src) ~= 'number' or src <= 0 then
        return { ok = false, err = 'invalid_source' }
    end
    if not partId or type(partId) ~= 'string' or partId == '' then
        return { ok = false, err = 'invalid_part_id' }
    end

    if _mock and _mock.RefurbishPart then
        return _mock.RefurbishPart(src, partId)
    end

    local cfg = getCfg()
    if cfg.Enable == false then
        return { ok = false, err = 'refurbishment_disabled' }
    end

    local PP = rawget(_G, 'PhysicalPart')
    if not PP or not PP.Get then
        return { ok = false, err = 'physical_part_bridge_missing' }
    end

    local part = PP.Get(partId)
    if not part then
        return { ok = false, err = 'part_not_found' }
    end

    local targetCond = cfg.TargetCondition or 98.0
    if (part.conditionPct or 0) >= targetCond then
        return { ok = false, err = 'already_optimal_condition' }
    end

    local recipe = Refurbishment.GetRecipe(part.partType)
    if not recipe then
        return { ok = false, err = 'no_recipe_for_part' }
    end

    -- Validação e consumo de inventário via bridge canônica (InvCount / InvRemove)
    local invCountFn = (type(InvCount) == 'function' and InvCount) or (exports and exports.ox_inventory and function(s, i) return exports.ox_inventory:GetItemCount(s, i) end)
    local invRemoveFn = (type(InvRemove) == 'function' and InvRemove) or (exports and exports.ox_inventory and function(s, i, c) return exports.ox_inventory:RemoveItem(s, i, c) end)

    if invCountFn and invRemoveFn then
        -- 1. Checa materiais
        for matItem, matCount in pairs(recipe.materials) do
            local has = invCountFn(src, matItem) or 0
            if has < matCount then
                return { ok = false, err = 'missing_materials', item = matItem, needed = matCount }
            end
        end

        -- 2. Consome materiais
        for matItem, matCount in pairs(recipe.materials) do
            local removed = invRemoveFn(src, matItem, matCount)
            if removed == false then
                return { ok = false, err = 'failed_to_remove_materials', item = matItem }
            end
        end
    end

    -- Atualiza estado da peça no banco de dados para 'refurbished' e eleva condição
    local updated = PP.UpdateState(partId, {
        conditionPct = targetCond,
        legalState = 'refurbished',
    })

    if not updated then
        return { ok = false, err = 'update_state_failed' }
    end

    return {
        ok = true,
        partId = partId,
        newCondition = targetCond,
        legalState = 'refurbished',
    }
end

function Refurbishment.__setMock(mock)
    _mock = mock
end

return Refurbishment
