-- bridge/server_vehicle.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-D] Ponte de PERSISTÊNCIA / DELEÇÃO de veículo. Isola o discard
--  (server/main.lua) de qualquer API de framework. Nada de qbx_* espalhado pelo
--  gameplay.
--
--  Duas responsabilidades DIFERENTES (não confundir):
--    • BridgeResolveVehiclePersistence → o veículo tem REGISTRO persistente (player
--      vehicle)?  Só LÊ. Fail-closed: dúvida ⇒ 'unknown'.
--    • BridgeDeleteWorldVehicle → remove a ENTIDADE do mundo (e desliga persistence
--      antes, p/ QBox não respawnar). NÃO apaga registro de banco.
--
--  API QBox confirmada (Qbox-project/qbx_core + qbx_vehicles, branch main, 2026-08):
--    exports.qbx_core:DisablePersistence(vehicle)                → seta state 'persisted'=nil (replicado)
--    Entity(vehicle).state.vehicleid                             → id do player vehicle (server-side, não replicado)
--    exports.qbx_vehicles:GetVehicleIdByPlate(plate)             → integer? vehicleId
--    exports.qbx_vehicles:GetPlayerVehicle(vehicleId, filters?)  → PlayerVehicle? { citizenid, props, ... }
--    exports.qbx_vehicles:DeletePlayerVehicles(idType, idValue)  → boolean success, ErrorResult?
--                                                                  idType: 'citizenid'|'license'|'plate'|'vehicleId'
--    (NÃO existe exports.qbx_core:DeleteVehicle — a função DeleteVehicle do qbx_core
--     é global interna + @deprecated; other resources usam DisablePersistence + DeleteEntity.)
--
--  QB-Core / ESX: sem adapter de ownership confiável instalado aqui (portabilidade
--  não-testada — servidor LIVE é QBox). NÃO inventamos nome de tabela SQL. Esses
--  frameworks devolvem status='unknown' → o discard trata como fail-closed.
-- ═══════════════════════════════════════════════════════════════════════════════

local function detectFramework()
    if GetResourceState('qbx_core') == 'started' then return 'qbox' end
    if GetResourceState('qb-core') == 'started' then return 'qbcore' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return 'none'
end

--- pcall wrapper p/ export. Retorna (completou?, resultado). `completou=false`
--- (resource parado, função ausente, erro) → o chamador deve FAIL-CLOSE (unknown),
--- nunca interpretar como "não existe registro".
local function safeExport(resource, fn, ...)
    if GetResourceState(resource) ~= 'started' then return false, nil end
    local ok, a = pcall(function(...) return exports[resource][fn](exports[resource], ...) end, ...)
    if not ok then return false, nil end   -- resource parou / função sumiu / erro → chamador fail-closa
    return true, a
end

--- Lê o vehicleid do state bag server-side (não replicado no QBox).
---@param vehicle integer
---@return integer|nil
local function readStateVehicleId(vehicle)
    local ok, v = pcall(function()
        local st = Entity(vehicle).state
        return st and (st.vehicleid or (st.vehicleData and st.vehicleData.id)) or nil
    end)
    return ok and tonumber(v) or nil
end

