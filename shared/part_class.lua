-- shared/part_class.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 P2.1 / FASE F concluída] `VPChopPartGtaClass(id)` — o ÚNICO acessor
--  legado que restou. A definição de peça (rica) vive no Part Registry
--  (shared/registry/parts.lua) e os consumidores server + client leem-no direto.
--
--  Os globais `ChopParts` / `ChopPartOrder` FORAM REMOVIDOS — nada mais os usa.
--
--  Carregar como shared_script DEPOIS de shared/registry/parts.lua.
-- ═══════════════════════════════════════════════════════════════════════════════

if not (VPChopPartRegistry and VPChopPartRegistry.get) then
    error('[vp_chopshop] shared/part_class.lua exige VPChopPartRegistry — conferir a '
        .. 'ordem no fxmanifest (shared/registry/parts.lua ANTES).')
end

--- Classe GTA de uma peça desmontável nativa: 'door' | 'tyre', ou nil se `id` não
--- é uma das 10 peças GTA (peça sintética como adv_engine/adv_carcass, ou id
--- desconhecido). NÃO checa `enabled` — isso é responsabilidade de quem valida a
--- ação (registryValidate). Substitui o antigo `ChopParts[id] and ChopParts[id].kind`.
---@param id string
---@return 'door'|'tyre'|nil
function VPChopPartGtaClass(id)
    local d = VPChopPartRegistry.get(id)
    return d and d.gtaClass or nil
end
