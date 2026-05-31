-- server/progression.lua
-- Gerencia XP e tiers por jogador. Persiste em vp_chop_progression.
-- Expõe: VPChopGetProgression(src), VPChopAddXp(src, amount)
-- Escuta: VPChopEvt.PART_CHOPPED, VPChopEvt.CAR_DISCARDED, VPChopEvt.FENCE_DELIVERY

--- Cache em memória por source (carregado ao conectar, salvo ao ganhar XP)
local ProgressCache = {} ---@type table<number, {tier:integer, xp:integer, total_chops:integer}>

--- XP por ação (configuração local — não exposta ao cliente)
local XP_TABLE = {
    phase1     = 8,
    phase2     = 15,
    phase3     = 40,
    phase4     = 60,
    discard    = 25,
    tyre_sell  = 5,
    order      = 120,
    tyre_mission = 80,
    vin_scratch  = 30,
    plate_theft  = 12,  -- [FASE1 placas] XP de roubo de placa física (progressão tier 1)
    plate_witness_bonus = 0,  -- [F4 testemunhas] valor real vem do Config.Plates.Witness.BonusXp (capado)
    fake_plate   = 22,  -- [FASE2 placas] XP de forja de placa falsa (gate tier 2; valor real vem do Config)
    material     = 10,
    car          = 150,
}

--- Carrega ou cria registro de progressão para um jogador.
---@param src number
---@return {tier:integer, xp:integer, total_chops:integer}
function VPChopGetProgression(src)
    if ProgressCache[src] then return ProgressCache[src] end
    local key = ServerChopPlayerKey(src)
    local row = MySQL.single.await(
        'SELECT tier, xp, total_chops FROM vp_chop_progression WHERE identifier = ?', {key}
    )
    if row then
        ProgressCache[src] = { tier=row.tier, xp=row.xp, total_chops=row.total_chops }
    else
        ProgressCache[src] = { tier=1, xp=0, total_chops=0 }
        MySQL.query.await(
            'INSERT IGNORE INTO vp_chop_progression (identifier, tier, xp, total_chops) VALUES (?,1,0,0)',
            {key}
        )
    end
    return ProgressCache[src]
end

--- Notifica cliente de ganho de XP (texto flutuante discreto).
---@param src number
---@param amount integer
local function notifyXp(src, amount)
    TriggerClientEvent('vp_chopshop:client:xpGained', src, amount)
end

--- Notifica cliente de avanço de tier.
---@param src number
---@param newTier integer
local function notifyTierUp(src, newTier)
    -- [M3 FIX] Enviar apenas newTier — client/progression.lua chama L() localmente.
    TriggerClientEvent('vp_chopshop:client:tierUp', src, newTier)
end

--- Adiciona XP e faz tier-up se necessário.
---@param src number
---@param amount integer
---@param reason string  chave da XP_TABLE ou string livre para log
function VPChopAddXp(src, amount, reason)
    if not IsValidSource(src) then return end
    local prog = VPChopGetProgression(src)
    if not prog then return end

    prog.xp = prog.xp + amount
    if reason == 'phase1' or reason == 'phase2' or reason == 'phase3' or reason == 'phase4' then
        prog.total_chops = prog.total_chops + 1
    end

    -- Verificar tier-up
    local tierXp = Config.Progression and Config.Progression.TierXp or { [1]=0, [2]=500, [3]=2000, [4]=5000 }
    local prevTier = prog.tier
    for t = 4, 2, -1 do
        if prog.xp >= (tierXp[t] or math.huge) and prog.tier < t then
            prog.tier = t
        end
    end

    -- [M2 FIX] Persistir em thread separada: não bloqueia a coroutine do callback enquanto
    -- aguarda o MySQL. O cache em memória (ProgressCache) já está actualizado — sem risco de
    -- dados inconsistentes se outro callback ler antes do DB confirmar.
    local key  = ServerChopPlayerKey(src)
    local snap = { tier = prog.tier, xp = prog.xp, total_chops = prog.total_chops }
    CreateThread(function()
        -- [M4 FIX] Wrap in pcall: a DB outage should be visible in console, not silently
        -- discard the player's tier-up (cache is cleared at playerDropped).
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO vp_chop_progression (identifier, tier, xp, total_chops) VALUES (?,?,?,?) '..
            'ON DUPLICATE KEY UPDATE tier=VALUES(tier), xp=VALUES(xp), total_chops=VALUES(total_chops)',
            {key, snap.tier, snap.xp, snap.total_chops}
        )
        if not ok then
            print(('[vp_chopshop] WARN: XP persist failed for %s — %s'):format(key, tostring(err)))
        end
    end)

    notifyXp(src, amount)
    for t = prevTier + 1, prog.tier do
        notifyTierUp(src, t)
    end
end

-- ─── Listeners do event bus ───────────────────────────────────────────────────

AddEventHandler(VPChopEvt.PART_CHOPPED, function(src, netId, partKey, phase)
    local reason = 'phase' .. tostring(phase)
    local amount = XP_TABLE[reason] or XP_TABLE.phase1
    -- VIN scratch tem XP próprio
    if partKey == 'vin_scratch' then
        amount = XP_TABLE.vin_scratch
        reason = 'vin_scratch'
    -- [FASE1 placas] roubo de placa física tem XP próprio (espelha o vin_scratch)
    elseif partKey == 'plate_theft' then
        amount = XP_TABLE.plate_theft
        reason = 'plate_theft'
    end
    VPChopAddXp(src, amount, reason)
end)

AddEventHandler(VPChopEvt.CAR_DISCARDED, function(src)
    VPChopAddXp(src, XP_TABLE.discard, 'discard')
end)

AddEventHandler(VPChopEvt.FENCE_DELIVERY, function(src, items, totalValue, deliveryType)
    -- deliveryType: 'material' | 'tyre' | 'order' | 'tyre_mission' | 'car'
    local amount = 0
    if     deliveryType == 'tyre'         then amount = XP_TABLE.tyre_sell
    elseif deliveryType == 'order'        then amount = XP_TABLE.order
    elseif deliveryType == 'tyre_mission' then amount = XP_TABLE.tyre_mission
    elseif deliveryType == 'material'     then amount = XP_TABLE.material
    elseif deliveryType == 'car'          then amount = XP_TABLE.car
    end
    if amount > 0 then VPChopAddXp(src, amount, deliveryType) end
end)

-- ─── Cleanup ao desconectar ───────────────────────────────────────────────────

AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1]
    ProgressCache[src] = nil
end)

-- ─── Callback: consulta de status (usado pelo fence para exibir ao jogador) ──

lib.callback.register('vp_chopshop:getProgression', function(src)
    if not IsValidSource(src) then return nil end
    local prog = VPChopGetProgression(src)
    if not prog then return nil end
    local tierXp = Config.Progression and Config.Progression.TierXp or { [1]=0, [2]=500, [3]=2000, [4]=5000 }
    local nextXp = tierXp[prog.tier + 1]
    return {
        tier       = prog.tier,
        xp         = prog.xp,
        nextXp     = nextXp,
        totalChops = prog.total_chops,
    }
end)
