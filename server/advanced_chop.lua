-- ============================================================
-- server/advanced_chop.lua
-- Sistema de desmanche avançado por fases (requer jackstand levantado).
-- Fase 2 — Portas / Capô / Porta-malas  → requer serra    → 1× car_parts por peça
-- Fase 3 — Motor                         → requer chave    → 5× car_parts (capô removido primeiro)
-- Fase 4 — Carcaça                       → requer solda    → recicláveis
--
-- [v1.15 PR-C] AdvState e AdvMutex REMOVIDOS. Estado de peça e mutex agora vivem
-- na ChopSession (via server/session/advanced_state.lua). Base + advanced
-- compartilham UMA fonte server-authoritative: ChopSession.parts.
-- Gameplay/economia/rewards/progress bars: INALTERADOS.
-- ============================================================

local AdvCooldown   = {} -- [src] = GetGameTimer() — rate-limit por jogador (PRESERVADO)
local ADV_COOLDOWN_MS = 3000  -- mínimo entre ações de desmanche avançado

local function advOnCooldown(src)
    local t = AdvCooldown[src]
    return t and (GetGameTimer() - t) < ADV_COOLDOWN_MS
end

local function advMarkCooldown(src)
    AdvCooldown[src] = GetGameTimer()
end

AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1]
    AdvCooldown[src] = nil
end)

-- [v1.15 P1-1] Gate de autoridade (server/session/adv_gate.lua) — devolve o
-- sessionId da ChopSession (ou nil no modo compat EnforceRaised=false, resolvido
-- depois via ensureSession).
local advGate = VPChopAdvRequireRaisedSession

