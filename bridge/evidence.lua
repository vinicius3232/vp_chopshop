-- bridge/evidence.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 FORENSICS V2] EvidenceBridge — Multi-Framework Police Evidence Bridge
--  Conector server-side modular para sistemas de vestígios e cena de crime.
--  Suporta: evidences (noobsystems), vp_crimescene, custom, none.
-- ═══════════════════════════════════════════════════════════════════════════════

EvidenceBridge = EvidenceBridge or {}

local _customProviders = {}
local _mockHandler = nil
local _mockProvider = nil
local _lastPlant = nil

--- Retorna a configuração de evidência sanitizada
---@return table
local function getEvidenceConfig()
    return Config.Evidence or {
        Enable = true,
        Provider = 'auto',
        AutoOrder = { 'evidences', 'vp_crimescene' },
        GlovesItem = 'gloves',
        GlovesBlocksDna = false,
        DnaType = 'blood',
        HeatScaling = true,
        HeatFactor = 0.5,
        Actions = {
            chop_part   = { fingerprint = 0.50, dna = 0.12 },
            vin_scratch = { fingerprint = 0.70, dna = 0.15 },
            plate_steal = { fingerprint = 0.60, dna = 0.10 },
            plate_forge = { fingerprint = 0.40, dna = 0.05 },
            plate_apply = { fingerprint = 0.50, dna = 0.08 },
            tracker_removal = { fingerprint = 0.65, dna = 0.15 },
        },
    }
end

--- Registra um provedor de evidência customizado server-side
---@param name string           identificador do provider (ex: 'custom' ou nome do resource)
---@param resourceName string   nome do resource chamador
---@param handler function      função que processa o vestígio (evidenceClass, src, coords, actionKey, meta)
---@return boolean success, string|nil err
function EvidenceBridge.RegisterProvider(name, resourceName, handler)
    if type(name) ~= 'string' or name == '' then
        return false, 'invalid_name'
    end
    if type(handler) ~= 'function' then
        return false, 'invalid_handler'
    end

    local invoking = (GetInvokingResource and GetInvokingResource()) or resourceName or 'vp_chopshop'
    if resourceName and invoking ~= resourceName and invoking ~= 'vp_chopshop' then
        return false, 'resource_mismatch'
    end

    if _customProviders[name] and _customProviders[name].resource ~= invoking then
        return false, 'already_registered'
    end

    _customProviders[name] = {
        resource = invoking,
        handler = handler,
    }
    return true
end

--- Export server-side para registro de provider custom
if exports then
    exports('RegisterEvidenceProvider', function(name, resourceName, handler)
        return EvidenceBridge.RegisterProvider(name, resourceName, handler)
    end)
end

--- Resolve o provedor de evidência ativo de forma segura e sem polling
---@return string provider ('evidences' | 'vp_crimescene' | 'custom' | 'none')
function EvidenceBridge.GetProvider()
    if _mockProvider then return _mockProvider end

    local cfg = getEvidenceConfig()
    if not cfg.Enable then return 'none' end

    local explicit = cfg.Provider
    if explicit and explicit ~= 'auto' then
        if explicit == 'none' then return 'none' end
        if explicit == 'custom' then
            return (_customProviders['custom'] and 'custom') or 'none'
        end
        if explicit == 'evidences' or explicit == 'vp_crimescene' then
            if GetResourceState and GetResourceState(explicit) == 'started' then
                return explicit
            end
            return 'none'
        end
        -- Provider desconhecido -> fallback seguro
        return 'none'
    end

    -- Modo 'auto': probing ordenado conforme Config.Evidence.AutoOrder
    local order = cfg.AutoOrder or { 'evidences', 'vp_crimescene' }
    for _, provName in ipairs(order) do
        if provName == 'custom' and _customProviders['custom'] then
            return 'custom'
        elseif (provName == 'evidences' or provName == 'vp_crimescene') and GetResourceState then
            if GetResourceState(provName) == 'started' then
                return provName
            end
        end
    end

    return 'none'
end

--- Informa se há um provedor de evidência ativo e disponível
---@return boolean
function EvidenceBridge.IsAvailable()
    return EvidenceBridge.GetProvider() ~= 'none'
end

--- Calcula o multiplicador de chance pelo heat policial da placa
---@param plate string|nil  placa REAL já resolvida ('' / nil = mult 1.0)
---@return number mult
local function heatMult(plate)
    local cfg = getEvidenceConfig()
    if not cfg.HeatScaling then return 1.0 end
    if not plate or plate == '' then return 1.0 end

    if type(VPChopHeatCalc) == 'function' then
        local okHeat, heat = pcall(VPChopHeatCalc, plate)
        if okHeat and type(heat) == 'number' then
            local factor = tonumber(cfg.HeatFactor) or 0.0
            return 1.0 + (heat / 100.0) * factor
        end
    end
    return 1.0
