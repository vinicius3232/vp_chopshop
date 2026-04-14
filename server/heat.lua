-- server/heat.lua
-- Calcula heat de veículo on-demand (sem loop). Heat afeta ambush e preço fence.
-- Expõe: VPChopHeatCalc(plate), VPChopHeatGetMultiplier(plate), VPChopHeatGetLabel(plate)
-- Callback: 'vp_chopshop:vinScratch' — recebe netId, resolve placa server-side.

-- Local fallback: garante que VPChopEvt está disponível mesmo se o global não propagou.
local VPChopEvt = VPChopEvt or {
    PART_CHOPPED   = 'vp_chopshop:evt:partChopped',
    CAR_DISCARDED  = 'vp_chopshop:evt:carDiscard',
    FENCE_DELIVERY = 'vp_chopshop:evt:fenceDelivery',
    HEAT_CHANGED   = 'vp_chopshop:evt:heatChanged',
}

--- Cache do nível anterior para emitir HEAT_CHANGED só em transições reais.
local LastHeatLevel = {} ---@type table<string, string>

--- Contador de peças removidas por placa — atualizado pelo PART_CHOPPED event.
--- GetAllVehicles() NÃO existe server-side; rastreamos em memória pelo evento.
local PartCountByPlate = {} ---@type table<string, integer>
local VinScratchCooldown = {} ---@type table<number, number>  src → expiry GetGameTimer

-- Escuta PART_CHOPPED e incrementa contador por placa.
AddEventHandler(VPChopEvt.PART_CHOPPED, function(src, netId, partKey, phase)
    -- Resolver placa a partir do netId para manter rastreio server-side
    local veh = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')
        if plate and plate ~= '' then
            PartCountByPlate[plate] = (PartCountByPlate[plate] or 0) + 1
        end
    end
end)

--- Retorna o heat numérico (0-100) de um veículo pela placa.
--- Chamado apenas quando o jogador inicia uma ação — zero overhead.
---@param plate string
---@return integer
function VPChopHeatCalc(plate)
    if not plate or plate == '' then return 0 end

    local heat = 0

    -- Componente 1: modificador MDT externo (0..50)
    local mdtMod = tonumber(VPChopMDT.GetHeatModifier(plate)) or 0.0
    heat = heat + math.floor(mdtMod * 50)

    -- Componente 2: peças removidas (rastreadas em memória via PART_CHOPPED event)
    -- +5 por peça, máx +20.
    local partCount = PartCountByPlate[plate] or 0
    heat = heat + math.min(partCount * 5, 20)

    -- Componente 3: VIN scratch reduz em 60
    -- [OPT] EXISTS para ao primeiro match (COUNT(*) continua contando até o fim)
    local scratched = MySQL.scalar.await(
        'SELECT EXISTS(SELECT 1 FROM vp_chop_vin_scratched WHERE plate = ?)', {plate}
    )
    if scratched == 1 then
        heat = math.max(0, heat - 60)
    end

    return math.min(heat, 100)
end

--- Retorna o rótulo de nível: 'frio' | 'morno' | 'quente' | 'queimando'
---@param plate string
---@return string
function VPChopHeatGetLabel(plate)
    local h = VPChopHeatCalc(plate)
    if h <= 25 then return 'frio'
    elseif h <= 50 then return 'morno'
    elseif h <= 75 then return 'quente'
    else return 'queimando' end
end

--- Retorna multiplicador de chance de ambush baseado no heat.
---@param plate string
---@return number
function VPChopHeatGetMultiplier(plate)
    local label = VPChopHeatGetLabel(plate)
    if label == 'frio'      then return 1.0
    elseif label == 'morno'  then return 1.15
    elseif label == 'quente' then return 1.35
    else return 1.80 end
end

--- Retorna penalidade de preço (0.0 = sem penalidade, 1.0 = preço zero).
--- Usado pelo fence para calcular preço final.
---@param plate string
---@return number  multiplicador: 1.0 | 0.90 | 0.75 | 0.0 (recusa)
function VPChopHeatGetPriceMult(plate)
    local label = VPChopHeatGetLabel(plate)
    if label == 'frio'       then return 1.0
    elseif label == 'morno'  then return 0.90
    elseif label == 'quente' then return 0.75
    else return 0.0 end  -- queimando = fence recusa
end

--- Emite HEAT_CHANGED se o nível mudou desde a última verificação.
---@param plate string
local function notifyHeatChange(plate)
    local newLabel = VPChopHeatGetLabel(plate)
    if LastHeatLevel[plate] ~= newLabel then
        LastHeatLevel[plate] = newLabel
        TriggerEvent(VPChopEvt.HEAT_CHANGED, plate, newLabel)
    end
end

--- Retorna o heat de um veículo e notifica cliente com o nível atual.
--- Chamado por server/main.lua ao iniciar qualquer ação no veículo.
---@param src number
---@param netId integer
---@return string label  'frio'|'morno'|'quente'|'queimando'
function VPChopHeatCheck(src, netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return 'frio' end
    local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')
    notifyHeatChange(plate)
    local label = VPChopHeatGetLabel(plate)
    -- Notificar cliente apenas se morno/quente/queimando
    if label ~= 'frio' then
        TriggerClientEvent('vp_chopshop:client:heatWarning', src, label)
    end
    return label
end

-- ─── Callback: VIN Scratch ────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:vinScratch', function(src, netId)
    if not GetPlayerName(src) then return { ok=false, err='invalid' } end

    -- Rate limit: 3s cooldown entre scratches
    local now = GetGameTimer()
    if VinScratchCooldown[src] and now < VinScratchCooldown[src] then
        return { ok=false, err='cooldown' }
    end
    VinScratchCooldown[src] = now + 3000

    -- Validar veículo e proximidade (trust-no-client)
    local veh = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return { ok=false, err='vehicle' }
    end
    local maxDist = (Config.VehicleNearLiftRadius or 5.0) + 2.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then
        return { ok=false, err='range' }
    end

    -- Placa resolvida no servidor (nunca confiamos no cliente)
    local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')

    -- Verificar tier ≥ 3
    local prog = VPChopGetProgression(src)
    if not prog or prog.tier < 3 then
        return { ok=false, err='tier' }
    end

    -- Verificar e consumir item
    if not exports.ox_inventory:RemoveItem(src, 'vin_kit', 1) then
        return { ok=false, err='no_item' }
    end

    -- Chance de falha em veículo quente
    local heat = VPChopHeatCalc(plate)
    if heat > 75 then
        local failChance = tonumber(Config.Progression and Config.Progression.VinFailChanceHot) or 0.40
        if math.random() < failChance then
            -- Item já consumido — informar falha
            return { ok=false, err='failed_hot' }
        end
    end

    -- Registrar scratch (upsert — idempotente)
    MySQL.query.await(
        'INSERT INTO vp_chop_vin_scratched (plate, scratched_by) VALUES (?,?) '..
        'ON DUPLICATE KEY UPDATE scratched_by=VALUES(scratched_by), scratched_at=NOW()',
        { plate, ServerChopPlayerKey(src) }
    )

    -- Notificar MDT e emitir XP via evento
    VPChopMDT.ReportActivity(plate, src, 'vin_scratched')
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'vin_scratch', 0)

    -- Atualizar cache de nível
    LastHeatLevel[plate] = nil  -- forçar recálculo na próxima ação

    return { ok=true }
end)

AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1]
    VinScratchCooldown[src] = nil
end)
