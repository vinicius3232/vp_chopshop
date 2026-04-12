-- ============================================================
-- vp_chopshop — client/minigames.lua
-- Módulo de minigames para remoção de parafusos (jackstand).
-- Mantém a lógica de minigame isolada da lógica de desmanche.
--
-- API pública:
--   VPChopRunBoltMinigame(cfg) → boolean
--     cfg: tabela Config.Jackstand.Minigame (ou nil para defaults)
--     Retorna true se todos os rounds foram bem-sucedidos.
-- ============================================================

-- ─── Utilitários internos ────────────────────────────────────

--- Executa um único round de minigame com boii_minigames (async→sync via promise).
---@param cfg table Config.Jackstand.Minigame
---@return boolean
local function runBoiiRound(cfg)
    local p        = promise.new()
    local mgType   = cfg.Type or 'skill_circle'
    local timeout  = cfg.Timeout or 30000
    local resolved = false

    local function resolve(val)
        if not resolved then
            resolved = true
            p:resolve(val)
        end
    end

    if mgType == 'button_mash' then
        exports['boii_minigames']:button_mash({
            style      = 'default',
            difficulty = cfg.Difficulty or 12,
        }, function(success)
            resolve(success == true)
        end)
    else
        -- skill_circle (padrão)
        exports['boii_minigames']:skill_circle({
            style     = 'default',
            area_size = cfg.AreaSize or 5,
            speed     = cfg.Speed    or 0.025,
        }, function(result)
            resolve(result ~= 'failed')
        end)
    end

    -- Timeout de segurança: resolve false se boii não chamar o callback
    CreateThread(function()
        Wait(timeout)
        resolve(false)
    end)

    return Citizen.Await(p)
end

--- Executa um único round de fallback com lib.skillCheck (ox_lib).
---@param cfg table Config.Jackstand.Minigame
---@return boolean
local function runSkillCheckRound(cfg)
    local difficulties = cfg.SkillCheckDifficulties or { 'medium' }
    local keys         = cfg.SkillCheckKeys         or { 'e' }
    return lib.skillCheck(difficulties, keys)
end

--- Aplica FailureChance: chance extra de falhar mesmo passando no minigame.
---@param cfg table
---@param passed boolean resultado do minigame
---@return boolean
local function applyFailureChance(cfg, passed)
    if not passed then return false end
    local chance = cfg.FailureChance or 0.0
    if chance <= 0.0 then return true end
    return math.random() > chance
end

-- ─── Verificação de ferramenta ───────────────────────────────

--- Verifica se o jogador tem a ferramenta obrigatória no inventário.
--- Se RequiredTool for nil/false, sempre retorna true.
---@param cfg table
---@return boolean
local function checkRequiredTool(cfg)
    local tool = cfg.RequiredTool
    if not tool or tool == '' then return true end
    local count = exports.ox_inventory:Search('count', tool)
    return (count or 0) > 0
end

-- ─── API pública ─────────────────────────────────────────────

--- Executa o minigame de parafusos completo (N rounds).
--- Usa boii_minigames se disponível; caso contrário, lib.skillCheck.
---@param cfg table|nil  Config.Jackstand.Minigame (ou nil para defaults)
---@return boolean  true = sucesso em todos os rounds
function VPChopRunBoltMinigame(cfg)
    cfg = cfg or {}

    -- 1. Verificar ferramenta obrigatória
    if not checkRequiredTool(cfg) then
        local toolLabel = cfg.RequiredTool or '?'
        VPChopNotify(L('jackstand_no_tool') .. ' (' .. toolLabel .. ')', 'error')
        return false
    end

    local rounds   = cfg.Rounds or 4
    local useBoii  = GetResourceState('boii_minigames') == 'started'

    for i = 1, rounds do
        local passed

        if useBoii then
            passed = runBoiiRound(cfg)
        else
            passed = runSkillCheckRound(cfg)
        end

        passed = applyFailureChance(cfg, passed)

        if not passed then
            VPChopNotify(L('tyremission_minigame_fail'), 'error')
            return false
        end

        -- Pequena pausa entre rounds para feedback visual
        if i < rounds then Wait(300) end
    end

    return true
end
