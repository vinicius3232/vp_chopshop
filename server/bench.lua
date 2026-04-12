---@param bench table
---@param src number
---@param recipeIndex integer
---@return boolean ok
---@return string|nil err
function VPChopServerTryBenchRecipe(bench, src, recipeIndex)
    local recipe = Config.BenchRecipes[recipeIndex]
    if not recipe then return false, 'recipe' end
    if not ValidatePlayerNearCoords(src, bench.coords) then return false, 'distance' end

    for itemName, need in pairs(recipe.inputs) do
        if InvCount(src, itemName) < need then return false, 'inputs' end
    end

    -- Rastreia cada item removido para rollback atômico em caso de falha parcial
    local removed = {}
    for itemName, need in pairs(recipe.inputs) do
        if not InvRemove(src, itemName, need) then
            for rName, rAmt in pairs(removed) do InvAdd(src, rName, rAmt) end
            return false, 'remove'
        end
        removed[itemName] = need
    end

    -- Rastreia cada output adicionado; reverte inputs E outputs em caso de falha
    local added = {}
    for itemName, give in pairs(recipe.outputs) do
        if not InvAdd(src, itemName, give) then
            for aName, aAmt in pairs(added) do InvRemove(src, aName, aAmt) end
            for rName, rAmt in pairs(removed) do InvAdd(src, rName, rAmt) end
            return false, 'give'
        end
        added[itemName] = give
    end

    return true, nil
end
