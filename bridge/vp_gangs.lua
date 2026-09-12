-- bridge/vp_gangs.lua
-- ══════════════════════════════════════════════════════════════════════════════
--  CAMADA DE INTEGRAÇÃO vp_chopshop → vp_gangs  (contractVersion = 1)
--
--  ÚNICO lugar do vp_chopshop que conhece `exports.vp_gangs`.
--  1) Escuta o evento INTERNO VPChopEvt.PART_CHOPPED e publica atividade criminal.
--  2) Consulta de zonas territoriais e taxas de pedágio (P6.1).
--  3) Bônus e alívio de heat para membros dominantes (P6.2).
--  4) Alerta de intrusão via smartphone condicionado a informantes de turf (P6.3).
-- ══════════════════════════════════════════════════════════════════════════════

VPChopGangs = VPChopGangs or {}

local CONTRACT_VERSION = 1
local CRIME            = 'part_chopped'
local _gangMock        = nil
local _alertCooldowns  = {}

--- Retorna a configuração de gangues
local function getGangConfig()
    local cfg = Config and Config.Gangs
    if type(cfg) ~= 'table' then
        return {
            Enable = true,
            TerritoryTax = 0.15,
            OwnerBonus = 0.10,
            HeatReductionMultiplier = 0.50,
            RequireInformantForAlert = true,
            AlertCooldownSeconds = 120,
        }
    end
    return cfg
end

--- Este (partKey, phase) é um marco que o crédito de gang cobre?
--- Espelha EXATAMENTE o gate de server/progression.lua (reason ∈ {phase1..phase4}).
---@param partKey any
---@param phase any
---@return boolean
function VPChopGangsShouldEmit(partKey, phase)
    if type(partKey) ~= 'string' or partKey == '' then return false end
    local reason
    if partKey == 'vin_scratch' then
        reason = 'vin_scratch'
    elseif partKey == 'plate_theft' then
        reason = 'plate_theft'
    else
        reason = 'phase' .. tostring(phase)
    end
    return reason == 'phase1' or reason == 'phase2' or reason == 'phase3' or reason == 'phase4'
end
VPChopGangs.ShouldEmit = VPChopGangsShouldEmit

--- operationId domínio-derivado. nil se não há ChopSession ativa p/ o veículo
--- (fail-closed — não inventamos identidade).
---@return string|nil
function VPChopGangsOperationId(netId, partKey, phase)
    local CS = rawget(_G, 'ChopSession')
    local s = CS and CS.GetByVehicle and CS.GetByVehicle(netId)
    if not (s and s.id) then return nil end
    return ('%s:%s:p%s'):format(tostring(s.id), tostring(partKey), tostring(phase))
end
VPChopGangs.OperationId = VPChopGangsOperationId

--- Payload V1 — mínimo. Sem amount/plate/netId/citizenid/internals.
---@return table
function VPChopGangsBuildPayload(operationId, partKey, phase)
    return {
        contractVersion = CONTRACT_VERSION,
        crime           = CRIME,
        operationId     = operationId,
        partKey         = partKey,
        phase           = tonumber(phase) or 0,
    }
end
VPChopGangs.BuildPayload = VPChopGangsBuildPayload

--- Entrega ao vp_gangs pelo contrato público. Fail-safe: resource parado /
--- export ausente / erro / rejeição → SÓ diagnóstico, nunca propaga p/ o domínio
--- e NUNCA credita gang por outro caminho.
---@return table
function VPChopGangsDispatch(src, payload)
    if GetResourceState('vp_gangs') ~= 'started' then
        return { ok = false, reason = 'vp_gangs_stopped' }
    end

    local ok, res = pcall(function()
        return exports.vp_gangs:recordExternalCrime(src, payload)
    end)

    if ok and type(res) == 'table' and res.ok then
        print(('[vp_chopshop][int:vp_gangs] emit ok  op=%s part=%s phase=%s')
            :format(tostring(payload.operationId), tostring(payload.partKey), tostring(payload.phase)))
        return res
    end

    local reason = (type(res) == 'table' and res.reason)
        or (not ok and 'pcall_error')
        or 'no_result'

    print(('[vp_chopshop][int:vp_gangs] sem crédito (%s) op=%s'):format(reason, tostring(payload.operationId)))
    return (type(res) == 'table' and res) or { ok = false, reason = reason }
