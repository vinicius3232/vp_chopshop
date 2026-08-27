-- server/session/adv_gate.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 P1-1] Gate de AUTORIDADE do jackstand para o desmanche AVANÇADO.
--
--  ANTES: server/advanced_chop.lua tinha "requer jackstand levantado" no
--  cabeçalho mas NENHUM callback verificava — um lua executor chamava
--  vp_chopshop:adv:chopPart/chopEngine/chopCarcass sem carro no macaco.
--
--  AGORA: exige ChopSession ATIVA para o veículo + `raised == true` + jogador
--  REGISTRADO como participante da sessão.
--
--  Escopo desta PR: SÓ este gate. NÃO migra AdvState/AdvMutex/rewards/tools.
--  Participação nasce só pelo fluxo legítimo (vp_chopshop:session:requestRaise
--  — inclusive um 2º jogador que peça raise num carro já levantado vira
--  participante). Chamar adv:* NUNCA adiciona ninguém à sessão.
-- ═══════════════════════════════════════════════════════════════════════════════

--- SEM side effect de lifecycle: o gate só LÊ. Quem renova `lastActivity` é o
--- callback, no ponto terminal de sucesso (junto de markChopped) — via o
--- `sessionId` devolvido aqui. Assim spam de tentativas que falham depois
--- (distância, part, tool, mutex) não mantém a sessão viva.
--- @param src number
--- @param netId integer
--- @return boolean ok, string|nil err, string|nil sessionId
function VPChopAdvRequireRaisedSession(src, netId)
    -- Kill-switch de compatibilidade — comportamento legacy (sem gate de sessão).
    if Config.ChopSession and Config.ChopSession.EnforceRaised == false then
        return true, nil, nil
    end
    -- ACTIVE lookup: sessão terminal (CANCELLED/COMPLETED) → nil → not_raised.
    local session = ChopSession.GetByVehicle(netId)
    if not session or session.raised ~= true then
        return false, 'not_raised'
    end
    if not ChopSession.HasParticipant(session.id, src) then
        return false, 'not_participant'
    end
    return true, nil, session.id
end
