-- ============================================================
-- server/advanced_chop.lua
-- Sistema de desmanche avançado por fases (requer jackstand levantado).
-- Fase 2 — Portas / Capô / Porta-malas  → requer serra    → 1× car_parts por peça
-- Fase 3 — Motor                         → requer chave    → 5× car_parts (capô removido primeiro)
-- Fase 4 — Carcaça                       → requer solda    → recicláveis
--
-- [v1.15 PR-C] AdvState e AdvMutex REMOVIDOS. Estado de peça e mutex vivem na
-- ChopSession (server/session/advanced_state.lua).
-- [v1.15 PR-G] O DOMÍNIO (consume tool → markPart commit-antes-de-reward → reward →
-- trace → PART_CHOPPED → breakDoor) foi extraído para helpers reutilizáveis
-- (VPChopAdv{Door,Engine,Carcass}Commit) usados pelo callback legacy E pelo executor
-- da ActionSession (server/action/advanced_chop.lua). Gameplay/economia INALTERADOS.
-- Quando Config.ActionSession.RequireAdvanced=true (default) os callbacks legacy
-- adv:* retornam 'action_required' — o fluxo obrigatório vira start → UX → complete.
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
-- [PR-G] exposto p/ o executor da ActionSession (server/action/advanced_chop.lua)
function VPChopAdvOnCooldown(src) return advOnCooldown(src) end
function VPChopAdvMarkCooldown(src) advMarkCooldown(src) end

AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1]
    AdvCooldown[src] = nil
end)

-- [v1.15 P1-1] Gate de autoridade (server/session/adv_gate.lua).
local advGate = VPChopAdvRequireRaisedSession

-- Seam de teste (só sob convar): limpar o AdvCooldown entre casos.
if GetConvar and GetConvar('vp_chopshop_selftest', '0') == '1' then
    VPChopAdv_test = { clearCooldown = function() for k in pairs(AdvCooldown) do AdvCooldown[k] = nil end end }
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getVehCoords(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    return GetEntityCoords(veh)
end

local function consumeSaw(src)
    return VPChopConsumeTool(src, false)
end

--- [PR-G] soldadora perto do veículo (server-side). Exposto p/ ActionSession.
---@param netId integer
---@return boolean
function VPChopWelderNearVehicle(netId)
    local vc = getVehCoords(netId)
    if not vc then return false end
    local welderRadius = tonumber(Config.AdvancedChop and Config.AdvancedChop.WelderRadius) or 8.0
    for _, w in ipairs(ServerWelders or {}) do
        if #(w.coords - vc) <= welderRadius then return true end
    end
    return false
end

--- [AUDIT-FIX C2] Vestígio forense + arma marca de pneu (Fases 2/3/4). Inalterado.
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
local function resolveSession(sessionId, netId, src)
    return sessionId or VPChopAdvancedState.ensureSession(netId, src)
end

--- Recompensa avançada (inventário-cheio: peça permanece REMOVED, warning, sem rollback).
local function giveReward(src, netId, reward)
    if not (reward and reward.item and (reward.amount or 0) > 0) then return end
    local ok = (reward.item == 'car_parts')
        and VPChopAddStolenCarParts(src, netId, reward.amount)
        or  InvAdd(src, reward.item, reward.amount)
    if not ok then
        TriggerClientEvent('ox_lib:notify', src, { type = 'warning', description = L('reward_inv_full_engine') })
    end
end

-- ─── COMMIT HELPERS (domínio — reutilizados por legacy + ActionSession) ───────
--  Assumem: src pronto, netId/sessionId validados, gate/dependências/distância já
--  checados pelo chamador, ferramenta já VERIFICADA. Fazem: recheck → consume
--  tool → markPart (commit ANTES de reward) → cooldown → reward → trace →
--  PART_CHOPPED. NÃO travam a peça (o lock é do chamador: legacy = lockPart;
--  ActionSession = ChopSession.LockPart da própria action).

---@return { ok:boolean, err:string|nil }
function VPChopAdvDoorCommit(src, netId, sessionId, partKey)
    if VPChopPartGtaClass(partKey) ~= 'door' then return { ok = false, err = 'part' } end
    if VPChopAdvancedState.wasRemoved(sessionId, partKey) then return { ok = false, err = 'done' } end
    if not consumeSaw(src) then return { ok = false, err = 'no_saw' } end

    local mOk, mDup = VPChopAdvancedState.markPart(sessionId, src, partKey)
    if not mOk then return { ok = false, err = 'session' } end
    if mDup then return { ok = false, err = 'done' } end
    advMarkCooldown(src)

    local peId = nil
    if PartEntitlement and PartEntitlement.Issue then
        peId = PartEntitlement.Issue(sessionId, src, partKey, netId, { origin = 'advanced' })
    end

    -- [PHYSICAL CARRY] Se o carregamento físico estiver ativo, a peça vai para os braços
    -- e o jogador escolhe como processá-la na bancada (matérias-primas / serial limpo / serial roubado).
    if not (Config.PhysicalCarry and Config.PhysicalCarry.Enable) then
        giveReward(src, netId, Config.AdvancedChop.DoorReward or { item = 'car_parts', amount = 1 })
    end

    local vehCoords = getVehCoords(netId)
    if vehCoords then leaveAdvancedTrace(src, netId, vehCoords) end
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, partKey, 2)

    -- [H4 FIX] breakDoor filtrado por proximidade.
    local partDef = VPChopPartRegistry.get(partKey)
    local doorIndex = (partDef and partDef.gtaIndex) or 0
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
            if send then TriggerClientEvent('vp_chopshop:adv:breakDoor', pidN, netId, partKey, doorIndex) end
        end
    end
    return { ok = true, partEntitlementId = peId }
