-- server/action/base_tyre.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-F] EXECUTOR de domínio da ActionSession p/ BASE TYRE (wheel_*).
--
--  ActionSession controla: lifecycle · ownership · timing · revalidação · action
--  lock · idempotência (replay).
--  ESTE executor controla o DOMÍNIO já existente, SEM duplicar código: delega a
--  `VPChopChopPartCommit` (server/main.lua) — que faz cooldown mark → MarkPart
--  (commit ANTES de reward) → tool durability → TyreEntitlement.Issue → rewards →
--  PART_CHOPPED → evidence → alarm → breakPart broadcast → Discord.
--
--  Chamado por ActionSession.Complete APÓS: revalidação completa + transição
--  OPEN → COMMITTING. Roda no máximo 1× por ActionSession (replay não re-executa).
--
--  Carregado DEPOIS de server/main.lua (usa VPChopChopPartCommit) — ver fxmanifest.
-- ═══════════════════════════════════════════════════════════════════════════════

--- @param act table   ActionSession { id, src, sessionId, vsid, netId, action, kind }
--- @return table       { ok, err?, result? }   result = { tyreEntitlementId }
local function executeBaseTyre(act)
    if type(VPChopChopPartCommit) ~= 'function' then
        return { ok = false, err = 'internal' }
    end
    local res = VPChopChopPartCommit(act.src, act.netId, act.action)
    if not res.ok then
        -- 'done' (outro player removeu a peça entre a revalidação e o commit),
        -- 'session'/'completed' (store autoritativo recusou), etc. → ActionSession
        -- fecha FAILED e NÃO produz reward/entitlement/PART_CHOPPED.
        return { ok = false, err = res.err or 'domain' }
    end
    return { ok = true, result = { tyreEntitlementId = res.tyreEntitlementId } }
end

if ActionSession and ActionSession.RegisterExecutor then
    ActionSession.RegisterExecutor('tyre', executeBaseTyre)
end