end
VPChopGangs.Dispatch = VPChopGangsDispatch

--- Handler do evento interno VPChopEvt.PART_CHOPPED.
function VPChopGangsOnPartChopped(src, netId, partKey, phase)
    if not VPChopGangsShouldEmit(partKey, phase) then return end
    local operationId = VPChopGangsOperationId(netId, partKey, phase)
    if not operationId then
        print(('[vp_chopshop][int:vp_gangs] sem ChopSession p/ netId=%s — não emite'):format(tostring(netId)))
        return
    end
    VPChopGangsDispatch(src, VPChopGangsBuildPayload(operationId, partKey, phase))

    -- [v1.20 P6.3] Verificação territorial de intrusão rival
    local veh = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    local coords = (veh and veh ~= 0 and DoesEntityExist(veh)) and GetEntityCoords(veh)
        or (IsValidSource(src) and GetPlayerPed and GetEntityCoords(GetPlayerPed(src)))
    if coords then
        local turf = VPChopGangs.GetTerritory(coords)
        if turf and turf.inside and turf.gangId then
            local myGang = VPChopGangs.GetPlayerGang(src)
            if myGang ~= turf.gangId then
                VPChopGangs.DispatchRivalAlert(turf, coords, src)
            end
        end
    end
end

AddEventHandler(VPChopEvt.PART_CHOPPED, VPChopGangsOnPartChopped)

-- ══════════════════════════════════════════════════════════════════════════
--  [v1.20 FASE 6] DOMÍNIO TERRITORIAL, INFORMANTE E TAXAS
-- ══════════════════════════════════════════════════════════════════════════

--- Consulta se as coordenadas pertencem a um território de gangue
---@param coords vector3|table
---@return table { inside: boolean, turfId?: string, gangId?: string, zoneName?: string }
function VPChopGangs.GetTerritory(coords)
    if _gangMock and _gangMock.GetTerritory then
        return _gangMock.GetTerritory(coords)
    end
    local cfg = getGangConfig()
    if cfg.Enable == false or not coords then return { inside = false } end
    if GetResourceState and GetResourceState('vp_gangs') ~= 'started' then return { inside = false } end

    local ok, res = pcall(function()
        if exports and exports.vp_gangs and type(exports.vp_gangs.getTerritoryAtCoords) == 'function' then
            return exports.vp_gangs:getTerritoryAtCoords(coords)
        elseif exports and exports.vp_gangs and type(exports.vp_gangs.getTurfAtCoords) == 'function' then
            return exports.vp_gangs:getTurfAtCoords(coords)
        end
        return nil
    end)

    if ok and type(res) == 'table' and res.inside then
        return {
            inside   = true,
            turfId   = res.turfId or res.id,
            gangId   = res.gangId or res.owner,
            zoneName = res.zoneName or res.name or 'Território',
        }
    end

    return { inside = false }
end

--- Obtém a facção/gangue do jogador de forma server-authoritative
---@param src number
---@return string|nil gangId
function VPChopGangs.GetPlayerGang(src)
    if _gangMock and _gangMock.GetPlayerGang then
        return _gangMock.GetPlayerGang(src)
    end
    if not IsValidSource(src) then return nil end

    if GetResourceState and GetResourceState('vp_gangs') == 'started' then
        local ok, g = pcall(function()
            if exports and exports.vp_gangs and type(exports.vp_gangs.getPlayerGang) == 'function' then
                return exports.vp_gangs:getPlayerGang(src)
            end
            return nil
        end)
        if ok and g and type(g) == 'string' and g ~= '' and g ~= 'none' then
            return g
        elseif ok and type(g) == 'table' and g.name and g.name ~= 'none' then
            return g.name
        end
    end

    return nil
