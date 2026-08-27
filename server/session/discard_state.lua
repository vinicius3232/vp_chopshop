-- server/session/discard_state.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-D] Fachada da OPERAÇÃO TERMINAL de descarte sobre a ChopSession.
--  Antes: server/main.lua fazia PAY → CLEAR → EVENT → DeleteEntity inline, sem
--  máquina de transação e contando só peças base.
--
--  Agora:
--    • contagem UNIFICADA base+advanced (a mesma session.parts desde a PR-C);
--    • BEGIN = SetState(READY_FOR_DISCARD) → FREEZE (MarkPart/LockPart recusam
--      'discarding' enquanto durar o payout — ver chop_session.lua PR-D);
--    • ROLLBACK = READY_FOR_DISCARD → DISMANTLING se o pagamento falhar (nada perdido);
--    • COMPLETE = Complete() → COMPLETED (tombstone permanente; não reabre).
--
--  Ownership / deleção de entidade NÃO ficam aqui — isso é bridge/server_vehicle.lua.
--  Esta fachada só orquestra o ESTADO da sessão.
-- ═══════════════════════════════════════════════════════════════════════════════

VPChopDiscardState = {}

--- @param netId integer
--- @return string|nil sessionId, table|nil session
function VPChopDiscardState.resolve(netId)
    local s = ChopSession.GetByVehicle(netId)   -- ACTIVE lookup (terminal → nil)
    if not s then return nil, nil end
    return s.id, s
end

--- Contagem para observabilidade + gate de MinPartsToDiscard (usa `total`).
--- @param sessionId string
--- @return { total: integer, base: integer, advanced: integer }
function VPChopDiscardState.getCounts(sessionId)
    return {
        total    = ChopSession.CountParts(sessionId),
        base     = ChopSession.CountParts(sessionId, 'base'),
        advanced = ChopSession.CountParts(sessionId, 'advanced'),
    }
end

--- Entra na operação terminal: SetState(READY_FOR_DISCARD). A partir daqui a
--- sessão está CONGELADA (nenhuma peça nova; nenhum lock físico novo).
--- Idempotente. NÃO paga nada — só transita o estado.
--- @param sessionId string
--- @return boolean ok, string|nil err
function VPChopDiscardState.begin(sessionId)
    local s = ChopSession.Get(sessionId)          -- ACTIVE (terminal → nil)
    if not s then return false, 'no_session' end
    if s.state == 'READY_FOR_DISCARD' then return true end   -- idempotente
    if s.state == 'CREATED' or s.state == 'RAISED' then
        local ok = ChopSession.SetState(sessionId, 'DISMANTLING')
        if not ok then return false, 'state' end
    end
    local ok = ChopSession.SetState(sessionId, 'READY_FOR_DISCARD')
    if not ok then return false, 'state' end
    return true
end

--- Pagamento falhou → sai da operação terminal, sessão volta a desmontável.
--- Nada foi pago, nada foi deletado, nenhuma peça perdida.
--- @param sessionId string
--- @return boolean ok
function VPChopDiscardState.rollback(sessionId)
    local s = ChopSession.Get(sessionId)
    if not s then return false end
    if s.state == 'READY_FOR_DISCARD' then
        return ChopSession.SetState(sessionId, 'DISMANTLING') == true
    end
    return true
end

--- Fecha a sessão: READY_FOR_DISCARD → COMPLETED. Tombstone permanente enquanto
--- a entidade existir (bloqueia re-chop mesmo se a deleção de mundo falhar).
--- @param sessionId string
--- @return boolean ok, string|nil err
function VPChopDiscardState.complete(sessionId)
    return ChopSession.Complete(sessionId)
end
