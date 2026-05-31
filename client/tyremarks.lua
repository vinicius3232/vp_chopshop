-- client/tyremarks.lua
-- [TYRE] Marcas de pneu — lado CLIENT. Duas responsabilidades, totalmente isoladas:
--   1) CRIMINOSO: depois de um crime, o servidor arma este client por uma janela
--      (vp_chopshop:armTyreMark). Enquanto armado e dentro de um veículo, faz uma
--      checagem leve de BURNOUT/cantada de pneu. Ao detectar, manda só o netId do
--      veículo + coords ao servidor (trust-no-client: o SERVIDOR resolve o modelo).
--   2) POLÍCIA: recebe o broadcast de marca (vp_chopshop:spawnTyreMark) e cria um
--      ponto examinável (ox_target). Examinar → callback → notify com modelo+classe.
--
-- Carregado ANTES de client/main.lua no fxmanifest.
-- NUNCA expõe placa em lugar nenhum (decisão de design: pneu não fala placa).

if not Config.TyreMarks or not Config.TyreMarks.Enable then return end

local TM = Config.TyreMarks

-- ─────────────────────────────────────────────────────────────────────────────
-- [TYRE] BLOCO 1 — CRIMINOSO: armar janela + detectar burnout
-- ─────────────────────────────────────────────────────────────────────────────

local armedUntil   = 0   -- GetGameTimer() até quando a janela está armada
local lastBurnout  = 0   -- timestamp do último burnout detectado (cooldown anti-spam)
local marksThisArm = 0   -- nº de marcas geradas nesta janela (limite MaxMarksPerCrime)
local detectThread = false -- evita iniciar a thread de detecção em duplicidade

--- [TYRE] Heurística de burnout SEM native especulativa. Não usamos IsVehicleInBurnout
--- (não está garantido em todo build / é instável). Em vez disso comparamos:
---   - velocidade linear das rodas: GetVehicleWheelSpeed(veh)  (m/s, pode ser negativa em ré)
---   - velocidade real do chassi:   GetEntitySpeed(veh)        (m/s, sempre ≥ 0)
--- Burnout/cantada = rodas girando bem mais rápido que o deslocamento real (patinação),
--- com o carro parado ou lento. Ambas são natives CFX reais e estáveis.
---@param veh integer
---@return boolean
local function isBurningOut(veh)
    local b = TM.Burnout
    local wheelSpeed = math.abs(GetVehicleWheelSpeed(veh) + 0.0) -- giro linear das rodas
    local realSpeed  = GetEntitySpeed(veh) + 0.0                 -- deslocamento real do carro

    -- Carro precisa estar parado/lento (burnout de verdade é estático ou arrancada).
    if realSpeed > (b.MaxRealSpeed or 12.0) then return false end
    -- Roda precisa estar girando forte (ignora manobras lentas / re leve).
    if wheelSpeed < (b.MinWheelSpeed or 6.0) then return false end
    -- E girando MUITO mais que o deslocamento real → patinação clara.
    -- realSpeed pode ser ~0; somamos 0.5 para evitar divisão instável e exigir giro absoluto.
    return wheelSpeed >= ((realSpeed + 0.5) * (b.Ratio or 1.8))
end

--- [TYRE] Reporta a marca: manda APENAS netId + coords. O servidor resolve o modelo
--- pelo netId (trust-no-client) — nunca confiamos no modelo vindo do client.
---@param veh integer
local function reportTyreMark(veh)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    if not netId or netId == 0 then return end
    local coords = GetEntityCoords(veh)
    TriggerServerEvent('vp_chopshop:createTyreMark', netId, coords)
end

--- [TYRE] Thread de detecção: só roda enquanto a janela está armada. Wait adaptativo:
--- 250ms em veículo (checagem leve), 1000ms fora de veículo (quase idle). Encerra
--- sozinha quando a janela expira.
local function startDetectThread()
    if detectThread then return end
    detectThread = true
    CreateThread(function()
        while GetGameTimer() < armedUntil do
            local wait = 1000
            local ped  = cache.ped or PlayerPedId()
            local veh  = GetVehiclePedIsIn(ped, false)

            if veh and veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                wait = 250 -- só checa burnout quando o jogador é o MOTORISTA
                if marksThisArm < (TM.MaxMarksPerCrime or 2) then
                    local now = GetGameTimer()
                    if (now - lastBurnout) >= (TM.BurnoutCooldownMs or 3000) and isBurningOut(veh) then
                        lastBurnout  = now
                        marksThisArm = marksThisArm + 1
                        reportTyreMark(veh)
                    end
                end
            end

            Wait(wait)
        end
        detectThread = false -- janela expirou → desarma e libera nova thread
    end)
end

