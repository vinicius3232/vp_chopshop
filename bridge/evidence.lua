-- bridge/evidence.lua
-- [EVIDENCE] Ponte server-side para o resource `vp_crimescene` (sistema de cena de crime).
-- Toda ação de crime do chopshop chama VPChopLeaveEvidence(src, coords, actionKey) APÓS o
-- sucesso. A função planta vestígio coletável (digital + DNA) no local, vinculado
-- biometricamente ao criminoso — o próprio `evidences` resolve a biometria a partir do serverId.
--
-- API consumida (vp_crimescene/server/evidence_objects.lua):
--   exports.vp_crimescene:AddGroundEvidence(evidenceType, coords, playerSrc, metadata?)
--     evidenceType : 'blood' (DNA) — traço biométrico de chão coletável
--     coords       : vector3/table {x,y,z}
--     playerSrc    : serverId do criminoso → o script resolve a biometria sozinho
--   (Migrado do antigo resource `evidences`, que foi removido.)
--
-- Padrões espelhados do vp_chopshop:
--   guard de feature flag, GetResourceState gate (auto-desativa), IsValidSource,
--   InvCount (bridge/server_inventory.lua), VPChopHeatCalc (server/heat.lua),
--   tudo defensivo em pcall — uma falha do evidences NUNCA quebra o crime.
--
-- Carregado no fxmanifest DEPOIS de server_inventory.lua e mdt.lua (usa InvCount e
-- VPChopMDT.GetRealPlate indiretamente via VPChopHeatCalc), ANTES dos arquivos de crime.

-- [EVIDENCE] Calcula o multiplicador de chance pelo heat da placa.
-- chance_final = base * (1 + heat/100 * HeatFactor). Se HeatScaling off, sem placa, ou
-- heat indeterminável → mult 1.0 (não quebra, só não escala).
-- NOTA: a resolução de placa é feita pelo CHAMADOR (hook), que já tem o handle do veículo
-- validado server-side. `GetClosestVehicle`/`GetAllVehicles` NÃO existem server-side neste
-- build (ver comentário em server/heat.lua), por isso recebemos a placa pronta como hint.
---@param plate string|nil  placa REAL já resolvida pelo hook ('' / nil = sem scaling)
---@return number mult
local function heatMult(plate)
    local cfg = Config.Evidence
    if not cfg or not cfg.HeatScaling then return 1.0 end
    if not plate or plate == '' then return 1.0 end
    -- VPChopHeatCalc(plate) → integer 0..100 (confirmado em server/heat.lua).
    local okHeat, heat = pcall(VPChopHeatCalc, plate)
    if not okHeat or type(heat) ~= 'number' then return 1.0 end
    local factor = tonumber(cfg.HeatFactor) or 0.0
    return 1.0 + (heat / 100.0) * factor
end

-- [EVIDENCE] Plant defensivo de UMA evidência. Tudo em pcall: falha do evidences
-- (ex.: jogador sem biometria, export ausente) NÃO propaga para o crime.
---@param evidenceClass string  'fingerprint' | 'blood' | 'saliva'
---@param src number
---@param coords vector3
---@param actionKey string
local function plantEvidence(evidenceClass, src, coords, actionKey)
    -- [MIGRADO] vp_crimescene substituiu o antigo resource `evidences`.
    -- Ele modela traços biométricos de chão como 'blood' (DNA): tanto a rolagem de
    -- digital quanto a de DNA do chopshop viram um vestígio de DNA coletável,
    -- vinculado ao criminoso (resolvido pelo serverId server-side).
    pcall(function()
        exports.vp_crimescene:AddGroundEvidence('blood', coords, src, {
            source = 'vp_chopshop',
            action = actionKey,
        })
    end)
end

--- [EVIDENCE] Ponto de entrada único: deixa vestígio forense de uma ação de crime.
--- Chamado APÓS o sucesso de cada ação (chop_part, vin_scratch, plate_steal,
--- plate_forge, plate_apply) com as coords do VEÍCULO (ou bancada/jogador na forja).
---
--- Regras:
---  - Auto-desativa se Config.Evidence.Enable=false ou se 'evidences' não estiver started.
---  - Digital: bloqueada se o jogador tem luvas (GlovesItem) no inventário.
---  - DNA: cai mesmo com luvas (corte/suor), salvo GlovesBlocksDna=true.
---  - Chances escalam com o heat da placa (se HeatScaling).
---@param src number        serverId do criminoso (owner da biometria)
---@param coords vector3    local onde o vestígio é plantado
---@param actionKey string  chave em Config.Evidence.Actions
---@param plate string|nil  (opcional) placa REAL já resolvida pelo hook → habilita heat scaling
function VPChopLeaveEvidence(src, coords, actionKey, plate)
    local cfg = Config.Evidence
    -- Guard 1: feature ligada na config.
    if not cfg or not cfg.Enable then return end
    -- Guard 2: resource presente e rodando — auto-desativa sem crashar se ausente.
    if GetResourceState('vp_crimescene') ~= 'started' then return end
    -- Guard 3: coords válido (vector3 com componentes numéricos).
    if not coords or type(coords.x) ~= 'number' then return end
    -- Guard 4: ação conhecida (tabela de chances existe).
    local actCfg = cfg.Actions and cfg.Actions[actionKey]
    if not actCfg then return end
    -- Guard 5: fonte válida (mesmo padrão de todo callback do resource).
    if not IsValidSource(src) then return end

    -- [EVIDENCE] Multiplicador por heat (placa mais "quente" → mais chance de vestígio).
    -- A placa é resolvida pelo hook (que tem o handle do veículo) e passada aqui; sem placa
    -- (ex.: forja, sem veículo) o scaling é neutro (mult 1.0).
    local mult = heatMult(plate)

    -- [EVIDENCE] Luvas no inventário bloqueiam digitais. InvCount(src, item) → integer
    -- (confirmado em bridge/server_inventory.lua: exports.ox_inventory:GetItemCount).
    local hasGloves = InvCount(src, cfg.GlovesItem or 'gloves') > 0

    -- [EVIDENCE] DIGITAL (fingerprint): só sem luvas, chance base * mult.
    if not hasGloves then
        local chance = (tonumber(actCfg.fingerprint) or 0.0) * mult
        if chance > 0 and math.random() <= chance then
            plantEvidence('fingerprint', src, coords, actionKey)
        end
    end

    -- [EVIDENCE] DNA (blood/saliva): cai mesmo com luvas (corte/suor), salvo GlovesBlocksDna.
    if (not hasGloves) or (not cfg.GlovesBlocksDna) then
        local chance = (tonumber(actCfg.dna) or 0.0) * mult
        if chance > 0 and math.random() <= chance then
            plantEvidence(cfg.DnaType or 'blood', src, coords, actionKey)
        end
    end
end
