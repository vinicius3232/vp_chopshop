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

RegisterNetEvent('vp_chopshop:client:tierUp', function(newTier)
    -- [M3 FIX] Labels e unlocks via L() — suporte completo a todos os locales.
    lib.notify({
        title       = 'Tier ' .. newTier .. ' \226\128\148 ' .. L('tier_label_' .. newTier),
        description = L('tier_unlock_' .. newTier),
        type        = 'success',
        duration    = 8000,
        position    = 'top-right',
    })
end)

-- [L4 FIX] Strings hardcoded PT-BR substituídas por L() para suportar todos os locales.
RegisterNetEvent('vp_chopshop:client:heatWarning', function(level)
    local types = { morno = 'inform', quente = 'warning', queimando = 'error' }
    local t = types[level]
    if t then
        lib.notify({ description = L('heat_warn_' .. level), type = t, duration = 5000 })
    end
end)
