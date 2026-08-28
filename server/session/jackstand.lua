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
    local vc = GetVehicleClass(veh)
    return (vc >= 0 and vc <= 7) or (vc >= 9 and vc <= 12) or (vc >= 17 and vc <= 20)
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
lib.callback.register('vp_chopshop:session:requestRaise', function(src, netId)
    if not (Config.Jackstand and Config.Jackstand.Enable) then return { ok = false, err = 'disabled' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    local now = GetGameTimer()
    if _raiseCd[src] and now < _raiseCd[src] then return { ok = false, err = 'cooldown' } end
    _raiseCd[src] = now + RAISE_CD_MS

    netId = tonumber(netId)
    if not netId then return { ok = false, err = 'net' } end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return { ok = false, err = 'vehicle' } end
    if not isJackableClass(veh) then return { ok = false, err = 'class' } end
    if not ValidatePlayerNearVehicle(src, veh, maxRaiseDist()) then return { ok = false, err = 'range' } end

    -- Item exigido (trust-no-client — o export client só implica posse).
    -- tonumber(...) or 0: se InvCount devolver nil (bridge de inventário ainda não
    -- pronta / framework não carregado) o check falha FECHADO, não aberto.
    local item = Config.Jackstand.Item or 'chopshop_jackstand'
    if (tonumber(InvCount(src, item)) or 0) < 1 then return { ok = false, err = 'no_item' } end

    -- Create pode negar: 'disabled' / 'completed' (sessão concluída, veículo ainda
    -- existe) / 'vehicle'. CANCELLED é reutilizável → Create cunha nova por dentro.
    local session, err = ChopSession.Create(netId, src)
    if not session then return { ok = false, err = err or 'session' } end

    -- [v1.15 #2] Checar EXPLICITAMENTE cada mutação — nunca responder ok se a
    -- sessão recusou (ex.: terminou entre o Create e aqui).
    if not ChopSession.AddParticipant(session.id, src) then
        return { ok = false, err = 'session' }
    end

    local already = session.raised == true
    if not already then
        if not ChopSession.MarkRaised(session.id, src) then
            return { ok = false, err = 'session' }
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