end

---@return { ok:boolean, err:string|nil }
function VPChopAdvEngineCommit(src, netId, sessionId)
    local bonnetDone = VPChopAdvancedState.wasRemoved(sessionId, 'bonnet')
    if not bonnetDone and netId and netId > 0 then
        local veh = NetworkGetEntityFromNetworkId(netId)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            if type(GetVehicleDoorStatus) == 'function' and (GetVehicleDoorStatus(veh, 4) == 2 or GetVehicleDoorStatus(veh, 4) == 1) then
                bonnetDone = true
            elseif type(IsVehicleDoorDamaged) == 'function' and IsVehicleDoorDamaged(veh, 4) then
                bonnetDone = true
            end
        end
    end
    if not bonnetDone then return { ok = false, err = 'hood_first' } end
    if VPChopAdvancedState.wasRemoved(sessionId, 'adv_engine') then return { ok = false, err = 'done' } end
    if not VPChopConsumeTool(src, true) then return { ok = false, err = 'no_screwdriver' } end

    local mOk, mDup = VPChopAdvancedState.markPart(sessionId, src, 'adv_engine')
    if not mOk then return { ok = false, err = 'session' } end
    if mDup then return { ok = false, err = 'done' } end
    advMarkCooldown(src)

    -- [UX-D Damage Scaling] Recompensa do motor ajustada pelo dano físico (EngineHealth)
    local baseParts = (Config.AdvancedChop and Config.AdvancedChop.EngineReward and Config.AdvancedChop.EngineReward.amount) or 5
    local finalParts = baseParts
    local scrapBonus = 0

    if Config.DamageScaling and Config.DamageScaling.Enable and netId and netId > 0 then
        local veh = NetworkGetEntityFromNetworkId(netId)
        if veh and veh ~= 0 and DoesEntityExist(veh) and type(GetVehicleEngineHealth) == 'function' then
            local eHealth = GetVehicleEngineHealth(veh)
            local minH = tonumber(Config.DamageScaling.MinEngineHealthToChop) or 150.0
            if eHealth and eHealth < minH then
                finalParts = 0
                scrapBonus = 6
                TriggerClientEvent('ox_lib:notify', src, {
                    type = 'warning',
                    title = L('notify_title') or 'Chop Shop',
                    description = L('err_engine_destroyed')
                })
            elseif Config.DamageScaling.ScaleEngineRewards and eHealth and eHealth < 950.0 then
                local healthRatio = math.max(0.2, math.min(1.0, eHealth / 1000.0))
                finalParts = math.max(1, math.floor(baseParts * healthRatio))
                local lostParts = baseParts - finalParts
                scrapBonus = lostParts * 2
                TriggerClientEvent('ox_lib:notify', src, {
                    type = 'inform',
                    title = L('notify_title') or 'Chop Shop',
                    description = L('notify_engine_scaled')
                })
            end
        end
    end

    local peId = nil
    if PartEntitlement and PartEntitlement.Issue then
        peId = PartEntitlement.Issue(sessionId, src, 'adv_engine', netId, { origin = 'advanced' })
    end

    -- [PHYSICAL CARRY] Se o carregamento físico estiver ativo, o bloco do motor vai para os braços
    -- e o jogador escolhe como processá-lo na bancada (matérias-primas / serial limpo / serial roubado).
    if not (Config.PhysicalCarry and Config.PhysicalCarry.Enable) then
        if finalParts > 0 then
            giveReward(src, netId, { item = 'car_parts', amount = finalParts })
        end
        if scrapBonus > 0 then
            giveReward(src, netId, { item = 'metalscrap', amount = scrapBonus })
        end
    end

    local vehCoords = getVehCoords(netId)
    if vehCoords then leaveAdvancedTrace(src, netId, vehCoords) end
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'adv_engine', 3)
    return { ok = true, partEntitlementId = peId }
