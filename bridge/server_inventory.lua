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

--- [v1.16 SEC-1.2] Pré-validação de capacidade de inventário fail-closed (ox_inventory obrigatório).
---@param src number
---@param item string
---@param count integer
---@param metadata? table
---@return boolean
function InvCanCarry(src, item, count, metadata)
    if not src or src <= 0 then return false end
    if (count or 0) < 1 then return true end
    if exports and exports.ox_inventory and exports.ox_inventory.CanCarryItem then
        local ok, can = pcall(exports.ox_inventory.CanCarryItem, exports.ox_inventory, src, item, count, metadata)
        if ok and can ~= nil then return can == true end
    end
    -- Fail-closed: se o export de ox_inventory não responder ou lançar erro, retorna false
    return false
end

--- [v1.17 BROKER-4] Obtenção segura de slot server-authoritative.
---@param src number
---@param slot number
---@return table|nil
function BridgeGetSlot(src, slot)
    if not src or src <= 0 or not slot then return nil end
    if exports and exports.ox_inventory and exports.ox_inventory.GetSlot then
        local ok, item = pcall(exports.ox_inventory.GetSlot, exports.ox_inventory, src, slot)
        if ok and item and type(item) == 'table' then return item end
    end
    return nil
end

--- [v1.17 BROKER-4] Remoção específica de item por slot e metadados.
---@param src number
---@param item string
---@param count integer
---@param metadata? table
---@param slot? number
---@return boolean
function BridgeRemoveItem(src, item, count, metadata, slot)
    if not src or src <= 0 or (count or 0) < 1 then return false end
    if exports and exports.ox_inventory and exports.ox_inventory.RemoveItem then
        local ok, res = pcall(exports.ox_inventory.RemoveItem, exports.ox_inventory, src, item, count, metadata, slot)
        if ok and res ~= nil then return res == true or res == 1 end
    end
    return false
end