-- [v1.15 PR-C] entityRemoved de AdvState/AdvMutex REMOVIDO — o lifecycle da
-- entidade é da ChopSession (chop_session.lua tem seu entityRemoved).

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getVehCoords(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    return GetEntityCoords(veh)
end

local function consumeSaw(src)
    return VPChopConsumeTool(src, false)
end

--- [AUDIT-FIX C2] Vestígio forense + arma marca de pneu (Fases 2/3/4). Inalterado.
---@param src number
---@param netId number
---@param vehCoords vector3
local function leaveAdvancedTrace(src, netId, vehCoords)
    local veh = NetworkGetEntityFromNetworkId(netId)
    local realPlate = nil
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        local visible = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', '')
        if visible ~= '' then
            realPlate = VPChopMDT.GetRealPlate(visible)
        end
    end
    VPChopLeaveEvidence(src, vehCoords, 'chop_part', realPlate)
    if Config.TyreMarks and Config.TyreMarks.Enable then
        local armMs = (Config.TyreMarks.ArmWindowSeconds or 45) * 1000
        VPChopArmTyreWindow(src, armMs)  -- [AUDIT-FIX H1]
        TriggerClientEvent('vp_chopshop:armTyreMark', src, armMs)
    end
end

--- Resolve/cria o sessionId após validar entidade/distância (nunca do payload cru).
---@return string|nil
local function resolveSession(sessionId, netId, src)
    return sessionId or VPChopAdvancedState.ensureSession(netId, src)
end

-- ─── Fase 2: Portas / Capô / Porta-malas ─────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopPart', function(source, netId, partKey)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then
        return { ok = false, err = 'disabled' }
    end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advOnCooldown(src) then return { ok = false, err = 'processing' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end
    if type(partKey) ~= 'string' or #partKey > 32 or #partKey < 3 then
        return { ok = false, err = 'part' }
    end

    -- [v1.15 P1-1] Gate de autoridade (read-only). sessionId pode vir nil no modo compat.
    local okS, errS, sessionId = advGate(src, netId)
    if not okS then return { ok = false, err = errS } end

    local partDef = ChopParts[partKey]
    if not partDef or partDef.kind ~= 'door' then return { ok = false, err = 'part' } end

    local vehCoords = getVehCoords(netId)
    if not vehCoords then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearPoint(src, vehCoords, 6.0) then return { ok = false, err = 'distance' } end

    -- Só AGORA (entidade + distância válidas) resolvemos/criamos a ChopSession.
    sessionId = resolveSession(sessionId, netId, src)
    if not sessionId then return { ok = false, err = 'session' } end

    if VPChopAdvancedState.wasRemoved(sessionId, partKey) then return { ok = false, err = 'done' } end

    -- Mutex por (sessão, peça)
    local locked, token = VPChopAdvancedState.lockPart(sessionId, partKey)
    if not locked then return { ok = false, err = 'processing' } end
    local function done(res) VPChopAdvancedState.unlockPart(sessionId, partKey, token); return res end

    -- [PR-C] RECHECK após o lock (defense-in-depth).
    if VPChopAdvancedState.wasRemoved(sessionId, partKey) then return done({ ok = false, err = 'done' }) end

    -- Verificar e consumir serra
    if not consumeSaw(src) then return done({ ok = false, err = 'no_saw' }) end

    -- [PR-C] COMMIT ANTES DE REWARD: nenhuma recompensa sem committed part state.
    local mOk, mDup = VPChopAdvancedState.markPart(sessionId, src, partKey)
    if not mOk then return done({ ok = false, err = 'session' }) end
    if mDup then return done({ ok = false, err = 'done' }) end
    advMarkCooldown(src)

    -- Recompensa (após commit). Política de inventário-cheio INALTERADA: peça
    -- permanece REMOVED, warning, sem rollback.
    local reward = Config.AdvancedChop.DoorReward or { item = 'car_parts', amount = 1 }
    if reward.item and (reward.amount or 0) > 0 then
        local ok = (reward.item == 'car_parts')
            and VPChopAddStolenCarParts(src, netId, reward.amount)
            or  InvAdd(src, reward.item, reward.amount)
        if not ok then
            TriggerClientEvent('ox_lib:notify', src, { type='warning', description='Inventário cheio — item de recompensa perdido.' })
        end
    end

    leaveAdvancedTrace(src, netId, vehCoords)
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, partKey, 2)

    -- [H4 FIX] breakDoor filtrado por proximidade.
    local ent = NetworkGetEntityFromNetworkId(netId)
    local bpos = (ent and ent ~= 0 and DoesEntityExist(ent)) and GetEntityCoords(ent) or nil
    for _, pid in ipairs(GetPlayers()) do
        local pidN = tonumber(pid)
        if pidN then
            local send = true
            if bpos then
                local pped = GetPlayerPed(pidN)
                send = pped and pped ~= 0 and #(GetEntityCoords(pped) - bpos) < 150.0
            end
            if send then TriggerClientEvent('vp_chopshop:adv:breakDoor', pidN, netId, partKey, partDef.index) end
        end
    end

    return done({ ok = true })
end)