--- Resolve se o veículo tem REGISTRO persistente (player owned). Só leitura.
---@param vehicle integer  entity handle
---@param context? string  rótulo p/ log ('discard')
---@return { status: 'owned'|'not_owned'|'unknown', vehicleId: integer|nil, framework: string, source: string, plate: string, ownedBy: string|nil }
function BridgeResolveVehiclePersistence(vehicle, context)
    local fw = detectFramework()
    local plate = ''
    do
        local ok, p = pcall(function() return (GetVehicleNumberPlateText(vehicle) or ''):gsub('%s+', '') end)
        if ok then plate = p end
    end
    local out = { status = 'unknown', vehicleId = nil, framework = fw, source = 'none', plate = plate }

    if not (vehicle and vehicle ~= 0 and DoesEntityExist(vehicle)) then
        return out  -- sem entidade → unknown (fail-closed)
    end

    if fw ~= 'qbox' then
        -- QB/ESX: sem adapter confiável → unknown (o discard fail-closa).
        return out
    end

    local function logCtx(msg)
        if context then print(('[vp_chopshop][bridge/vehicle] %s: %s'):format(tostring(context), msg)) end
    end
    -- Extrai o citizenid do dono de um PlayerVehicle (p/ observabilidade / políticas futuras).
    local function ownerOf(pv)
        if type(pv) ~= 'table' then return nil end
        return pv.citizenid or (pv.citizen and pv.citizen.id) or nil
    end

    -- 1) state.vehicleid é a fonte preferida (mais confiável que placa — o projeto tem fake plates).
    local stateId = readStateVehicleId(vehicle)
    if stateId then
        local ok, pv = safeExport('qbx_vehicles', 'GetPlayerVehicle', stateId)
        if not ok then
            -- export não completou → NÃO dá p/ afirmar nada → fail-closed.
            out.status, out.vehicleId, out.source = 'unknown', stateId, 'state_vehicleid'
            logCtx(('GetPlayerVehicle(%s) falhou → unknown (fail-closed)'):format(tostring(stateId)))
            return out
        end
        if pv ~= nil then
            out.status, out.vehicleId, out.source = 'owned', stateId, 'state_vehicleid'
            out.ownedBy = ownerOf(pv)
            return out
        end
        -- state diz que é owned mas o registro não confirma → INCONSISTENTE → fail-closed.
        out.status, out.vehicleId, out.source = 'unknown', stateId, 'state_vehicleid'
        logCtx(('state.vehicleid=%s sem registro em qbx_vehicles → unknown (fail-closed)'):format(tostring(stateId)))
        return out
    end

    -- 2) Sem state id: só a PLACA REAL pode provar ausência de registro. `not_owned`
    --    exige PROVA POSITIVA — qualquer passo ambíguo/indisponível ⇒ 'unknown'.
    out.source = 'qbx_vehicles_plate'

    -- 2A) resolver de placa real precisa EXISTIR e estar OPERACIONAL.
    if not (VPChopMDT and VPChopMDT.GetRealPlate) then
        logCtx('VPChopMDT.GetRealPlate indisponível → unknown (fail-closed)')
        return out
    end
    if VPChopDBReady ~= true then
        -- nil (ainda não carregou) OU false → não dá p/ confiar na resolução de placa.
        logCtx('DB não pronto (VPChopDBReady ~= true) → unknown (fail-closed)')
        return out
    end
    -- 2E) sem placa visível legível → não há como resolver a real → unknown.
    if plate == '' then
        logCtx('placa vazia/ilegível + sem state.vehicleid → unknown (fail-closed)')
        return out
    end
    -- 3A) GetRealPlate LANÇOU erro → NÃO cair de volta pra placa visível (fake) → unknown.
    local okRp, realPlate = pcall(VPChopMDT.GetRealPlate, plate)
    if not okRp or type(realPlate) ~= 'string' or realPlate == '' then
        logCtx('GetRealPlate falhou/vazio → unknown (fail-closed)')
        return out
    end

    -- 2B) lookup do id por placa.
    local okId, vidRaw = safeExport('qbx_vehicles', 'GetVehicleIdByPlate', realPlate)
    if not okId then
        logCtx(('GetVehicleIdByPlate(%s) não completou → unknown (fail-closed)'):format(realPlate))
        return out
    end
    if vidRaw ~= nil then
        -- 3D) retornou algo não-nil mas não é um id válido → INCONSISTENTE → unknown.
        local vid = tonumber(vidRaw)
        if not vid then
            logCtx(('GetVehicleIdByPlate(%s) devolveu valor inválido (%s) → unknown'):format(realPlate, tostring(vidRaw)))
            return out
        end
        out.vehicleId = vid
        -- 3C) id existe mas o registro não confirma → INCONSISTENTE → unknown (igual ao caminho state.vehicleid).
        local okPv, pv = safeExport('qbx_vehicles', 'GetPlayerVehicle', vid)
        if not okPv then
            logCtx(('GetPlayerVehicle(%s) não completou → unknown (fail-closed)'):format(tostring(vid)))
            return out
        end
        if pv == nil then
            logCtx(('placa %s → id %s sem PlayerVehicle → unknown (inconsistente)'):format(realPlate, tostring(vid)))
            return out
        end
        out.status, out.ownedBy = 'owned', ownerOf(pv)
        return out
    end

    -- 3) PROVA POSITIVA: state.vehicleid ausente + resolver de placa OK + DB pronto +
    --    GetVehicleIdByPlate completou e devolveu EXATAMENTE nil → nenhum registro.
    out.status, out.source = 'not_owned', 'none'
    return out
