---@param src number
---@param item string
---@return integer
function InvCount(src, item)
    return exports.ox_inventory:GetItemCount(src, item) or 0
end

---@param src number
---@param item string
---@param count integer
---@return boolean
function InvRemove(src, item, count)
    if count < 1 then return false end
    return exports.ox_inventory:RemoveItem(src, item, count) == true
end

---@param src number
---@param item string
---@param count integer
---@return boolean
function InvAdd(src, item, count)
    if count < 1 then return false end
    local result = exports.ox_inventory:AddItem(src, item, count)
    -- ox_inventory v2+ retorna o slot number em sucesso, false/nil em falha
    return result ~= nil and result ~= false
end

--- [v1.16 SEC-1.1] Pré-validação de capacidade de inventário antes de consumir o entitlement.
---@param src number
---@param item string
---@param count integer
---@return boolean
function InvCanCarry(src, item, count)
    if not src or src <= 0 then return false end
    if count < 1 then return true end
    if exports.ox_inventory and exports.ox_inventory.CanCarryItem then
        local ok, can = pcall(exports.ox_inventory.CanCarryItem, exports.ox_inventory, src, item, count)
        if ok and can ~= nil then return can == true end
    end
    return true
end