end

---@return { ok:boolean, err:string|nil }
function VPChopAdvCarcassCommit(src, netId, sessionId)
    if not VPChopAdvancedState.wasRemoved(sessionId, 'adv_engine') then return { ok = false, err = 'engine_first' } end
    if VPChopAdvancedState.wasRemoved(sessionId, 'adv_carcass') then return { ok = false, err = 'done' } end
    if not VPChopWelderNearVehicle(netId) then return { ok = false, err = 'no_welder_adv' } end

    local veh = NetworkGetEntityFromNetworkId(netId)
    local model = (veh and veh ~= 0 and DoesEntityExist(veh)) and GetEntityModel(veh) or 0

    -- [v1.16 SEC-1.1] Barreira persistente anti-rechop / double-carcass
    if VPChopCarcassLedger and VPChopCarcassLedger.alreadyProcessed and model ~= 0 then
        if VPChopCarcassLedger.alreadyProcessed(netId, model) then
            return { ok = false, err = 'done' }
        end
    end
    if veh and veh ~= 0 and DoesEntityExist(veh) and Entity(veh).state.vpChopCarcassDone == true then
        return { ok = false, err = 'done' }
    end

    local mOk, mDup = VPChopAdvancedState.markPart(sessionId, src, 'adv_carcass')
    if not mOk then return { ok = false, err = 'session' } end
    if mDup then return { ok = false, err = 'done' } end
    advMarkCooldown(src)

    local anyFull = false
    for _, reward in ipairs(Config.AdvancedChop.CarcassRewards or {}) do
        if reward.item and (reward.amount or 0) > 0 and math.random() <= (reward.chance or 1.0) then
            local ok = (reward.item == 'car_parts')
                and VPChopAddStolenCarParts(src, netId, reward.amount)
                or  InvAdd(src, reward.item, reward.amount)
            if not ok then anyFull = true end
        end
    end
    if anyFull then
        TriggerClientEvent('ox_lib:notify', src, { type = 'warning', description = L('reward_inv_full_carcass') })
    end

    local vehCoords = getVehCoords(netId)
    if vehCoords then leaveAdvancedTrace(src, netId, vehCoords) end
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'adv_carcass', 4)

    -- [UX-E Terminal Chassis Destruction]
    local stillExists = false
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        Entity(veh).state:set('vpChopCarcassDone', true, true)
        if type(BridgeDeleteWorldVehicle) == 'function' then
            BridgeDeleteWorldVehicle(veh)
        else
            DeleteEntity(veh)
        end
        stillExists = (veh ~= 0 and DoesEntityExist(veh) == true)
    end

    -- [v1.16 SEC-1.1] Grava no CarcassLedger persistente para bloquear repetição mesmo pós restart
    if VPChopCarcassLedger and VPChopCarcassLedger.mark and model ~= 0 then
        local s = type(ChopSession) == 'table' and ChopSession.Get and ChopSession.Get(sessionId)
        local vsid = s and s.vehicle and s.vehicle.identity or nil
        VPChopCarcassLedger.mark(netId, model, vsid, 'carcass', ServerChopPlayerKey(src), stillExists)
    end

    local jackItem = (Config.Jackstand and Config.Jackstand.Item) or 'chopshop_jackstand'
    if jackItem and type(InvAdd) == 'function' then
        InvAdd(src, jackItem, 1)
    end

    return { ok = true }
end

