-- server/tyremarks.lua
-- [TYRE] Marcas de pneu — lado SERVER. Fonte única de verdade.
--   - Recebe vp_chopshop:createTyreMark(netId, coords) do criminoso. RESOLVE o modelo
--     pelo netId (trust-no-client: nunca confia no modelo vindo do client), valida
--     fonte + cooldown, e guarda a marca em memória (transiente, com TTL — SEM DB).
--   - Faz broadcast só para clientes POLICIAIS (jobs em Config.TyreMarks.PoliceJobs).
--   - Callback vp_chopshop:examineTyreMark(markId): gate por job policial + proximidade
--     server-side; retorna { modelName, class }. REGRA ABSOLUTA: NUNCA inclui placa.
--   - Thread de limpeza periódica remove marcas expiradas.
--
-- Carregado DEPOIS de bridge/mdt.lua e server/plates.lua no fxmanifest (usa BridgeIsPolice,
-- IsValidSource, VPChopMDT.ReportActivity).

if not Config.TyreMarks or not Config.TyreMarks.Enable then return end

local TM = Config.TyreMarks

-- Marcas ativas: markId(int) → { coords, model(hash), modelName(string), class(int), createdAt, expires }
local TyreMarks   = {}
local nextMarkId  = 0
local createCd    = {}  -- src → GetGameTimer() até quando o jogador pode criar de novo

-- [AUDIT-FIX H1] Janela ARMADA server-side: src → GetGameTimer() de expiração. Sem ela um
-- cheater podia chamar createTyreMark a qualquer hora (sem ter cometido crime). A janela é
-- preenchida nos MESMOS pontos onde o servidor dispara `armTyreMark` (main/heat/plates/
-- advanced_chop), via o helper global VPChopArmTyreWindow abaixo. createTyreMark rejeita
-- qualquer marca fora da janela.
local ArmWindow   = {}  -- src → GetGameTimer() até quando o jogador pode CRIAR marca

-- [AUDIT-FIX H4] Rate-limit do sync em bulk (requestTyreMarks): src → próximo permitido.
local requestCd   = {}
local REQUEST_CD_MS = 10000  -- 10s entre dumps completos de marcas

--- [AUDIT-FIX H1] Arma a janela server-side de criação de marca para `src` por `ms` ms.
--- Chamado nos pontos de crime (junto ao TriggerClientEvent 'armTyreMark'). Global de
--- propósito para os outros arquivos server (main/heat/plates/advanced_chop) reusarem.
---@param src number
---@param ms number
function VPChopArmTyreWindow(src, ms)
    if not Config.TyreMarks or not Config.TyreMarks.Enable then return end
    src = tonumber(src)
    if not src then return end
    local dur = tonumber(ms) or ((TM.ArmWindowSeconds or 45) * 1000)
    local until_ = GetGameTimer() + dur
    -- Estende (crimes encadeados renovam), nunca encurta uma janela ainda aberta.
    if not ArmWindow[src] or until_ > ArmWindow[src] then
        ArmWindow[src] = until_
    end
end

--- [TYRE] Lista de jobs policiais (reusa Config.TyreMarks.PoliceJobs).
local function policeJobs()
    return TM.PoliceJobs or (Config.Plates and Config.Plates.PoliceJobs) or { 'police', 'bcso', 'sheriff' }
end

--- [TYRE] Nome pt-BR da classe GTA (0..22). Fallback 'Desconhecido'.
---@param class integer
---@return string
local function className(class)
    return (TM.ClassNames and TM.ClassNames[class]) or 'Desconhecido'
end

--- [TYRE] Broadcast filtrado: dispara `event` só para players com job policial.
---@param event string
---@param ... any
local function broadcastToPolice(event, ...)
    local jobs = policeJobs()
    for _, pid in ipairs(GetPlayers()) do
        local src = tonumber(pid)
        if src and BridgeIsPolice(src, jobs) then
            TriggerClientEvent(event, src, ...)
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- [TYRE] Criar marca (do criminoso). SERVIDOR resolve o modelo pelo netId.
-- ─────────────────────────────────────────────────────────────────────────────
RegisterNetEvent('vp_chopshop:createTyreMark', function(netId, coords)
    local src = source
    if not TM.Enable then return end
    if not IsValidSource(src) then return end

    -- [AUDIT-FIX H1] Gate de JANELA ARMADA (server-side): só aceita marca se o jogador está
    -- dentro da janela aberta por um crime real. Sem janela / expirada → rejeita (anti-cheat).
    local now = GetGameTimer()
    if not ArmWindow[src] or now > ArmWindow[src] then return end

    -- Rate limit por jogador (anti-flood).
    if createCd[src] and now < createCd[src] then return end
    createCd[src] = now + (TM.CreateCooldownMs or 1500)

    -- Validar netId → veículo real.
    if not netId or type(netId) ~= 'number' then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    -- Validar coords vindas do client (anti-teleport de pista). Devem bater com o veículo
    -- (que é a verdade server-side) dentro de uma folga generosa.
    if not coords or type(coords.x) ~= 'number' then return end
    local vehCoords = GetEntityCoords(veh)
    if #(vehCoords - vector3(coords.x, coords.y, coords.z)) > 8.0 then
        -- Coords incoerentes com o veículo → usa as do veículo (fonte de verdade).
        coords = vehCoords
    end

    -- [TYRE] RESOLVER O MODELO SERVER-SIDE (trust-no-client). GetEntityModel funciona
    -- server-side neste build (entidades OneSync). GetDisplayNameFromVehicleModel e
    -- GetVehicleClass também são acessíveis server-side para entidades de rede.
    local modelHash = GetEntityModel(veh)
    if not modelHash or modelHash == 0 then return end
    local displayName = GetDisplayNameFromVehicleModel(modelHash) or 'CARMODEL'
    local vClass      = GetVehicleClass(veh) or 0

    nextMarkId = nextMarkId + 1
    local markId = nextMarkId
    local ttl    = (TM.MarkTTLSeconds or 600) * 1000

    TyreMarks[markId] = {
        coords    = vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0),
        model     = modelHash,
        modelName = displayName,
        class     = vClass,
        createdAt = now,
        expires   = now + ttl,
    }

    -- Broadcast só para a polícia criar o ponto examinável.
    broadcastToPolice('vp_chopshop:spawnTyreMark', markId, TyreMarks[markId].coords)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- [TYRE] Sync sob demanda: polícia que loga/entra em serviço pede as marcas ativas.
