---@param msg string
---@param nType? string
---@param duration? integer
function VPChopNotify(msg, nType, duration)
    lib.notify({
        title = L('notify_title'),
        description = msg,
        type = nType or 'inform',
        duration = duration or 5000,
    })
end