end

--- [v1.16 SEC-1] Normaliza identificador de cidadão / player key para comparação exata.
--- Remove prefixos ('qbx:', 'qb:', 'esx:', 'src:') e espaços para evitar falsos positivos de substring.
---@param val string|number|nil
---@return string
function BridgeNormalizeCitizenId(val)
    if not val then return '' end
    local s = tostring(val)
    s = s:gsub('^%a+:', '')
    return string.upper(s:gsub('%s+', ''))
end

--- Retorna true se o veículo pertence ao jogador `src` (mesmo citizenid).
--- Usado para bloquear auto-farm/exploit de desmanchar o próprio carro pessoal.
---@param src number
---@param vehicle integer
---@return boolean
function BridgeIsPlayerVehicleOwner(src, vehicle)
    if not src or not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    local pInfo = BridgeResolveVehiclePersistence(vehicle, 'owner_check')
    if pInfo and pInfo.status == 'owned' and pInfo.ownedBy then
        local myKey = ServerChopPlayerKey(src)
        if myKey and myKey ~= '' then
            local normPlayer = BridgeNormalizeCitizenId(myKey)
            local normOwner  = BridgeNormalizeCitizenId(pInfo.ownedBy)
            if normPlayer ~= '' and normPlayer == normOwner then
                return true
            end
        end
    end
    return false
end

--- Remove a ENTIDADE do mundo. No QBox, desliga persistence ANTES (senão respawna)
--- e SÓ deleta se isso for confirmado. NÃO apaga registro de banco.
---
--- FAIL-CLOSED:
---  • opts.expectedFramework informado e diferente do framework atual (qbx_core
---    parou entre o ownership gate e aqui) → NÃO deleta. { method='framework_race' }.
---  • framework qbox + DisablePersistence não completou / state 'persisted' ainda
---    setado → NÃO deleta. { method='qbx_disable_persist_failed' }.
--- Em ambos: existsAfter=true, retryable=true. A sessão já é COMPLETED (tombstone);
--- o payout continua válido; a retry segura pode ocorrer depois.
---@param vehicle integer  entity handle
---@param opts? { expectedFramework?: string }
---@return { ok: boolean, method: string, existsAfter: boolean, retryable?: boolean }
function BridgeDeleteWorldVehicle(vehicle, opts)
    if not (vehicle and vehicle ~= 0 and DoesEntityExist(vehicle)) then
        return { ok = true, method = 'noop', existsAfter = false }
    end
    local fw = detectFramework()
    local expected = opts and opts.expectedFramework

    -- Framework race: o que resolveu o ownership não é mais o que está de pé.
    if expected and expected ~= fw then
        return { ok = false, method = 'framework_race', existsAfter = true, retryable = true }
    end

    local method = 'native'
    if fw == 'qbox' then
        method = 'qbx_disable_persist+native'
        -- Desligar persistence primeiro e CONFIRMAR. Sem isso o qbx_core respawna.
        local okDp = safeExport('qbx_core', 'DisablePersistence', vehicle)
        local stillPersisted = true
        local okRead, v = pcall(function() return Entity(vehicle).state.persisted end)
        if okRead then stillPersisted = (v == true) end
        if not okDp or stillPersisted then
            return { ok = false, method = 'qbx_disable_persist_failed', existsAfter = true, retryable = true }
        end
    end

    pcall(function()
        if SetEntityAsMissionEntity then SetEntityAsMissionEntity(vehicle, true, true) end
    end)
    pcall(DeleteEntity, vehicle)

    local existsAfter = DoesEntityExist(vehicle) == true
    return { ok = not existsAfter, method = method, existsAfter = existsAfter, retryable = existsAfter }
end
