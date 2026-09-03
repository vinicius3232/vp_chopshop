-- client/plates.lua
-- [FASE1 placas] Roubo de placa física (lado cliente).
-- Adiciona um ox_target GLOBAL em veículos com a opção "Arrancar placa":
--   canInteract → tem chave de fenda E não é o veículo em que o próprio jogador está dirigindo.
--   onSelect    → lib.skillCheck (padrão do resource) → callback server 'vp_chopshop:stealPlate'.
-- A VERDADE (distância, placa real, item, cooldown) é toda validada no servidor (server/plates.lua).
-- Também escuta os eventos de broadcast para apagar a placa visível e disparar dispatch.

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [F4 testemunhas] Score de testemunhas ao redor (imersão de dispatch)       ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Conta NPCs vivos não-player + players próximos (exceto o autor) num raio configurável,
-- centrado no veículo. Player pesa mais que NPC. O score é reportado ao servidor, que decide
-- a chance de dispatch e o bônus (com CAP server-side). Client-side é low-stakes (imersão),
-- nunca a verdade do crime. Usa GetGamePool sob demanda (1× no clique), não por frame.
---@param veh integer  handle do veículo alvo
---@return number score
function VPChopWitnessScore(veh)
    local w = Config.Plates and Config.Plates.Witness
    if not w then return 0.0 end
    local center = (veh and veh ~= 0 and DoesEntityExist(veh)) and GetEntityCoords(veh)
        or GetEntityCoords(PlayerPedId())
    local radius = tonumber(w.Radius) or 45.0
    local r2 = radius * radius
    local myPed = PlayerPedId()

    local score = 0.0

    -- NPCs (peds não-player, vivos) dentro do raio.
    local npcWeight = tonumber(w.NpcWeight) or 1.0
    if npcWeight > 0 then
        for _, ped in ipairs(GetGamePool('CPed')) do
            if ped ~= myPed
                and not IsPedAPlayer(ped)
                and not IsPedDeadOrDying(ped, true)
                and DoesEntityExist(ped)
            then
                local d = GetEntityCoords(ped) - center
                if (d.x * d.x + d.y * d.y + d.z * d.z) <= r2 then
                    score = score + npcWeight
                end
            end
        end
    end

    -- Players próximos (exceto o autor) — peso maior.
    local playerWeight = tonumber(w.PlayerWeight) or 3.0
    if playerWeight > 0 then
        for _, pid in ipairs(GetActivePlayers()) do
            local pPed = GetPlayerPed(pid)
            if pPed ~= 0 and pPed ~= myPed and DoesEntityExist(pPed) then
                local d = GetEntityCoords(pPed) - center
                if (d.x * d.x + d.y * d.y + d.z * d.z) <= r2 then
                    score = score + playerWeight
                end
            end
        end
    end

    return score
end

CreateThread(function()
    -- Respeitar o toggle da feature e a presença do ox_target.
    if not Config.Plates or not Config.Plates.Enable then return end

    -- Esperar o ox_target subir (mesmo padrão de espera de client/main.lua).
    local tries = 0
    while GetResourceState('ox_target') ~= 'started' and tries < 120 do
        Wait(250)
        tries = tries + 1
    end
    if GetResourceState('ox_target') ~= 'started' then return end

    local tool = Config.Plates.ToolItem or 'screwdriver'

    exports.ox_target:addGlobalVehicle({
        {
            name     = 'vp_chopshop:stealPlate',
            label    = L('plate_target_steal'),
            icon     = 'fa-solid fa-screwdriver',
            -- distância de interação do alvo (~2.0); a distância "real" é checada no servidor
            distance = 2.0,
            canInteract = function(entity)
                -- 1) precisa da chave de fenda (UX — servidor revalida)
                local count = exports.ox_inventory:Search('count', tool) or 0
                if count < 1 then return false end
                -- 2) não pode ser o próprio veículo do jogador (UX — servidor não bloqueia ainda
                --    por ownership na Fase 1, mas evitamos roubar a placa do carro que dirigimos)
                -- PlayerPedId() em vez de cache.ped: espelha o padrão usado no resto do resource;
                -- canInteract roda sob demanda (não por frame), sem custo relevante.
                local myVeh = GetVehiclePedIsIn(cache.ped, false)
                if myVeh ~= 0 and myVeh == entity then return false end
                return true
            end,
            onSelect = function(data)
                local veh = data and data.entity
                if not veh or veh == 0 or not DoesEntityExist(veh) then
                    VPChopNotify(L('notify_generic_error'), 'error')
                    return
                end

                -- Minigame antes de arrancar. UX no client; a verdade (item/distância/
                -- cooldown) é validada no server abaixo.
                local sc = Config.Plates.SkillCheck
                if sc then
                    local passed = lib.skillCheck(sc.difficulties, sc.keys)
                    if not passed then
                        VPChopNotify(L('notify_skill_fail'), 'error')
                        return
                    end
                end

                local netId = NetworkGetNetworkIdFromEntity(veh)
                if not netId or netId == 0 then
                    VPChopNotify(L('notify_generic_error'), 'error')
                    return
                end

                -- [F4 testemunhas] Score de testemunhas calculado AGORA (no momento do roubo),
                -- centrado no veículo. Low-stakes: server decide dispatch/bônus com CAP.
                local witnessScore = VPChopWitnessScore(veh)

                local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:stealPlate', false, netId, witnessScore)
                if not cbOk or not res then
                    VPChopNotify(L('notify_generic_error'), 'error')
                    return
                end

                if res.ok then
                    VPChopNotify(L('plate_stolen_success'), 'success')
                    -- [F4 testemunhas] Bônus por risco (XP/cash) aplicado server-side com CAP.
                    if (res.bonusXp and res.bonusXp > 0) or (res.bonusCash and res.bonusCash > 0) then
                        VPChopNotify(L('plate_witness_bonus_fmt', res.bonusXp or 0, res.bonusCash or 0), 'inform')
                    end
                else
                    -- Mapear erros do servidor para mensagens amigáveis (pt-BR via locale).
                    local errKey = ({
                        no_tool   = 'plate_no_tool',
                        range     = 'plate_too_far',
                        own       = 'plate_own_vehicle',
                        cooldown  = 'plate_cooldown',
                        no_plate  = 'plate_generic_error',
                        inventory = 'plate_generic_error',
                        done      = 'plate_generic_error',
                    })[res.err] or 'plate_generic_error'
                    VPChopNotify(L(errKey), 'error')
                end
            end,
        },
    })
