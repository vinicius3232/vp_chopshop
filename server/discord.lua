--- Optional Discord webhook (similar idea to nek_chopshop editable logs).

---@param title string
---@param body string
function VPChopDiscordLog(title, body)
    local d = Config.Discord
    if not d or not d.Webhook or d.Webhook == '' then return end

    local embed = {
        {
            title = title,
            description = body,
            type = 'rich',
            color = tonumber(d.Color) or 3447003,
            footer = { text = os.date('%Y-%m-%d %H:%M:%S') },
        },
    }

    local payload = {
        username = d.Username or 'vp_chopshop',
        avatar_url = (d.AvatarUrl and d.AvatarUrl ~= '') and d.AvatarUrl or nil,
        embeds = embed,
    }

    PerformHttpRequest(d.Webhook, function() end, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json',
    })
end

---@param rewards table<string, number>|nil
---@return string
local function formatRewards(rewards)
    if not rewards or type(rewards) ~= 'table' then return '_' end
    local parts = {}
    for item, n in pairs(rewards) do
        parts[#parts + 1] = ('`%s` x%d'):format(tostring(item), tonumber(n) or 0)
    end
    if #parts < 1 then return '_' end
    table.sort(parts)
    return table.concat(parts, ', ')
end

---@param src number
---@param partKey string
---@param rewards table|nil
function VPChopDiscordLogChop(src, partKey, rewards)
    local d = Config.Discord
    if not d or not d.LogChopPart then return end
    local name = GetPlayerName(src) or '?'
    local body = ('**Player:** %s (id %d)\n**Part:** `%s`\n**Rewards:** %s'):format(
        name,
        src,
        partKey,
        formatRewards(rewards)
    )
    VPChopDiscordLog('vp_chopshop — part removed', body)
end

---@param src number
---@param benchId integer
---@param recipeIndex integer
function VPChopDiscordLogBench(src, benchId, recipeIndex)
    local d = Config.Discord
    if not d or not d.LogBenchCraft then return end
    local name = GetPlayerName(src) or '?'
    local body = ('**Player:** %s (id %d)\n**Bench:** %d\n**Recipe:** %d'):format(name, src, benchId, recipeIndex)
    VPChopDiscordLog('vp_chopshop — bench craft', body)
end

---@param src number
---@param kind 'bench'|'welder'
---@param id integer
function VPChopDiscordLogPlace(src, kind, id)
    local d = Config.Discord
    if not d then return end
    if kind == 'bench'   and not d.LogPlaceBench   then return end
    if kind == 'welder'  and not d.LogPlaceWelder  then return end
    local name = GetPlayerName(src) or '?'
    VPChopDiscordLog(('vp_chopshop — placed %s'):format(kind), ('**Player:** %s (id %d)\n**Id:** %d'):format(name, src, id))
end