end

--- [REQUISITO CANÔNICO DO DONO]
--- Verifica se a gangue dona do território possui um NPC / sistema de informantes ativo no turf.
--- Se a gangue não tiver informante na turf, o alerta NÃO pode ser acionado.
---@param gangId string
---@param turfId string
---@param coords? table|vector3
---@return boolean
function VPChopGangs.HasTurfInformant(gangId, turfId, coords)
    if _gangMock and _gangMock.HasTurfInformant then
        return _gangMock.HasTurfInformant(gangId, turfId, coords) == true
    end
    if GetResourceState and GetResourceState('vp_gangs') ~= 'started' then return false end
    if not gangId or not turfId then return false end

    local ok, hasInf = pcall(function()
        if exports and exports.vp_gangs and type(exports.vp_gangs.hasTurfInformant) == 'function' then
            return exports.vp_gangs:hasTurfInformant(turfId, gangId)
        elseif exports and exports.vp_gangs and type(exports.vp_gangs.getTurfUpgrades) == 'function' then
            local up = exports.vp_gangs:getTurfUpgrades(turfId)
            return (type(up) == 'table' and (up.informant or up.scouts or up.lookouts)) == true
        end
        return false
    end)

    return (ok and hasInf == true)
end

--- Credita o cofre da gangue com a taxa de pedágio territorial retida
---@param gangId string
---@param taxAmount number
---@param metadata? table
---@return boolean ok, string? err
function VPChopGangs.CreditTerritoryTax(gangId, taxAmount, metadata)
    if _gangMock and _gangMock.CreditTerritoryTax then
        return _gangMock.CreditTerritoryTax(gangId, taxAmount, metadata)
    end
    if not gangId or taxAmount <= 0 then return false, 'invalid_tax_params' end
    if GetResourceState and GetResourceState('vp_gangs') ~= 'started' then return false, 'vp_gangs_stopped' end

    local ok, res = pcall(function()
        if exports and exports.vp_gangs and type(exports.vp_gangs.addGangMoney) == 'function' then
            return exports.vp_gangs:addGangMoney(gangId, taxAmount, 'chopshop_territory_tax')
        elseif exports and exports.vp_gangs and type(exports.vp_gangs.addTerritoryFunds) == 'function' then
            return exports.vp_gangs:addTerritoryFunds(gangId, taxAmount, metadata)
        end
        return false
    end)

    return (ok and res ~= false), (not ok and tostring(res) or nil)
end

