-- client/progression.lua
-- Recebe eventos de XP e tier-up do servidor e exibe feedback visual.
-- XP: texto flutuante discreto no canto. Tier-up: notificação success.

--- Exibe "+N XP" como texto flutuante no canto superior direito por 2s.
---@param amount integer
local function showXpFloat(amount)
    -- Usa lib.notify com duração curta e sem título (discreto)
    lib.notify({
        description = '+' .. amount .. ' XP',
        type        = 'inform',
        duration    = 2000,
        position    = 'top-right',
    })
end

RegisterNetEvent('vp_chopshop:client:xpGained', function(amount)
    showXpFloat(amount)
end)

RegisterNetEvent('vp_chopshop:client:tierUp', function(newTier, label, unlocks)
    lib.notify({
        title       = 'Tier ' .. newTier .. ' — ' .. label,
        description = unlocks,
        type        = 'success',
        duration    = 8000,
        position    = 'top-right',
    })
end)

RegisterNetEvent('vp_chopshop:client:heatWarning', function(level)
    local msgs = {
        morno     = { text = 'Este carro está morno. Cuidado.', type = 'inform' },
        quente    = { text = 'Este carro está quente. Fence paga menos.', type = 'warning' },
        queimando = { text = 'Carro queimando! Fence não vai tocar nisso.', type = 'error' },
    }
    local m = msgs[level]
    if m then
        lib.notify({ description = m.text, type = m.type, duration = 5000 })
    end
end)
