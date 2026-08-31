-- server/session/jackstand.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Jackstand SERVER-AUTHORITATIVE — primeiro consumidor real da ChopSession.
--  v1.15 arch/chop-session · ETAPA 3.
--
--  ANTES: o estado "veículo levantado" vivia só em JackstandData (client). Nada
--  no servidor sabia se um carro estava no macaco → advanced_chop.lua tinha no
--  cabeçalho "requer jackstand" mas NENHUM callback verificava (P1-1).
--
--  AGORA: o cliente pede autorização; o servidor cria/atualiza a ChopSession e
--  marca `raised`. O visual (props, animação, lift) continua 100% client-side,
--  mas NÃO é mais autoridade. `ChopSession.IsRaised(netId)` é a verdade.
--
--  Esta PR só estabelece a autoridade do jackstand. Os consumidores que exigem
--  elevação (advanced chop, tyre steal) passam a consultar IsRaised nas próximas
--  PRs, com aprovação — NÃO nesta.
-- ═══════════════════════════════════════════════════════════════════════════════

local RAISE_CD_MS = 2000
local _raiseCd = {} ---@type table<number, number>  src → expiry GetGameTimer

AddEventHandler('playerDropped', function() _raiseCd[source] = nil end)

--- Classe de veículo elegível a macaco (espelha o filtro client de VPChopJackstandRaiseCar).
local function isJackableClass(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local model = GetEntityModel(veh)

    -- 1) Se GetVehicleClass existir (mock / client environment)
    if rawget(_G, 'GetVehicleClass') then
        local ok, vc = pcall(GetVehicleClass, veh)
        if ok and type(vc) == 'number' then
            return (vc >= 0 and vc <= 7) or (vc >= 9 and vc <= 12) or (vc >= 17 and vc <= 20)
        end
    end

    -- 2) CFX server native: GetVehicleClassFromName(modelHash)
    if rawget(_G, 'GetVehicleClassFromName') and model and model ~= 0 then
        local ok, vc = pcall(GetVehicleClassFromName, model)
        if ok and type(vc) == 'number' and vc >= 0 then
            return (vc >= 0 and vc <= 7) or (vc >= 9 and vc <= 12) or (vc >= 17 and vc <= 20)
        end
    end

    -- 3) CFX server native: GetVehicleType(veh)
    if rawget(_G, 'GetVehicleType') then
        local ok, vtype = pcall(GetVehicleType, veh)
        if ok and type(vtype) == 'string' then
            if vtype == 'automobile' or vtype == 'trailer' then
                return true
            elseif vtype == 'bike' or vtype == 'boat' or vtype == 'heli' or vtype == 'plane' or vtype == 'submarine' or vtype == 'train' then
                return false
            end
        end
    end

    return true
end

--- Distância máxima jogador↔veículo aceite p/ levantar (config client + margem).
local function maxRaiseDist()
    return (tonumber(Config.Jackstand and Config.Jackstand.MaxCarDistance) or 5.0) + 2.0
end

-- ─── requestRaise ──────────────────────────────────────────────────────────────
-- req:  ('vp_chopshop:session:requestRaise', vehicleNetId)
-- ok:   { ok=true, sessionId=<cs:n>, vsid=<vsid:n>, already=<bool> }
-- deny: { ok=false, err='disabled'|'player'|'cooldown'|'net'|'vehicle'|'class'
--                       |'range'|'no_item'|'session' }
local function denyRaise(src, netId, err)
    print(('[vp_chopshop][jackstand] requestRaise DENIED for src %s (netId %s): %s'):format(tostring(src), tostring(netId), tostring(err)))
    return { ok = false, err = err }
end

