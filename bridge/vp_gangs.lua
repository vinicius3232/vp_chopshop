-- bridge/vp_gangs.lua
-- ══════════════════════════════════════════════════════════════════════════════
--  CAMADA DE INTEGRAÇÃO vp_chopshop → vp_gangs  (contractVersion = 1)
--
--  ÚNICO lugar do vp_chopshop que conhece `exports.vp_gangs`. Escuta o evento
--  INTERNO VPChopEvt.PART_CHOPPED (disparado PÓS-COMMIT — a peça já está
--  MarkChopped em server/chop.lua|advanced_chop.lua) e publica uma "atividade de
--  desmanche válida" pelo CONTRATO PÚBLICO do vp_gangs
--  (`exports.vp_gangs:recordExternalCrime(src, payload)`).
--
--  CAMINHO ÚNICO (INT-01C fechou o cutover — não há mais fallback legado):
--    PART_CHOPPED → bridge/vp_gangs.lua → recordExternalCrime → adapter
--    'vp_chopshop' (config/external.lua) → ExternalBridge → rewardGangActivity
--    INTERNO do vp_gangs.
--  O vp_chopshop NUNCA chama rewardGangActivity direto.
--
--  NÃO envia:  payout / valor / placa / netId-como-identidade /
--              citizenid-como-autoridade / internals (mutex, ChopSession, ...).
--  O vp_gangs resolve jogador/gang/citizenid SERVER-SIDE a partir do `src`.
--
--  Falha da integração NUNCA altera o desmanche — o evento já é pós-commit
--  ("Falha da emissão NÃO derruba o chop", server/main.lua). Qualquer
--  erro/rejeição do contrato (forbidden_caller / adapter_disabled /
--  bridge_disabled / version_unsupported / bad_payload / no_gang / not_official /
--  replay / dedup_capacity / pcall_error / no_result / vp_gangs_stopped) é
--  SÓ diagnóstico.
--
--  FILTRO — só os mesmos marcos que o call cru antigo (server/progression.lua)
--  creditava: phase 1-4 de PEÇA REAL. `vin_scratch` (phase 0) e `plate_theft`
--  (phase 1) NÃO emitem (o listener de progressão os remapeia p/ reason próprio,
--  fora de {phase1..phase4}).
--
--  IDEMPOTÊNCIA — operationId = ChopSession.id + partKey + phase (domínio-derivado).
--  Dedup do lado vp_gangs (server/external_dedup.lua): replay/concorrência
--  protegidos enquanto a entrada estiver retida (até o TTL, e no restart do
--  vp_chopshop o namespace de dedup é limpo). cross-restart NÃO garantido —
--  `_sidSeq` reseta no boot; sem identidade FÍSICA persistente de peça ainda
--  (roadmap vp_chopshop: vehicle_part / sourceSession). NÃO usamos
--  netId / placa / timestamp como substituto fraco.
-- ══════════════════════════════════════════════════════════════════════════════

local CONTRACT_VERSION = 1
local CRIME            = 'part_chopped'

--- Este (partKey, phase) é um marco que o crédito de gang cobre?
--- Espelha EXATAMENTE o gate de server/progression.lua (reason ∈ {phase1..phase4}).
---@param partKey any
---@param phase any
---@return boolean
function VPChopGangsShouldEmit(partKey, phase)
    if type(partKey) ~= 'string' or partKey == '' then return false end
    local reason
    if partKey == 'vin_scratch' then
        reason = 'vin_scratch'
    elseif partKey == 'plate_theft' then
        reason = 'plate_theft'
    else
        reason = 'phase' .. tostring(phase)
    end
    return reason == 'phase1' or reason == 'phase2' or reason == 'phase3' or reason == 'phase4'
end

--- operationId domínio-derivado. nil se não há ChopSession ativa p/ o veículo
--- (fail-closed — não inventamos identidade).
---@return string|nil
function VPChopGangsOperationId(netId, partKey, phase)
    local CS = rawget(_G, 'ChopSession')
    local s = CS and CS.GetByVehicle and CS.GetByVehicle(netId)
    if not (s and s.id) then return nil end
    return ('%s:%s:p%s'):format(tostring(s.id), tostring(partKey), tostring(phase))
end

--- Payload V1 — mínimo. Sem amount/plate/netId/citizenid/internals.
---@return table
function VPChopGangsBuildPayload(operationId, partKey, phase)
    return {
        contractVersion = CONTRACT_VERSION,
        crime           = CRIME,
        operationId     = operationId,
        partKey         = partKey,
        phase           = tonumber(phase) or 0,
    }
end

--- Entrega ao vp_gangs pelo contrato público. Fail-safe: resource parado /
--- export ausente / erro / rejeição → SÓ diagnóstico, nunca propaga p/ o domínio
--- e NUNCA credita gang por outro caminho.
---@return table
function VPChopGangsDispatch(src, payload)
    if GetResourceState('vp_gangs') ~= 'started' then
        return { ok = false, reason = 'vp_gangs_stopped' }
    end

    local ok, res = pcall(function()
        return exports.vp_gangs:recordExternalCrime(src, payload)
    end)

    if ok and type(res) == 'table' and res.ok then
        print(('[vp_chopshop][int:vp_gangs] emit ok  op=%s part=%s phase=%s')
            :format(tostring(payload.operationId), tostring(payload.partKey), tostring(payload.phase)))
        return res
    end

    local reason = (type(res) == 'table' and res.reason)
        or (not ok and 'pcall_error')
        or 'no_result'

    print(('[vp_chopshop][int:vp_gangs] sem crédito (%s) op=%s'):format(reason, tostring(payload.operationId)))
    return (type(res) == 'table' and res) or { ok = false, reason = reason }
end

--- Handler do evento interno VPChopEvt.PART_CHOPPED.
function VPChopGangsOnPartChopped(src, netId, partKey, phase)
    if not VPChopGangsShouldEmit(partKey, phase) then return end
    local operationId = VPChopGangsOperationId(netId, partKey, phase)
    if not operationId then
        print(('[vp_chopshop][int:vp_gangs] sem ChopSession p/ netId=%s — não emite'):format(tostring(netId)))
        return
    end
    VPChopGangsDispatch(src, VPChopGangsBuildPayload(operationId, partKey, phase))
end

AddEventHandler(VPChopEvt.PART_CHOPPED, VPChopGangsOnPartChopped)