--- Dispara alerta silencioso via smartphone para a gangue dona do território
--- CONDICIONADO ESTRITAMENTE à presença de informante no turf!
---@param turfInfo table { turfId: string, gangId: string, zoneName: string }
---@param coords table|vector3
---@param chopperSrc number
---@return table { ok: boolean, reason?: string, alertedCount?: number }
function VPChopGangs.DispatchRivalAlert(turfInfo, coords, chopperSrc)
    if not turfInfo or not turfInfo.gangId or not turfInfo.turfId then
        return { ok = false, reason = 'invalid_turf_info' }
    end

    local cfg = getGangConfig()
    if cfg.Enable == false then
        return { ok = false, reason = 'gangs_disabled' }
    end

    -- 1. [REQUISITO CANÔNICO DO DONO]
    -- SÓ ATIVA SE A GANG TIVER UM NPC/SISTEMA DE INFORMANTES NA SUA TURF
    if cfg.RequireInformantForAlert ~= false then
        local hasInformant = VPChopGangs.HasTurfInformant(turfInfo.gangId, turfInfo.turfId, coords)
        if not hasInformant then
            return { ok = false, reason = 'no_informant_in_turf' }
        end
    end

    -- 2. Cooldown anti-spam por território
    local now = os.time()
    local lastAlert = _alertCooldowns[turfInfo.turfId] or 0
    local cd = cfg.AlertCooldownSeconds or 120
    if (now - lastAlert) < cd then
        return { ok = false, reason = 'territory_alert_cooldown' }
    end
    _alertCooldowns[turfInfo.turfId] = now

    -- 3. Obter membros online da facção dona do território
    local members = {}
    if _gangMock and _gangMock.GetOnlineGangMembers then
        members = _gangMock.GetOnlineGangMembers(turfInfo.gangId) or {}
    elseif GetResourceState and GetResourceState('vp_gangs') == 'started' and exports.vp_gangs and type(exports.vp_gangs.getOnlineGangMembers) == 'function' then
        local okM, mList = pcall(function() return exports.vp_gangs:getOnlineGangMembers(turfInfo.gangId) end)
        if okM and type(mList) == 'table' then members = mList end
    end

    if #members == 0 then
        return { ok = false, reason = 'no_members_online' }
    end

    -- 4. Disparar notificação para os celulares dos membros via PhoneBridge
    local PB = rawget(_G, 'PhoneBridge')
    if not PB or not PB.IsAvailable() then
        return { ok = false, reason = 'phone_bridge_unavailable' }
    end

    local zoneName = turfInfo.zoneName or 'sua área'
    local message = ('[Informante: %s] Atividade suspeita avistada! Um veículo está sendo desmanchado clandestinamente no nosso território!'):format(zoneName)

    local sent = PB.SendNotificationToPlayers(members, 'Olheiro da Quebrada', message, {
        icon = 'shield-alert',
        coords = coords,
        duration = 8000,
    })

    return { ok = true, alertedCount = sent }
end

--- Calcula o ajuste territorial no payout (bônus p/ dono, taxa territorial retida p/ terceiros)
---@param src number
---@param coords vector3|table
---@param basePayout number
---@return table { adjustedPayout: number, taxAmount: number, bonusAmount: number, isOwner: boolean, turf: table|nil }
function VPChopGangs.CalculateTerritoryAdjustment(src, coords, basePayout)
    basePayout = math.floor(tonumber(basePayout) or 0)
    if basePayout <= 0 then
        return { adjustedPayout = 0, taxAmount = 0, bonusAmount = 0, isOwner = false, turf = nil }
    end

    local cfg = getGangConfig()
    if cfg.Enable == false or not coords then
        return { adjustedPayout = basePayout, taxAmount = 0, bonusAmount = 0, isOwner = false, turf = nil }
    end

    local turf = VPChopGangs.GetTerritory(coords)
    if not turf or not turf.inside or not turf.gangId then
        return { adjustedPayout = basePayout, taxAmount = 0, bonusAmount = 0, isOwner = false, turf = nil }
    end

    local playerGang = VPChopGangs.GetPlayerGang(src)
    local isOwner = (playerGang ~= nil and playerGang == turf.gangId)

    if isOwner then
        -- [P6.2] Bônus econômico para membros operando em território próprio
        local bonusRate = tonumber(cfg.OwnerBonus) or 0.10
        local bonus = math.floor(basePayout * bonusRate)
        return {
            adjustedPayout = basePayout + bonus,
            taxAmount      = 0,
            bonusAmount    = bonus,
            isOwner        = true,
            turf           = turf,
        }
    else
        -- [P6.1] Pedágio / Retenção territorial para terceiros (civis ou rivais)
        local taxRate = tonumber(cfg.TerritoryTax) or 0.15
        local tax = math.floor(basePayout * taxRate)
        local adjusted = math.max(0, basePayout - tax)
        if tax > 0 then
            VPChopGangs.CreditTerritoryTax(turf.gangId, tax, {
                source = src,
                playerGang = playerGang,
                turfId = turf.turfId,
            })
        end
        return {
            adjustedPayout = adjusted,
            taxAmount      = tax,
            bonusAmount    = 0,
            isOwner        = false,
            turf           = turf,
        }
    end
end

function VPChopGangs.__setMock(mock)
    _gangMock = mock
end

return VPChopGangs
