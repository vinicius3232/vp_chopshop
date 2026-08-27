-- server/session/advanced_state.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-C] Fachada do estado de peça do ADVANCED CHOP sobre a ChopSession.
--  Antes: server/advanced_chop.lua guardava `AdvState[netId][key]` + mutex
--  `AdvMutex[netId:key]`. Ambos REMOVIDOS. A fonte de verdade agora é
--  `ChopSession.parts` — a MESMA do base chop (uma única fonte server-authoritative).
--
--  Peças advanced são registradas com `origin='advanced'`; base com `origin='base'`.
--  `VPChopGetPartCount` (discard) continua contando SÓ base até a PR D (unified discard).
--
--  Não espalha `session.parts` por advanced_chop.lua — todo toque na ChopSession
--  passa por aqui.
-- ═══════════════════════════════════════════════════════════════════════════════

VPChopAdvancedState = {}

--- @param sessionId string
--- @param partKey string
--- @return boolean   -- true se a peça já foi removida nesta sessão
function VPChopAdvancedState.wasRemoved(sessionId, partKey)
    return ChopSession.GetPartState(sessionId, partKey) == 'REMOVED'
end

--- Resolve a ChopSession ativa do veículo OU cria uma. SÓ chamar APÓS validar
--- entidade/distância no callback (nunca ao receber o payload cru). Usado só no
--- caminho de compatibilidade EnforceRaised=false — no fluxo normal o gate já
--- devolve o sessionId.
--- @param netId integer
--- @param src number
--- @return string|nil sessionId
function VPChopAdvancedState.ensureSession(netId, src)
    local s = ChopSession.GetByVehicle(netId)
    if s then return s.id end
    local created = ChopSession.Create(netId, src)   -- Create adiciona `src` como participante inicial
    return created and created.id or nil
end

--- Commit autoritativo da peça advanced. Master switch bloqueia NOVAS mutações
--- inclusive em sessão já aberta.
--- @param sessionId string
--- @param src number
--- @param partKey string
--- @return boolean ok, boolean duplicate
function VPChopAdvancedState.markPart(sessionId, src, partKey)
    if Config.ChopSession and Config.ChopSession.Enable == false then
        return false, false
    end
    return ChopSession.MarkPart(sessionId, partKey, src, { origin = 'advanced' })
end

--- Mutex por (sessão, peça) — token de uso único, TTL da ChopSession.
--- @param sessionId string
--- @param partKey string
--- @return boolean ok, string|nil token
function VPChopAdvancedState.lockPart(sessionId, partKey)
    return ChopSession.LockPart(sessionId, partKey)
end

--- @param sessionId string
--- @param partKey string
--- @param token string
--- @return boolean
function VPChopAdvancedState.unlockPart(sessionId, partKey, token)
    return ChopSession.UnlockPart(sessionId, partKey, token)
end