lib.callback.register('vp_chopshop:session:requestRaise', function(src, netId)
    if not (Config.Jackstand and Config.Jackstand.Enable) then return denyRaise(src, netId, 'disabled') end
    if not ServerPlayerIsReady(src) then return denyRaise(src, netId, 'player') end

    local now = GetGameTimer()
    if _raiseCd[src] and now < _raiseCd[src] then return denyRaise(src, netId, 'cooldown') end
    _raiseCd[src] = now + RAISE_CD_MS

    netId = tonumber(netId)
    if not netId then return denyRaise(src, netId, 'net') end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return denyRaise(src, netId, 'vehicle') end
    if not isJackableClass(veh) then return denyRaise(src, netId, 'class') end
    if not ValidatePlayerNearVehicle(src, veh, maxRaiseDist()) then return denyRaise(src, netId, 'range') end

    -- Item exigido (trust-no-client — o export client só implica posse).
    local item = Config.Jackstand.Item or 'chopshop_jackstand'
    if (tonumber(InvCount(src, item)) or 0) < 1 then return denyRaise(src, netId, 'no_item') end

    -- Create pode negar: 'disabled' / 'completed' / 'carcass_consumed' / 'vehicle'
    local session, err = ChopSession.Create(netId, src)
    if not session then return denyRaise(src, netId, err or 'session') end

    if not ChopSession.AddParticipant(session.id, src) then
        return denyRaise(src, netId, 'session')
    end

    local already = session.raised == true
    if not already then
        if not ChopSession.MarkRaised(session.id, src) then
            return denyRaise(src, netId, 'session')
        end
    else
        ChopSession.Touch(session.id)
    end

    return {
        ok        = true,
        sessionId = session.id,
        vsid      = session.vehicle.identity,
        already   = already,
    }
end)

-- ─── requestLower ─────────────────────────────────────────────────────────────
-- req:  ('vp_chopshop:session:requestLower', vehicleNetId)
-- ok:   { ok=true }              baixou (raised limpo)
-- ok:   { ok=true, stale=true }  sessão já sumiu — o client limpa o visual mesmo assim
-- deny: { ok=false, err='player'|'net'|'not_participant' }
lib.callback.register('vp_chopshop:session:requestLower', function(src, netId)
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    netId = tonumber(netId)
    if not netId then return { ok = false, err = 'net' } end

    local session = ChopSession.GetByVehicle(netId)
    if not session then
        -- Sessão já foi invalidada (veículo removido / timeout). O client ainda
        -- precisa limpar o visual dele → devolve ok+stale.
        return { ok = true, stale = true }
    end
    -- [v1.15 #5] Autorização EXPLÍCITA: só participante da sessão baixa o veículo.
    -- Proximidade não é bypass — ajuda externa seria regra de gameplay explícita.
    if not ChopSession.HasParticipant(session.id, src) then
        return { ok = false, err = 'not_participant' }
    end

    ChopSession.ClearRaised(session.id)
    return { ok = true }
end)

-- ─── isRaised (consulta de UX; não-autoritativa por si só) ─────────────────────
lib.callback.register('vp_chopshop:session:isRaised', function(src, netId)
    netId = tonumber(netId)
    if not netId then return { raised = false } end
    return { raised = ChopSession.IsRaised(netId) }
end)

-- ─── [v1.15 PR-F] getActive — READ-ONLY: sessionId ativo de um veículo ─────────
-- Só p/ o client obter o sessionId antes de vp_chopshop:action:start. NUNCA cria
-- sessão (payload cru). Devolve nil se não há sessão ativa / não-participante.
lib.callback.register('vp_chopshop:session:getActive', function(src, netId)
    if not ServerPlayerIsReady(src) then return { ok = false } end
    netId = tonumber(netId)
    if not netId then return { ok = false } end
    local s = ChopSession.GetByVehicle(netId)                 -- ACTIVE lookup (terminal → nil)
    if not s then return { ok = false } end
    if not ChopSession.HasParticipant(s.id, src) then return { ok = false, err = 'not_participant' } end
    return { ok = true, sessionId = s.id, raised = s.raised == true }
end)