-- ─────────────────────────────────────────────────────────────────────────────
RegisterNetEvent('vp_chopshop:requestTyreMarks', function()
    local src = source
    if not TM.Enable or not IsValidSource(src) then return end
    if not BridgeIsPolice(src, policeJobs()) then return end

    -- [AUDIT-FIX H4] Rate-limit (10s) — sem isso um cliente podia spammar o evento e forçar
    -- o servidor a montar/enviar o dump de TODAS as marcas em loop.
    local now = GetGameTimer()
    if requestCd[src] and now < requestCd[src] then return end
    requestCd[src] = now + REQUEST_CD_MS

    -- [AUDIT-FIX H4] Cap defensivo do tamanho do payload (proteção contra crescimento anômalo).
    local maxItems = tonumber(TM.MaxSyncItems) or 200
    local payload = {}
    for id, m in pairs(TyreMarks) do
        if #payload >= maxItems then break end
        payload[#payload + 1] = { id = id, coords = m.coords }
    end
    TriggerClientEvent('vp_chopshop:syncTyreMarks', src, payload)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- [TYRE] Examinar marca (POLÍCIA). Gate por job + proximidade server-side.
-- Retorna { modelName, class } — NUNCA placa.
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register('vp_chopshop:examineTyreMark', function(src, markId)
    if not TM.Enable or not IsValidSource(src) then return nil end
    -- Gate 1: job policial (revalidado server-side; canInteract do client é só UX).
    if not BridgeIsPolice(src, policeJobs()) then return nil end

    -- Gate 2: marca existe e não expirou.
    local mark = TyreMarks[markId]
    if not mark then return nil end
    if GetGameTimer() >= mark.expires then return nil end

    -- Gate 3: proximidade server-side (anti-exame remoto).
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local pCoords = GetEntityCoords(ped)
    if #(pCoords - mark.coords) > ((TM.ExamineDistance or 3.0) + 1.5) then return nil end

    -- [TYRE] Log no MDT — SEM PLACA (regra absoluta). Reusa VPChopMDT.ReportActivity,
    -- cuja assinatura é (plate, src, action). Não temos/nem queremos placa: passamos ''
    -- como "plate" e codificamos o modelo na string de action.
    pcall(function()
        VPChopMDT.ReportActivity('', src, ('tyre_marks_model:%s'):format(mark.modelName))
    end)

    -- Retorno: display name (o CLIENT traduz com GetLabelText) + nome da classe pt-BR.
    return {
        modelName = mark.modelName,
        class     = className(mark.class),
    }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- [TYRE] Thread de limpeza periódica de marcas expiradas (padrão do resource: Wait).
-- ─────────────────────────────────────────────────────────────────────────────
CreateThread(function()
    while true do
        Wait(30000) -- varre a cada 30s (TTL é da ordem de minutos)
        local now = GetGameTimer()
        for id, m in pairs(TyreMarks) do
            if now >= m.expires then
                TyreMarks[id] = nil
                broadcastToPolice('vp_chopshop:removeTyreMark', id)
            end
        end
        -- Limpa cooldowns de jogadores que já saíram (memória).
        for src in pairs(createCd) do
            if not IsValidSource(src) or now >= createCd[src] then createCd[src] = nil end
        end
        -- [AUDIT-FIX H1/H4] Mesma higiene para a janela armada e o CD de sync.
        for src in pairs(ArmWindow) do
            if not IsValidSource(src) or now > ArmWindow[src] then ArmWindow[src] = nil end
        end
        for src in pairs(requestCd) do
            if not IsValidSource(src) or now >= requestCd[src] then requestCd[src] = nil end
        end
    end
end)

-- [TYRE] Limpeza de cooldown ao sair (a marca é por coords, não por player — só o CD sai).
AddEventHandler('playerDropped', function()
    local src = source
    createCd[src]   = nil
    ArmWindow[src]  = nil  -- [AUDIT-FIX H1] limpar a janela armada do jogador que saiu
    requestCd[src]  = nil  -- [AUDIT-FIX H4]
end)
