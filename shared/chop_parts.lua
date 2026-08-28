-- shared/chop_parts.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 P1.2 / FASE B] ChopParts / ChopPartOrder são a PROJEÇÃO do Part Registry.
--
--  A definição RICA da peça (bones, tool, deps, gates, carry, reward, minigame…)
--  vive em shared/registry/parts.lua. Este arquivo é só a FACHADA LEGADA
--  `{ labelKey, kind, index }` que o resto do código ainda consome hoje
--  (client/main.lua, server/chop.lua, server/action/advanced_chop.lua, …).
--
--  A migração das FASEs C→F troca esses consumidores, um por vez, para lerem o
--  registry direto. Quando o último sair, este arquivo some.
--
--  Carregar como shared_script DEPOIS de shared/registry/parts.lua.
--  A paridade byte-a-byte (projeção == estas 10 peças) é provada por
--  shared/registry/registry_spec.lua.
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
