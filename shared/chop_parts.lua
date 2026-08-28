-- shared/chop_parts.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 P1.6 / FASE F] O PART REGISTRY (shared/registry/parts.lua) é a
--  AUTORIDADE de definição de peça. Este arquivo é o ALIAS FINO legado:
--    · ChopParts / ChopPartOrder  — projeção `{ labelKey, kind, index }` das 10
--      peças GTA-native. Ainda consumido por client/main.lua (menus + matemática
--      de índice de roda) — migra em P2.1 junto com client/interaction.lua.
--    · VPChopPartGtaClass(id)      — o acessor que os consumidores SERVER usam no
--      lugar de `ChopParts[id] and ChopParts[id].kind`.
--
--  Nenhum código NOVO deve ler `ChopParts` — use `VPChopPartRegistry` direto.
--  Quando o client migrar, este arquivo some.
--
--  Carregar como shared_script DEPOIS de shared/registry/parts.lua. A paridade
--  byte-a-byte (projeção == as 10 peças) é provada por registry_spec.lua.
-- ═══════════════════════════════════════════════════════════════════════════════

---@class ChopPartDef
---@field labelKey string  locale key em shared/locale.lua
---@field kind 'door'|'tyre'
---@field index integer    índice de porta / roda GTA

if not (VPChopPartRegistry and VPChopPartRegistry.projectChopParts) then
    error('[vp_chopshop] shared/chop_parts.lua exige VPChopPartRegistry — conferir a ordem '
        .. 'no fxmanifest (shared/registry/parts.lua ANTES de shared/chop_parts.lua)')
end

--- `ChopParts`: table<string, ChopPartDef> · `ChopPartOrder`: string[] (ordem de menu)
ChopParts, ChopPartOrder = VPChopPartRegistry.projectChopParts()

--- Classe GTA de uma peça desmontável legada: 'door' | 'tyre', ou nil se `id` não
--- é uma das 10 peças nativas (peça sintética, desconhecida ou desabilitada).
--- Substitui o padrão `local d = ChopParts[id]; if d and d.kind == 'x'` nos
--- consumidores server — sem `ChopParts` exposto a código novo.
---@param id string
---@return 'door'|'tyre'|nil
function VPChopPartGtaClass(id)
    local d = ChopParts[id]
    return d and d.kind or nil
end
