-- bridge/evidence.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.18 FORENSICS V2] EvidenceBridge — Multi-Framework Police Evidence Bridge
--  Conector server-side modular para sistemas de vestígios e cena de crime.
--  Suporta: vp_crimescene, qbx_policejob, ox_evidence, evidences (CFX legacy), none.
-- ═══════════════════════════════════════════════════════════════════════════════

EvidenceBridge = EvidenceBridge or {}

local _mockHandler = nil
local _mockProvider = nil
local _lastPlant = nil

--- Retorna a configuração de evidência sanitizada
---@return table
local function getEvidenceConfig()
    return Config.Evidence or {
        Enable = true,
        Provider = 'auto',
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
        },
    }
end

--- Resolve o provedor de evidência ativo
---@return string provider ('vp_crimescene' | 'qbx_policejob' | 'ox_evidence' | 'evidences' | 'none')
function EvidenceBridge.GetProvider()
    if _mockProvider then return _mockProvider end

    local cfg = getEvidenceConfig()
    if not cfg.Enable then return 'none' end

    local explicit = cfg.Provider
    if explicit and explicit ~= 'auto' then
        if explicit == 'none' then return 'none' end
        if GetResourceState and GetResourceState(explicit) == 'started' then
            return explicit
        end
        return 'none'
    end

    -- Modo 'auto': probing ordenado dos recursos suportados
    if GetResourceState then
        if GetResourceState('vp_crimescene') == 'started' then return 'vp_crimescene' end
        if GetResourceState('qbx_policejob') == 'started' then return 'qbx_policejob' end
        if GetResourceState('ox_evidence') == 'started' then return 'ox_evidence' end
        if GetResourceState('evidences') == 'started' then return 'evidences' end
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
        if provider == 'vp_crimescene' then
            -- vp_crimescene modela vestígios via AddGroundEvidence
            local evType = (evidenceClass == 'fingerprint' and 'fingerprint') or 'blood'
            exports.vp_crimescene:AddGroundEvidence(evType, coords, src, meta)
            success = true
        elseif provider == 'qbx_policejob' then
            if exports.qbx_policejob and exports.qbx_policejob.CreateEvidence then
                exports.qbx_policejob:CreateEvidence(evidenceClass, coords, meta)
                success = true
            elseif TriggerEvent then
                TriggerEvent('evidence:server:CreateFingerprint', coords, src)
                success = true
            end
        elseif provider == 'ox_evidence' then
            if exports.ox_evidence and exports.ox_evidence.addEvidence then
                exports.ox_evidence:addEvidence(coords, evidenceClass, meta)
                success = true
            end
        elseif provider == 'evidences' then
            if exports.evidences and exports.evidences.syncEvidence then
                exports.evidences:syncEvidence(evidenceClass, coords, src, meta)
                success = true
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
    reset = function()
        _mockProvider = nil
        _mockHandler = nil
        _lastPlant = nil
    end,
}
