-- server/session/base_state.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-B] Camada de FACHADA do estado de peça do BASE CHOP sobre a
--  ChopSession. Antes: server/chop.lua guardava `ChoppedByNetId[netId][partKey]`.
--  Agora a fonte de verdade é `ChopSession.parts`; server/chop.lua delega aqui.
--
--  Só o BASE CHOP usa isto. AdvState (advanced_chop.lua) NÃO migrado nesta PR.
--  Não espalha acesso a `session.parts` — todo o toque na ChopSession vive aqui.
--
--  Participação: NÃO adiciona o chamador como participante. Participação nasce
--  só por quem INICIA o chop (ChopSession.Create adiciona o criador) ou por
--  vp_chopshop:session:requestRaise (jackstand). markPart de um 2º jogador que
--  chega depois NÃO o torna participante (não abre bypass p/ o gate do adv chop).
-- ═══════════════════════════════════════════════════════════════════════════════

VPChopBaseState = {}

--- @param netId integer
--- @param partKey string
--- @return boolean   -- true se a peça já foi removida (REMOVED) na sessão ativa
function VPChopBaseState.wasChopped(netId, partKey)
    local s = ChopSession.GetByVehicle(netId)     -- ACTIVE lookup (terminal → nil)
    return s ~= nil and ChopSession.GetPartState(s.id, partKey) == 'REMOVED'
end

--- Marca a peça. Resolve a sessão ativa OU cria uma (só chamar APÓS as validações
--- de veículo/proximidade de tryPartInner). Create adiciona só o criador como
--- participante.
--- @param src number
--- @param netId integer
--- @param partKey string
--- @return boolean ok, boolean duplicate, string|nil err
function VPChopBaseState.markPart(src, netId, partKey)
    -- [v1.15 PR-B follow-up] Master switch bloqueia NOVAS mutações/recompensas,
    -- inclusive em sessão já aberta (reads / discard / cleanup continuam).
    if Config.ChopSession and Config.ChopSession.Enable == false then
        return false, false, 'disabled'
    end
    local s = ChopSession.GetByVehicle(netId)
    if not s then
        local created, err = ChopSession.Create(netId, src)  -- pode negar 'completed'/'disabled'/'vehicle'
        if not created then return false, false, err or 'session' end
        s = created
    end
    local ok, dup = ChopSession.MarkPart(s.id, partKey, src)
    return ok, dup
end

--- @param netId integer
--- @return integer   -- nº de peças BASE removidas (só as que estão em session.parts;
---                       AdvState não conta — comportamento equivalente ao atual)
function VPChopBaseState.partCount(netId)
    local s = ChopSession.GetByVehicle(netId)
    if not s then return 0 end
    local c = 0
    for _ in pairs(s.parts) do c = c + 1 end
    return c
end

--- Conclusão do discard (ÚNICO call site: server/main.lua discardVehicle).
--- [v1.15 PR-B follow-up] O veículo foi efetivamente processado → a sessão vira
--- COMPLETED (não CANCELLED). Isso é um TOMBSTONE: enquanto o veículo original
--- ainda existir (ex.: DeleteEntity falhou após o pagamento), Create(netId)
--- devolve 'completed' → o mesmo carro não pode ser re-chopado. Quando a entidade
--- morrer de fato → entityRemoved → CleanupVehicle libera o netId.
--- (A PR D fará o fluxo completo: BridgeDeleteVehicle / owned guard / transaction.)
--- @param netId integer
--- @return boolean ok
function VPChopBaseState.clear(netId)
    local s = ChopSession.GetByVehicle(netId)     -- ACTIVE lookup: terminal → nil
    if not s then return true end                  -- nada a concluir
    if s.state == 'CREATED' then ChopSession.SetState(s.id, 'DISMANTLING') end
    if s.state ~= 'READY_FOR_DISCARD' then
        if not ChopSession.SetState(s.id, 'READY_FOR_DISCARD') then return false end
    end
    return ChopSession.Complete(s.id)
end