--- [TYRE] Handler de armar (disparado pelo servidor nos MESMOS pontos do crime).
---@param durationMs integer  janela em ms (ArmWindowSeconds * 1000)
RegisterNetEvent('vp_chopshop:armTyreMark', function(durationMs)
    if not TM.Enable then return end
    local dur = tonumber(durationMs) or ((TM.ArmWindowSeconds or 45) * 1000)
    -- Estende a janela (crimes encadeados renovam o tempo) e zera o contador de marcas.
    armedUntil   = GetGameTimer() + dur
    marksThisArm = 0
    startDetectThread()
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- [TYRE] BLOCO 2 — POLÍCIA: receber broadcast + ox_target de exame
-- ─────────────────────────────────────────────────────────────────────────────

-- Marcas ativas no client da polícia: markId → { coords, zoneId }.
local localMarks = {}

--- [TYRE] true se o jogador local é polícia (UX; o servidor revalida o job no callback).
local policeSet = {}
for _, j in ipairs(TM.PoliceJobs or { 'police', 'bcso', 'sheriff' }) do policeSet[j] = true end

local function playerIsPolice()
    if GetResourceState('qbx_core') ~= 'started' then return false end
    local ok, pdata = pcall(function() return exports.qbx_core:GetPlayerData() end)
    local job = ok and pdata and pdata.job and pdata.job.name
    return job ~= nil and policeSet[job] == true
end

--- [TYRE] Cria o ponto examinável (ox_target box) para uma marca recebida.
---@param markId integer
---@param coords vector3
local function spawnLocalMark(markId, coords)
    if localMarks[markId] then return end
    if GetResourceState('ox_target') ~= 'started' then return end

    local zoneId = exports.ox_target:addBoxZone({
        coords = vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0),
        size = vector3(2.0, 2.0, 1.5),
        rotation = 0.0,
        debug = Config.Debug or false,
        options = {
            {
                name     = ('vp_chopshop:examineTyre:%s'):format(markId),
                label    = L('tyre_target_examine'),
                icon     = 'fa-solid fa-magnifying-glass',
                distance = TM.ExamineDistance or 3.0,
                -- Gate de UX: só polícia vê a opção. Servidor revalida job + proximidade.
                canInteract = function() return playerIsPolice() end,
                onSelect = function()
                    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:examineTyreMark', false, markId)
                    if not cbOk or not res or not res.modelName then
                        VPChopNotify(L('notify_generic_error'), 'error')
                        return
                    end
                    -- [TYRE] O servidor resolve o DISPLAY NAME do modelo (ex.: 'SULTANRS') a
                    -- partir do netId (trust-no-client). A tradução do label (ex.: 'Sultan RS')
                    -- é client-side: GetLabelText só existe/funciona no client. Fallback: usa o
                    -- próprio display name se o label não estiver carregado.
                    local pretty = GetLabelText(res.modelName)
                    if not pretty or pretty == '' or pretty == 'NULL' then pretty = res.modelName end
                    -- "Marcas de pneu de um %s (%s)" — modelo + classe. SEM placa.
                    VPChopNotify(L('tyre_examine_result_fmt', pretty, res.class or '?'), 'inform', 7000)
                end,
            },
        },
    })

    localMarks[markId] = { coords = coords, zoneId = zoneId }
end

--- [TYRE] Remove o ponto local (TTL expirado server-side ou cleanup).
---@param markId integer
local function removeLocalMark(markId)
    local m = localMarks[markId]
    if not m then return end
    if m.zoneId then pcall(function() exports.ox_target:removeZone(m.zoneId) end) end
    localMarks[markId] = nil
end

-- Broadcast do servidor: criar marca (só policiais recebem — filtragem é server-side).
RegisterNetEvent('vp_chopshop:spawnTyreMark', function(markId, coords)
    if not TM.Enable then return end
    if not markId or not coords or type(coords.x) ~= 'number' then return end
    spawnLocalMark(markId, coords)
end)

-- Broadcast do servidor: remover marca (expirou / limpeza).
RegisterNetEvent('vp_chopshop:removeTyreMark', function(markId)
    if not markId then return end
    removeLocalMark(markId)
end)

-- [TYRE] Sync inicial: ao virar polícia / logar, pedir as marcas ativas ao servidor.
RegisterNetEvent('vp_chopshop:syncTyreMarks', function(marks)
    if not TM.Enable or type(marks) ~= 'table' then return end
    for _, m in ipairs(marks) do
        if m.id and m.coords then spawnLocalMark(m.id, m.coords) end
    end
end)

-- Limpeza ao parar o resource (evita zonas órfãs no ox_target).
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(localMarks) do removeLocalMark(id) end
end)

-- Ao carregar, pedir o estado atual (caso a polícia entre depois de marcas já criadas).
CreateThread(function()
    Wait(2000)
    if playerIsPolice() then
        TriggerServerEvent('vp_chopshop:requestTyreMarks')
    end
end)