-- ─── Fase 3: Motor ────────────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopEngine', function(source, netId)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then
        return { ok = false, err = 'disabled' }
    end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advOnCooldown(src) then return { ok = false, err = 'processing' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end

    local okS, errS, sessionId = advGate(src, netId)
    if not okS then return { ok = false, err = errS } end

    local vehCoords = getVehCoords(netId)
    if not vehCoords then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearPoint(src, vehCoords, 6.0) then return { ok = false, err = 'distance' } end

    sessionId = resolveSession(sessionId, netId, src)
    if not sessionId then return { ok = false, err = 'session' } end

    -- Dependência: capô removido (autoridade = ChopSession, nunca estado client).
    if not VPChopAdvancedState.wasRemoved(sessionId, 'bonnet') then return { ok = false, err = 'hood_first' } end
    if VPChopAdvancedState.wasRemoved(sessionId, 'adv_engine') then return { ok = false, err = 'done' } end

    -- Chave de fenda (verificar antes do lock; consumir depois)
    if not VPChopHasTool(src, true) then return { ok = false, err = 'no_screwdriver' } end

    local locked, token = VPChopAdvancedState.lockPart(sessionId, 'adv_engine')
    if not locked then return { ok = false, err = 'processing' } end
    local function done(res) VPChopAdvancedState.unlockPart(sessionId, 'adv_engine', token); return res end

    if VPChopAdvancedState.wasRemoved(sessionId, 'adv_engine') then return done({ ok = false, err = 'done' }) end
    if not VPChopConsumeTool(src, true) then return done({ ok = false, err = 'no_screwdriver' }) end

    local mOk, mDup = VPChopAdvancedState.markPart(sessionId, src, 'adv_engine')
    if not mOk then return done({ ok = false, err = 'session' }) end
    if mDup then return done({ ok = false, err = 'done' }) end
    advMarkCooldown(src)

    local reward = Config.AdvancedChop.EngineReward or { item = 'car_parts', amount = 5 }
    if reward.item and (reward.amount or 0) > 0 then
        local ok = (reward.item == 'car_parts')
            and VPChopAddStolenCarParts(src, netId, reward.amount)
            or  InvAdd(src, reward.item, reward.amount)
        if not ok then
            TriggerClientEvent('ox_lib:notify', src, { type='warning', description='Inventário cheio — item de recompensa perdido.' })
        end
    end

    leaveAdvancedTrace(src, netId, vehCoords)
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'adv_engine', 3)
    return done({ ok = true })
end)

-- ─── Fase 4: Carcaça ──────────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopCarcass', function(source, netId)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then
        return { ok = false, err = 'disabled' }
    end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advOnCooldown(src) then return { ok = false, err = 'processing' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end

    local okS, errS, sessionId = advGate(src, netId)
    if not okS then return { ok = false, err = errS } end

    local vehCoords = getVehCoords(netId)
    if not vehCoords then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearPoint(src, vehCoords, 8.0) then return { ok = false, err = 'distance' } end

    sessionId = resolveSession(sessionId, netId, src)
    if not sessionId then return { ok = false, err = 'session' } end

    if not VPChopAdvancedState.wasRemoved(sessionId, 'adv_engine') then return { ok = false, err = 'engine_first' } end
    if VPChopAdvancedState.wasRemoved(sessionId, 'adv_carcass') then return { ok = false, err = 'done' } end

    -- Soldadora perto (server-side)
    local welderRadius = tonumber(Config.AdvancedChop.WelderRadius) or 8.0
    local hasWelder = false
    for _, w in ipairs(ServerWelders or {}) do
        if #(w.coords - vehCoords) <= welderRadius then hasWelder = true; break end
    end
    if not hasWelder then return { ok = false, err = 'no_welder_adv' } end

    local locked, token = VPChopAdvancedState.lockPart(sessionId, 'adv_carcass')
    if not locked then return { ok = false, err = 'processing' } end
    local function done(res) VPChopAdvancedState.unlockPart(sessionId, 'adv_carcass', token); return res end

    if VPChopAdvancedState.wasRemoved(sessionId, 'adv_carcass') then return done({ ok = false, err = 'done' }) end

    local mOk, mDup = VPChopAdvancedState.markPart(sessionId, src, 'adv_carcass')
    if not mOk then return done({ ok = false, err = 'session' }) end
    if mDup then return done({ ok = false, err = 'done' }) end
    advMarkCooldown(src)

    local anyFull = false
    for _, reward in ipairs(Config.AdvancedChop.CarcassRewards or {}) do
        if reward.item and (reward.amount or 0) > 0 then
            local chance = reward.chance or 1.0
            if math.random() <= chance then
                local ok = (reward.item == 'car_parts')
                    and VPChopAddStolenCarParts(src, netId, reward.amount)
                    or  InvAdd(src, reward.item, reward.amount)
                if not ok then anyFull = true end
            end
        end
    end
    if anyFull then
        TriggerClientEvent('ox_lib:notify', src, { type='warning', description='Inventário cheio — alguns itens de carcaça perdidos.' })
    end

    leaveAdvancedTrace(src, netId, vehCoords)
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'adv_carcass', 4)
    return done({ ok = true })
end)