-- ─── Gate legacy: ActionSession obrigatória p/ advanced ───────────────────────
-- Predicate ÚNICO (shared/action_gate.lua): quando FALSE (RequireAdvanced=false OU
-- EnforceRaised=false = compat legacy mode), o callback legacy NÃO gate — o fluxo
-- antigo (advGate compat → ensureSession → ChopSession state) volta a funcionar.
local function advActionRequired()
    return VPChopActionModeAdvanced()
end

-- ─── Fase 2: Portas / Capô / Porta-malas ─────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopPart', function(source, netId, partKey)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then return { ok = false, err = 'disabled' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advActionRequired() then return { ok = false, err = 'action_required' } end
    if advOnCooldown(src) then return { ok = false, err = 'processing' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end
    if type(partKey) ~= 'string' or #partKey > 32 or #partKey < 3 then return { ok = false, err = 'part' } end

    local okS, errS, sessionId = advGate(src, netId)
    if not okS then return { ok = false, err = errS } end

    if VPChopPartGtaClass(partKey) ~= 'door' then return { ok = false, err = 'part' } end

    local vehCoords = getVehCoords(netId)
    if not vehCoords then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearPoint(src, vehCoords, 6.0) then return { ok = false, err = 'distance' } end

    sessionId = resolveSession(sessionId, netId, src)
    if not sessionId then return { ok = false, err = 'session' } end
    if VPChopAdvancedState.wasRemoved(sessionId, partKey) then return { ok = false, err = 'done' } end

    local locked, token = VPChopAdvancedState.lockPart(sessionId, partKey)
    if not locked then return { ok = false, err = 'processing' } end
    local function done(res) VPChopAdvancedState.unlockPart(sessionId, partKey, token); return res end

    if not VPChopHasTool(src, false) then return done({ ok = false, err = 'no_saw' }) end
    return done(VPChopAdvDoorCommit(src, netId, sessionId, partKey))
end)

-- ─── Fase 3: Motor ────────────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopEngine', function(source, netId)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then return { ok = false, err = 'disabled' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advActionRequired() then return { ok = false, err = 'action_required' } end
    if advOnCooldown(src) then return { ok = false, err = 'processing' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end

    local okS, errS, sessionId = advGate(src, netId)
    if not okS then return { ok = false, err = errS } end

    local vehCoords = getVehCoords(netId)
    if not vehCoords then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearPoint(src, vehCoords, 6.0) then return { ok = false, err = 'distance' } end

    sessionId = resolveSession(sessionId, netId, src)
    local bonnetDone = VPChopAdvancedState.wasRemoved(sessionId, 'bonnet')
    if not bonnetDone and netId and netId > 0 then
        local veh = NetworkGetEntityFromNetworkId(netId)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            if type(GetVehicleDoorStatus) == 'function' and (GetVehicleDoorStatus(veh, 4) == 2 or GetVehicleDoorStatus(veh, 4) == 1) then
                bonnetDone = true
            elseif type(IsVehicleDoorDamaged) == 'function' and IsVehicleDoorDamaged(veh, 4) then
                bonnetDone = true
            end
        end
    end
    if not bonnetDone then return { ok = false, err = 'hood_first' } end
    if VPChopAdvancedState.wasRemoved(sessionId, 'adv_engine') then return { ok = false, err = 'done' } end
    if not VPChopHasTool(src, true) then return { ok = false, err = 'no_screwdriver' } end

    local locked, token = VPChopAdvancedState.lockPart(sessionId, 'adv_engine')
    if not locked then return { ok = false, err = 'processing' } end
    local function done(res) VPChopAdvancedState.unlockPart(sessionId, 'adv_engine', token); return res end
    return done(VPChopAdvEngineCommit(src, netId, sessionId))
end)

-- ─── Fase 4: Carcaça ──────────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:adv:chopCarcass', function(source, netId)
    local src = source
    if not Config.AdvancedChop or not Config.AdvancedChop.Enable then return { ok = false, err = 'disabled' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if advActionRequired() then return { ok = false, err = 'action_required' } end
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
    if not VPChopWelderNearVehicle(netId) then return { ok = false, err = 'no_welder_adv' } end

    local locked, token = VPChopAdvancedState.lockPart(sessionId, 'adv_carcass')
    if not locked then return { ok = false, err = 'processing' } end
    local function done(res) VPChopAdvancedState.unlockPart(sessionId, 'adv_carcass', token); return res end
    return done(VPChopAdvCarcassCommit(src, netId, sessionId))
end)
