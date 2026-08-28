-- shared/registry/tools.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [SPIKE PR-I · schema v2] TOOL REGISTRY — fonte ÚNICA de definição de ferramenta.
--
--  "Ferramenta" AQUI = item consumível do ox_inventory que VPChopHasTool/
--  VPChopConsumeTool (server/main.lua) já reconhecem: saw_cheap, saw_pro,
--  mechanic_drill. Split de VPChopHasTool: mechanic_drill = 'screw'; resto = 'cut'.
--
--  NÃO são tools (são GATES — modelados no Part Registry, não aqui):
--    · welder            → VPChopWelderNearVehicle (proximidade de world object)
--    · chopshop_jackstand → server/session/jackstand.lua (sistema próprio)
--  NÃO existem no runtime (config MORTA — VPChopHasTool nunca lê):
--    · metal_saw / screwdriver  (Config.AdvancedChop.SawItem/ScrewdriverItem)
--
--  INERTE — nada consome. Objetivo: travar a FORMA. Carregar ANTES de parts.lua.
-- ═══════════════════════════════════════════════════════════════════════════════

---@class ToolDefinition
---@field id string                       -- item ox_inventory
---@field class 'cut'|'screw'              -- família REAL (ver R.RESERVED p/ futuras)
---@field maxUses integer                  -- durabilidade; default 6 (== VPChopConsumeTool). metadata key: 'uses_remaining'
---@field uxSpeed number                   -- multiplicador da BARRA DE PROGRESSO do client. NUNCA toca action.minDurationMs.
---@field noise number                     -- 0..1  (Heat V2)
---@field dispatchChance number            -- 0..1  (client-side hoje)
---@field breakChance number               -- 0..1  (futuro; 0 = só esgota por maxUses)
---@field requiredTier integer             -- futuro (1 = sem gate)
---@field handProp { model:string, offset:number[], rotation:number[] }|nil

_G.VPChopToolRegistry = _G.VPChopToolRegistry or {}
local R = _G.VPChopToolRegistry

R.defs = {
    saw_cheap = {
        id = 'saw_cheap', class = 'cut',
        maxUses = 2,  uxSpeed = 1.4, noise = 0.9, dispatchChance = 1.0, breakChance = 0.0, requiredTier = 1,
        handProp = { model = 'prop_tool_consaw', offset = { 0.05, 0.02, 0.0 }, rotation = { 20, 0, -50 } },
    },
    saw_pro = {
        id = 'saw_pro', class = 'cut',
        maxUses = 6,  uxSpeed = 1.0, noise = 0.6, dispatchChance = 0.25, breakChance = 0.0, requiredTier = 2,
        handProp = { model = 'prop_tool_consaw', offset = { 0.05, 0.02, 0.0 }, rotation = { 20, 0, -50 } },
    },
    mechanic_drill = {
        id = 'mechanic_drill', class = 'screw',
        maxUses = 10, uxSpeed = 0.7, noise = 0.3, dispatchChance = 0.0, breakChance = 0.0, requiredTier = 2,
        handProp = { model = 'prop_tool_screwflt01', offset = { 0.10, 0.03, 0.0 }, rotation = { 10, 0, -30 } },
    },
}

--- Classes REAIS (derivadas dos defs). O Part Registry só pode exigir uma destas (ou nil).
R.CLASSES = (function()
    local c = {}
    for _, d in pairs(R.defs) do c[d.class] = true end
    return c
end)()

--- Classes RESERVADAS p/ o futuro (documentação — nenhum tool ainda). NÃO válidas em toolClass.
R.RESERVED = { weld = true, lift = true, scan = true, hack = true }

---@param id string
---@return ToolDefinition|nil
function R.get(id) return R.defs[id] end

--- Itens de uma classe. `part.toolClass` → estes.  (Sentido ÚNICO: peça → classe → itens.)
---@param class string
---@return string[] ids  (ordenado)
function R.forClass(class)
    local out = {}
    for id, d in pairs(R.defs) do if d.class == class then out[#out + 1] = id end end
    table.sort(out)
    return out
end

--- wantDrill de VPChopHasTool(src, wantDrill): 'screw' → true, 'cut' → false.
---@param class string|nil
---@return boolean|nil  -- nil se a classe não exige item (toolClass=nil)
function R.wantDrill(class)
    if class == nil then return nil end
    return class == 'screw'
end

return R