end)

-- ─── Broadcast: apagar a placa visível nos clientes próximos ──────────────────
RegisterNetEvent('vp_chopshop:client:plateCleared', function(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    -- Placa em branco — o item físico saiu do carro.
    SetVehicleNumberPlateText(veh, '')
end)

-- ─── Dispatch: servidor manda o autor do roubo chamar a polícia ───────────────
-- Reutiliza o MESMO mecanismo do alarme (VPChopTriggerDispatch, definida em client/main.lua).
RegisterNetEvent('vp_chopshop:client:plateDispatch', function(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        VPChopTriggerDispatch(veh)
    end
end)

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [FASE2 placas] Aplicar placa falsa + sync visível + remoção policial      ║
-- ╚══════════════════════════════════════════════════════════════════════════╝

-- ─── Sync da placa VISÍVEL (cosmético) ────────────────────────────────────────
-- O servidor manda este evento (broadcast filtrado por proximidade) quando uma placa
-- falsa é aplicada (texto = falsa) ou removida/restaurada (texto = real). Apenas troca
-- o texto exibido — a verdade do crime vive no servidor (mapa falsa→real).
RegisterNetEvent('vp_chopshop:client:setVisiblePlate', function(netId, text)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    SetVehicleNumberPlateText(veh, tostring(text or ''))
end)

-- ─── Re-sync robusto para clientes que entram no scope DEPOIS ──────────────────
-- O servidor seta um MARCADOR statebag 'vpFakeRealPlate' (a placa REAL) no veículo, REPLICADO.
-- A placa FALSA em si NÃO vai no statebag (segurança). Para reexibir a falsa a quem entra no
-- scope, o servidor já reenvia 'setVisiblePlate' no broadcast inicial; aqui tratamos o caso de
-- um cliente que recebe o statebag e ainda vê a placa antiga: pedimos a falsa ao servidor.
--
-- Como a falsa é cosmética, basta exibir o texto correto. Usamos o handler do statebag para
-- detectar a presença do disfarce e perguntar ao servidor qual texto exibir (placa falsa).
AddStateBagChangeHandler('vpFakeRealPlate', nil, function(bagName, _key, value)
    -- Só nos importa quando o disfarce É ativado (value presente). Limpeza (nil) já vem
    -- acompanhada do broadcast 'setVisiblePlate' com a placa real.
    if value == nil then return end
    -- A entidade pode ainda não existir localmente quando o statebag chega; resolvemos
    -- o handle a partir do nome do bag com retry curto best-effort.
    CreateThread(function()
        local entity, tries = 0, 0
        while (entity == 0 or not DoesEntityExist(entity)) and tries < 20 do
            entity = GetEntityFromStateBagName(bagName)
            if entity ~= 0 and DoesEntityExist(entity) then break end
            Wait(100); tries = tries + 1
        end
        if entity == 0 or not DoesEntityExist(entity) then return end
        local netId = NetworkGetNetworkIdFromEntity(entity)
        if not netId or netId == 0 then return end
        -- Perguntar ao servidor o texto da placa falsa a exibir (não vai no statebag por segurança).
        local cbOk, fake = pcall(lib.callback.await, 'vp_chopshop:getVisibleFakePlate', false, netId)
        if cbOk and type(fake) == 'string' and fake ~= '' then
            if DoesEntityExist(entity) then SetVehicleNumberPlateText(entity, fake) end
        end
    end)
end)

-- ─── Export de USO do item `fake_plate` ───────────────────────────────────────
-- Espelha o padrão exports('useBenchItem', ...) de client/main.lua, registrado no item via
-- client = { export = 'vp_chopshop.useFakePlateItem' }. `data.metadata.plate` traz a placa-alvo.
local _applyingFakePlate = false  -- trava reentrância (anti duplo-clique)

exports('useFakePlateItem', function(data)
    if _applyingFakePlate then return end
    if not Config.Plates or not Config.Plates.Enable then
        VPChopNotify(L('notify_generic_error'), 'error'); return
    end

    -- Placa-alvo vem da metadata do item (definida na forja).
    local sourcePlate = data and data.metadata and data.metadata.plate

    -- Resolver o veículo: o que o jogador dirige OU o mais próximo (ox_lib).
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then
        local coords = GetEntityCoords(ped)
        local maxDist = (tonumber(Config.Plates.ApplyMaxDistance) or 4.0)
        veh = lib.getClosestVehicle(coords, maxDist, true)
    end
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        VPChopNotify(L('fake_plate_no_vehicle'), 'error'); return
    end

    local netId = NetworkGetNetworkIdFromEntity(veh)
    if not netId or netId == 0 then
        VPChopNotify(L('notify_generic_error'), 'error'); return
    end

    _applyingFakePlate = true

    -- Barra de progresso (mesmo padrão de craft do resource).
    local okBar = lib.progressBar({
        duration = 6000,
        label = L('fake_plate_progress_apply'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    })
    if not okBar then _applyingFakePlate = false; return end

    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:applyFakePlate', false, netId, sourcePlate)
    _applyingFakePlate = false
    if not cbOk or not res then
        VPChopNotify(L('notify_generic_error'), 'error'); return
    end

    if res.ok then
        VPChopNotify(L('fake_plate_applied_success'), 'success')
    else
        local errKey = ({
            owned     = 'fake_plate_owned_blocked',
            in_use    = 'fake_plate_in_use',
            range     = 'fake_plate_too_far',
            no_item   = 'fake_plate_no_item',
            no_plate  = 'fake_plate_generic_error',
            same      = 'fake_plate_generic_error',
            cooldown  = 'fake_plate_cooldown',
            vehicle   = 'fake_plate_no_vehicle',
        })[res.err] or 'fake_plate_generic_error'
        VPChopNotify(L(errKey), 'error')
    end
end)

-- ─── ox_target POLICIAL: remover placa falsa ─────────────────────────────────
-- Opção GLOBAL em veículos, visível só para jobs policiais (Config.Plates.PoliceJobs) e só
-- quando o carro está disfarçado (callback 'vp_chopshop:isFakePlated'). A verdade (job,
-- proximidade, disfarce) é revalidada no servidor — o canInteract é apenas UX.
CreateThread(function()
    if not Config.Plates or not Config.Plates.Enable then return end

    local tries = 0
    while GetResourceState('ox_target') ~= 'started' and tries < 120 do
        Wait(250); tries = tries + 1
    end
    if GetResourceState('ox_target') ~= 'started' then return end

    -- Conjunto de jobs policiais para o gate de UX no client.
    local policeSet = {}
    for _, j in ipairs(Config.Plates.PoliceJobs or { 'police', 'bcso', 'sheriff' }) do
        policeSet[j] = true
    end

    --- Verifica o job atual do jogador via qbx_core (UX; servidor revalida).
    local function playerIsPolice()
        if GetResourceState('qbx_core') ~= 'started' then return false end
        local ok, pdata = pcall(function() return exports.qbx_core:GetPlayerData() end)
        local job = ok and pdata and pdata.job and pdata.job.name
        return job ~= nil and policeSet[job] == true
    end

    exports.ox_target:addGlobalVehicle({
        {
            name     = 'vp_chopshop:removeFakePlate',
            label    = L('fake_plate_target_remove'),
            icon     = 'fa-solid fa-id-card',
            distance = 2.5,
            canInteract = function(entity)
                -- 1) só policiais (UX — servidor revalida o job)
                if not playerIsPolice() then return false end
                if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
                -- 2) só em carro disfarçado: marcador statebag rápido (replicado pelo server)
                local okState, marker = pcall(function() return Entity(entity).state.vpFakeRealPlate end)
                return okState and marker ~= nil
            end,
            onSelect = function(odata)
                local veh = odata and odata.entity
                if not veh or veh == 0 or not DoesEntityExist(veh) then
                    VPChopNotify(L('notify_generic_error'), 'error'); return
                end
                local netId = NetworkGetNetworkIdFromEntity(veh)
                if not netId or netId == 0 then
                    VPChopNotify(L('notify_generic_error'), 'error'); return
                end
                local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:removeFakePlate', false, netId)
                if not cbOk or not res then
                    VPChopNotify(L('notify_generic_error'), 'error'); return
                end
                if res.ok then
                    VPChopNotify(L('fake_plate_removed_success'), 'success')
                else
                    local errKey = ({
                        not_police = 'fake_plate_not_police',
                        no_fake    = 'fake_plate_not_disguised',
                        range      = 'fake_plate_too_far',
                        cooldown   = 'fake_plate_cooldown',
                    })[res.err] or 'fake_plate_generic_error'
                    VPChopNotify(L(errKey), 'error')
                end
            end,
        },
    })
end)
