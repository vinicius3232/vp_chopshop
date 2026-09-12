-- shared/compatibility.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.21 P7.2] PART COMPATIBILITY ENGINE
--  Matriz canônica de compatibilidade mecânica entre famílias de motores,
--  painéis de carroceria, suspensões e chassis veiculares.
-- ═══════════════════════════════════════════════════════════════════════════════

PartCompatibility = PartCompatibility or {}

local _mock = nil

local function getConfig()
    local cfg = Config and Config.PartCompatibility
    if type(cfg) ~= 'table' then
        return {
            Enable = true,
            EngineFamilies = {
                ['v8_heavy'] = {
                    label = 'Motor V8 de Alta Cilindrada',
                    models = { 'sultanrs', 'banshee', 'buffalo4', 'dominator', 'coquette', 'gauntlet' },
                    classes = { 4, 7 },
                    minChassisStrength = 80.0,
                },
                ['i4_compact'] = {
                    label = 'Motor 4 Cilindros em Linha',
                    models = { 'blista', 'panto', 'asbo', 'prairie', 'brioso', 'dilettante', 'rhapsody' },
                    classes = { 0, 1 },
                    minChassisStrength = 40.0,
                },
                ['v6_suv'] = {
                    label = 'Motor V6 Utilitário / Tração Integral',
                    models = { 'baller', 'bison', 'granger', 'cavalcade', 'seminole', 'landstalker', 'dubsta' },
                    classes = { 2, 9 },
                    minChassisStrength = 65.0,
                },
            },
        }
    end
    return cfg
end

local function normalizeString(str)
    if not str or type(str) ~= 'string' then return '' end
    return str:gsub('%s+', ''):lower()
end

--- Identifica a família mecânica de um motor com base no modelo ou classe veicular
---@param model string|nil
---@param class number|nil
---@return string? familyKey, table? familyData
function PartCompatibility.GetEngineFamily(model, class)
    if _mock and _mock.GetEngineFamily then
        return _mock.GetEngineFamily(model, class)
    end

    local cfg = getConfig()
    if cfg.Enable == false or not cfg.EngineFamilies then
        return nil, nil
    end

    local cleanModel = normalizeString(model)
    local numClass = tonumber(class)

    -- 1. Match exato por modelo registrado
    if cleanModel ~= '' then
        for fKey, fData in pairs(cfg.EngineFamilies) do
            if fData.models then
                for _, m in ipairs(fData.models) do
                    if normalizeString(m) == cleanModel then
                        return fKey, fData
                    end
                end
            end
        end
    end

    -- 2. Match por classe veicular
    if numClass then
        for fKey, fData in pairs(cfg.EngineFamilies) do
            if fData.classes then
                for _, c in ipairs(fData.classes) do
                    if tonumber(c) == numClass then
                        return fKey, fData
                    end
                end
            end
        end
    end

    return nil, nil
end

--- Valida se uma peça específica pode ser instalada fisicamente em um modelo/chassi alvo
---@param partType string
---@param partData table { sourceModel?: string, vehicleClass?: number, conditionPct?: number }
---@param targetModel string
---@param targetClass? number
---@return boolean canFit, string reason
function PartCompatibility.CanFit(partType, partData, targetModel, targetClass)
    if not partType or type(partType) ~= 'string' or partType == '' then
        return false, 'invalid_part_type'
    end
    if not targetModel or type(targetModel) ~= 'string' or targetModel == '' then
        return false, 'invalid_target_model'
    end

    if _mock and _mock.CanFit then
        return _mock.CanFit(partType, partData, targetModel, targetClass)
    end

    local cfg = getConfig()
    if cfg.Enable == false then
        return true, 'compatibility_disabled'
    end

    partData = partData or {}
    local cleanTargetModel = normalizeString(targetModel)
    local numTargetClass = tonumber(targetClass) or 0

    -- ─── 1. Motores (`adv_engine` ou `engine`) ──────────────────────────────────
    if partType == 'adv_engine' or partType == 'engine' then
        local srcFamily, srcFamilyData = PartCompatibility.GetEngineFamily(partData.sourceModel, partData.vehicleClass)
        local tgtFamily, tgtFamilyData = PartCompatibility.GetEngineFamily(cleanTargetModel, numTargetClass)

        if not srcFamily then
            return false, 'unknown_source_engine_family'
        end
        if not tgtFamily then
            return false, 'unknown_target_engine_family'
        end
        if srcFamily ~= tgtFamily then
            return false, ('incompatible_engine_family: %s cannot fit in %s'):format(srcFamily, tgtFamily)
        end

        return true, 'engine_compatible'
    end

    -- ─── 2. Pneus e Rodas (`chopshop_tyre` ou `tyre_*`) ─────────────────────────
    if partType == 'chopshop_tyre' or partType:find('^tyre') or partType:find('^wheel') then
        -- Motocicletas (classe 8) e Bicicletas (classe 13) rejeitam pneus automotivos
        if numTargetClass == 8 or numTargetClass == 13 then
            return false, 'incompatible_tyre_for_bike_class'
        end
        return true, 'tyre_compatible'
    end

    -- ─── 3. Painéis de Carroceria (`door_*`, `bonnet`, `boot`) ──────────────────
    if partType:find('^door') or partType == 'bonnet' or partType == 'boot' then
        local srcModel = normalizeString(partData.sourceModel)
        -- Match de modelo idêntico é sempre 100% perfeito
        if srcModel ~= '' and srcModel == cleanTargetModel then
            return true, 'direct_chassis_match'
        end

        -- Se a classe for diferente, painéis externos não encaixam estruturalmente
        local srcClass = tonumber(partData.vehicleClass)
        if srcClass and srcClass ~= numTargetClass then
            return false, 'panel_class_mismatch'
        end

        -- Mesma classe aceita adaptação física com retífica
        return true, 'adapted_panel_fit'
    end

    -- ─── 4. Catalisadores e Exaustão (`catalytic_converter`) ────────────────────
    if partType == 'catalytic_converter' then
        -- Exaustão só é incompatível com bicicletas (classe 13), barcos (14) ou trens (21)
        if numTargetClass == 13 or numTargetClass == 14 or numTargetClass == 21 then
            return false, 'exhaust_unsupported_vehicle_type'
        end
        return true, 'exhaust_compatible'
    end

    return true, 'generic_compatible'
end

function PartCompatibility.__setMock(mock)
    _mock = mock
end

return PartCompatibility
