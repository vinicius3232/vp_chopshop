--- Per-player dismantle cooldown (anti-spam). Key from `ServerChopPlayerKey`.

local Until = {} ---@type table<string, number>

---@param src number
---@return integer seconds remaining (0 if none)
function VPChopChopCooldownRemaining(src)
    local sec = Config.ChopCooldownSeconds
    if not sec or sec < 1 then return 0 end
    local key = ServerChopPlayerKey(src)
    local t = Until[key]
    if not t then return 0 end
    local now = os.time()
    if now >= t then return 0 end
    return t - now
end

---@param src number
function VPChopChopCooldownMark(src)
    local sec = Config.ChopCooldownSeconds
    if not sec or sec < 1 then return end
    local key = ServerChopPlayerKey(src)
    Until[key] = os.time() + sec
end

AddEventHandler('playerDropped', function()
    local src = source  -- [M1 FIX] snapshot antes de qualquer yield
    local key = ServerChopPlayerKey(src)
    Until[key] = nil
end)