end

--- Executa o plant de evidência no provider ativo de forma fail-closed
---@param evidenceClass string  'fingerprint' | 'blood' | 'saliva'
---@param src number            serverId do criminoso
---@param coords vector3|table  coordenadas da evidência
---@param actionKey string      chave de ação do crime
---@param metadata table|nil    metadados opcionais
---@return boolean success
function EvidenceBridge.Plant(evidenceClass, src, coords, actionKey, metadata)
    if not IsValidSource(src) then return false end
    if not coords or type(coords.x) ~= 'number' then return false end

    local meta = metadata or {}
    meta.source = meta.source or 'vp_chopshop'
    meta.action = meta.action or actionKey or 'crime'

    _lastPlant = {
        evidenceClass = evidenceClass,
        src = src,
        coords = coords,
        actionKey = actionKey,
        metadata = meta,
    }

    if _mockHandler then
        local okMock, resMock = pcall(_mockHandler, evidenceClass, src, coords, actionKey, meta)
        return okMock and resMock ~= false
    end

    local provider = EvidenceBridge.GetProvider()
    if provider == 'none' then return false end

    local success = false
    pcall(function()
        if provider == 'evidences' then
            -- [UPSTREAM REFERENCE] https://github.com/noobsystems/evidences
            -- server/evidences/api.lua: syncEvidence(evidenceClass, owner, fun, ...)
            -- Invocado com functionName = 'atCoords' para posicionar no mundo
            if exports.evidences and exports.evidences.syncEvidence then
                exports.evidences:syncEvidence(evidenceClass, src, 'atCoords', coords, meta)
                success = true
            end
        elseif provider == 'vp_crimescene' then
            -- vp_crimescene modela vestígios via AddGroundEvidence(evidenceType, coords, playerSrc, metadata)
            if exports.vp_crimescene and exports.vp_crimescene.AddGroundEvidence then
                exports.vp_crimescene:AddGroundEvidence(evidenceClass, coords, src, meta)
                success = true
            end
        elseif provider == 'custom' then
            local prov = _customProviders['custom']
            if prov and prov.handler then
                local okCustom, resCustom = pcall(prov.handler, evidenceClass, src, coords, actionKey, meta)
                if okCustom and resCustom ~= false then
                    success = true
                end
            end
        end
    end)

    return success
end

--- [EVIDENCE] Ponto de entrada único: deixa vestígio forense de uma ação de crime.
--- Chamado APÓS o sucesso de cada ação (chop_part, vin_scratch, plate_steal, plate_forge, plate_apply).
---@param src number        serverId do criminoso
---@param coords vector3    local onde o vestígio é plantado
---@param actionKey string  chave em Config.Evidence.Actions
---@param plate string|nil  (opcional) placa REAL para heat scaling
function VPChopLeaveEvidence(src, coords, actionKey, plate)
    local cfg = getEvidenceConfig()
    if not cfg.Enable then return end
    if not EvidenceBridge.IsAvailable() then return end
    if not IsValidSource(src) then return end
    if not coords or type(coords.x) ~= 'number' then return end

    local actCfg = cfg.Actions and cfg.Actions[actionKey]
    if not actCfg then return end

    local mult = heatMult(plate)
    local hasGloves = false
    if type(InvCount) == 'function' then
        hasGloves = InvCount(src, cfg.GlovesItem or 'gloves') > 0
    end

    -- 1. Digital (fingerprint): bloqueada por luvas
    if not hasGloves then
        local chance = (tonumber(actCfg.fingerprint) or 0.0) * mult
        if chance > 0 and math.random() <= chance then
            EvidenceBridge.Plant('fingerprint', src, coords, actionKey, { plate = plate })
        end
    end

    -- 2. DNA (blood/saliva): cai mesmo com luvas (salvo se GlovesBlocksDna=true)
    if (not hasGloves) or (not cfg.GlovesBlocksDna) then
        local chance = (tonumber(actCfg.dna) or 0.0) * mult
        if chance > 0 and math.random() <= chance then
            EvidenceBridge.Plant(cfg.DnaType or 'blood', src, coords, actionKey, { plate = plate })
        end
    end
end

-- ─── Test Seam ───────────────────────────────────────────────────────────────
EvidenceBridge._test = {
    setProvider = function(name, handler)
        _mockProvider = name
        _mockHandler = handler
    end,
    getLastPlant = function()
        return _lastPlant
    end,
    getCustomProviders = function()
        return _customProviders
    end,
    reset = function()
        _mockProvider = nil
        _mockHandler = nil
        _lastPlant = nil
        _customProviders = {}
    end,
}
