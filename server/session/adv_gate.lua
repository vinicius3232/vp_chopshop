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
--  Este módulo é SÓ o gate de autoridade. O estado de peça / mutex do advanced
--  vive em server/session/advanced_state.lua (PR-C).
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
    -- [v1.15 PR-C] Master switch cedo: com o módulo desligado o callback nem chega
    -- a consumir ferramenta (consumeSaw/drill rodam DEPOIS do gate).
    if Config.ChopSession and Config.ChopSession.Enable == false then
        return false, 'disabled'
    end
    -- READ-ONLY: nunca cria sessão (payload cru). ACTIVE lookup (terminal → nil).
    local session = ChopSession.GetByVehicle(netId)

    -- [v1.15 PR-C] EnforceRaised=false = compatibilidade: pula APENAS o requisito
    -- de `raised` + participante/jackstand. A ChopSession CONTINUA sendo a fonte
    -- obrigatória de STATE — o callback resolve/cria a sessão (via
    -- VPChopAdvancedState.ensureSession) DEPOIS de validar entidade/distância.
    if Config.ChopSession and Config.ChopSession.EnforceRaised == false then
        return true, nil, session and session.id or nil
    end

    if not session or session.raised ~= true then
        return false, 'not_raised'
    end
    if not ChopSession.HasParticipant(session.id, src) then
        return false, 'not_participant'
    end
    return true, nil, session.id
end
