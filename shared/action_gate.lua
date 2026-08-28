-- shared/action_gate.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-G] Predicate ÚNICO (client + server) que decide se um fluxo usa a
--  ActionSession ou o caminho LEGACY. Garante EXCLUSIVIDADE: nunca os dois ao
--  mesmo tempo.
--
--    BASE TYRE  → ActionSession sse:  ActionSession.Enable ~= false
--                                     E RequireBaseTyres  ~= false
--    ADVANCED   → ActionSession sse:  ActionSession.Enable ~= false
--                                     E RequireAdvanced   ~= false
--                                     E NÃO EnforceRaised == false   (compat legacy)
--
--  `Config.ChopSession.EnforceRaised == false` = COMPATIBILITY / EMERGENCY MODE
--  para advanced: sem jackstand, sem participante — a ChopSession CONTINUA sendo o
--  state store obrigatório (via advGate compat + ensureSession). Nesse modo a
--  proteção TEMPORAL da ActionSession (start→UX→complete + minDuration) fica
--  REDUZIDA para advanced; existe só como fallback.
-- ═══════════════════════════════════════════════════════════════════════════════

--- @return boolean
function VPChopActionModeTyre()
    local a = Config and Config.ActionSession
    return (a and a.Enable ~= false and a.RequireBaseTyres ~= false) == true
end

--- @return boolean
function VPChopActionModeAdvanced()
    local a = Config and Config.ActionSession
    local c = Config and Config.ChopSession
    if not (a and a.Enable ~= false and a.RequireAdvanced ~= false) then return false end
    if c and c.EnforceRaised == false then return false end   -- compat legacy mode
    return true
end
