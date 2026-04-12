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
