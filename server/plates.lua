-- server/plates.lua
-- [FASE1 placas] Roubo de placa física.
-- Callback: 'vp_chopshop:stealPlate' — recebe netId, resolve placa REAL server-side,
-- entrega item `stolen_plate` com metadata { plate, model, takenAt } e manda os clientes
-- próximos deixarem a placa visível em branco. Rende dispatch e XP de progressão tier 1.
--
-- Padrões espelhados de server/advanced_chop.lua e server/heat.lua:
--   IsValidSource / ServerPlayerIsReady, cooldown por src + cleanup no playerDropped,
--   netId tonumber + validação de tipos, ValidatePlayerNearVehicle (proximity server-side),
--   flag anti-duplo-roubo por netId limpa no entityRemoved,
--   broadcast FILTRADO por proximidade (~150u) em vez de -1,
--   VPChopMDT.ReportActivity + TriggerEvent(VPChopEvt.PART_CHOPPED, ...).

-- ─── Estado por jogador / por netId ──────────────────────────────────────────
local PlateStealCooldown = {} ---@type table<number, number>  src → expiry (GetGameTimer)
local PlateStolen        = {} ---@type table<number, boolean>  netId → já roubada (anti-duplo)

-- [F2 persist][PERF] Cache em memória das placas disfarçadas (real → falsa). O entityCreated
-- consulta ISTO (O(1), sem DB) para cada veículo que spawna — senão seria 1 query por carro de
-- trânsito. O conjunto de disfarces é pequeno; mantemos o cache sincronizado em apply/remove e
-- carregamos do DB no boot. Verdade continua sendo o DB; o cache é só um filtro rápido.
local DisguiseByReal = {} ---@type table<string, string>  real_plate → fake_plate
local DisguiseCacheReady = false

--- Atualiza o cache ao aplicar/remover um disfarce.
local function cacheSetDisguise(realPlate, fakePlate)
    if realPlate and realPlate ~= '' then DisguiseByReal[realPlate] = fakePlate or nil end
end

-- Carrega o cache do DB no boot (após oxmysql pronto). Idempotente.
CreateThread(function()
    while not DisguiseCacheReady do
        if VPChopDbLoadAllDisguises then
            local rows = VPChopDbLoadAllDisguises()
            if type(rows) == 'table' then
                for i = 1, #rows do
                    local r = rows[i]
                    if r and r.real_plate then DisguiseByReal[r.real_plate] = r.fake_plate end
                end
                DisguiseCacheReady = true
                break
            end
        end
        Wait(500)
    end
end)

--- Cooldown configurável (segundos → ms). Fallback 30s.
local function plateCooldownMs()
    return (tonumber(Config.Plates and Config.Plates.StealCooldownSeconds) or 30) * 1000
end

-- Limpeza de cooldown ao desconectar (mesmo padrão do VinScratchCooldown em heat.lua).
AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1] capturar antes de qualquer yield
    PlateStealCooldown[src] = nil
end)

-- Limpar flag anti-duplo-roubo quando a entidade some (padrão do AdvState em advanced_chop.lua).
AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId and netId ~= 0 then
        PlateStolen[netId] = nil
    end
end)

-- ─── Broadcast filtrado: clientes próximos apagam a placa visível ─────────────
--- Em vez de TriggerClientEvent(-1), só notificamos clientes a ~150u da entidade
--- (mesmo padrão H4 do advanced_chop.lua para breakDoor).
---@param netId integer
---@param vehCoords vector3|nil
local function broadcastPlateCleared(netId, vehCoords)
    for _, pid in ipairs(GetPlayers()) do
        local pidN = tonumber(pid)
        if pidN then
            local send = true
            if vehCoords then
                local pped = GetPlayerPed(pidN)
                send = pped and pped ~= 0 and #(GetEntityCoords(pped) - vehCoords) < 150.0
            end
            if send then
                TriggerClientEvent('vp_chopshop:client:plateCleared', pidN, netId)
            end
        end
    end
end

-- ─── [F4 testemunhas] Helpers de dispatch/bônus por testemunhas ───────────────
--- Calcula a chance de dispatch (0..1) a partir do score de testemunhas (client-reportado).
--- Aplica BaseChance + ChancePerScore*score (saturado em MaxChance) e o NightModifier.
---@param score number  score de testemunhas (>=0); client-side, tratado como low-stakes
---@return number chance 0..1
local function witnessDispatchChance(score)
    local w = Config.Plates and Config.Plates.Witness
    if not w then return 0.0 end
    score = math.max(0.0, tonumber(score) or 0.0)
    local chance = (tonumber(w.BaseChance) or 0.0) + (tonumber(w.ChancePerScore) or 0.0) * score
    local maxC = tonumber(w.MaxChance) or 1.0
    if chance > maxC then chance = maxC end
    -- Modificador noturno (servidor é a verdade da hora: os.date local do host).
    local hour = tonumber(os.date('%H')) or 12
    local s, e = tonumber(w.NightStartHour) or 0, tonumber(w.NightEndHour) or 0
    local isNight = (s <= e) and (hour >= s and hour < e) or (s > e and (hour >= s or hour < e))
    if isNight then chance = chance * (tonumber(w.NightModifier) or 1.0) end
    if chance < 0 then chance = 0 end
    return chance
end

--- Aplica o bônus por risco (XP + cash) proporcional ao score, com CAP server-side.
--- O score é CLIENT-SIDE → low-stakes: limitamos o bônus para não ser exploitável.
--- Trade-off de confiança: um cliente malicioso pode inflar o score, mas o ganho máximo
--- é pequeno (BonusXp / BonusCashMax) e o cash bônus é cosmético frente ao valor da placa.
---@param src number
---@param score number
---@return integer bonusXp, integer bonusCash  (0,0 se nenhum bônus)
local function applyWitnessBonus(src, score)
    local w = Config.Plates and Config.Plates.Witness
    if not w then return 0, 0 end
    score = math.max(0.0, tonumber(score) or 0.0)
    if score < (tonumber(w.BonusMinScore) or math.huge) then return 0, 0 end  -- sem testemunhas reais → sem bônus

    -- Fração 0..1 do score relativo ao "teto" implícito (MaxChance/ChancePerScore).
    -- CAP duro: a fração nunca passa de 1.0, então o bônus nunca passa dos máximos da config.
    local capScore = (tonumber(w.MaxChance) or 1.0) / math.max(0.001, tonumber(w.ChancePerScore) or 1.0)
    local frac = math.min(1.0, score / math.max(1.0, capScore))

    local bonusXp = math.floor((tonumber(w.BonusXp) or 0) * frac + 0.5)
    -- [AUDIT-FIX M5] Hardcap absoluto em código (além da config): blinda contra config errada
    -- ou valores absurdos. XP teto 500, cash teto 1000.
    bonusXp = math.min(bonusXp, 500)
    if bonusXp > 0 then VPChopAddXp(src, bonusXp, 'plate_witness_bonus') end

    local bonusCash = math.floor((tonumber(w.BonusCashMax) or 0) * frac + 0.5)
    bonusCash = math.min(bonusCash, 1000)  -- [AUDIT-FIX M5] hardcap absoluto
    if bonusCash > 0 then BridgeAddCash(src, bonusCash, 'vp_chopshop:plate_witness_bonus') end

    return bonusXp, bonusCash
end

-- ─── Callback: roubar placa ───────────────────────────────────────────────────
-- [F4 testemunhas] 2º arg `witnessScore` vem do client (peds+players próximos). É low-stakes:
-- usado só para chance de dispatch e bônus capado — toda a verdade do roubo segue revalidada.
lib.callback.register('vp_chopshop:stealPlate', function(src, netId, witnessScore)
    -- Feature desligada
    if not Config.Plates or not Config.Plates.Enable then
        return { ok = false, err = 'disabled' }
    end

    -- Guard de fonte + jogador carregado
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    -- Cooldown anti-farm por jogador
    local now = GetGameTimer()
    if PlateStealCooldown[src] and now < PlateStealCooldown[src] then
        return { ok = false, err = 'cooldown' }
    end

    -- Validar netId (rejeita payloads malformados de lua executor)
    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end

    -- Anti-duplo-roubo: placa desta entidade já foi arrancada nesta sessão
    if PlateStolen[netId] then return { ok = false, err = 'done' } end

    -- Resolver veículo a partir do netId
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return { ok = false, err = 'vehicle' }
    end

    -- Proximity check server-side (verdade — nunca confiar no client)
    local maxDist = tonumber(Config.Plates.MaxDistance) or 3.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist + 1.0) then
        return { ok = false, err = 'range' }
    end

    -- Placa REAL resolvida no servidor (nunca confiamos no cliente)
    local realPlate = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', '')
    if realPlate == '' then return { ok = false, err = 'no_plate' } end

    -- Ferramenta exigida (verdade server-side; client só faz a UX)
    local tool = Config.Plates.ToolItem or 'screwdriver'
    if InvCount(src, tool) < 1 then
        return { ok = false, err = 'no_tool' }
    end

    -- Modelo do veículo (metadata informativa do item)
    local model = GetEntityModel(veh)

    -- Marcar como roubada ANTES de operações com yield (evita race entre callbacks simultâneos)
    PlateStolen[netId] = true
    PlateStealCooldown[src] = now + plateCooldownMs()

    -- Entregar item com metadata. InvAdd → exports.ox_inventory:AddItem(src, item, count, metadata).
    local added = exports.ox_inventory:AddItem(src, 'stolen_plate', 1, {
        plate   = realPlate,
        model   = model,
        takenAt = os.time(),
    })
    if not added then
        -- Inventário cheio / falha: reverter flag e cooldown para o jogador poder tentar de novo
        PlateStolen[netId] = nil
        PlateStealCooldown[src] = nil
        return { ok = false, err = 'inventory' }
    end

    -- Apagar a placa visível nos clientes próximos (broadcast filtrado por proximidade)
    local vehCoords = GetEntityCoords(veh)
    broadcastPlateCleared(netId, vehCoords)

    -- [F4 testemunhas] Dispatch PROBABILÍSTICO por testemunhas (substitui o booleano fixo).
    -- Lugar vazio → quase nunca chama polícia; movimentado → chance sobe até MaxChance.
    -- Fallback ao comportamento legado se Witness.Enable = false.
    local witnessOn = Config.Plates.Witness and Config.Plates.Witness.Enable
    local bonusXp, bonusCash = 0, 0
    if witnessOn then
        local chance = witnessDispatchChance(witnessScore)
        if math.random() < chance then
            TriggerClientEvent('vp_chopshop:client:plateDispatch', src, netId)
        end
        -- Bônus por risco: roubo concluído COM testemunhas perto (XP + cash capados).
        bonusXp, bonusCash = applyWitnessBonus(src, witnessScore)
    elseif Config.Plates.DispatchOnSteal then
        TriggerClientEvent('vp_chopshop:client:plateDispatch', src, netId)
    end

    -- Reportar ao MDT e emitir XP via barramento de eventos (phase 1 = tier 1)
    VPChopMDT.ReportActivity(realPlate, src, 'plate_stolen')
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'plate_theft', 1)

    -- [EVIDENCE] Arrancar a placa deixa vestígio no veículo. `vehCoords` e `realPlate` (REAL,
    -- resolvida server-side acima) já em escopo → coords + heat scaling.
    VPChopLeaveEvidence(src, vehCoords, 'plate_steal', realPlate)
    -- [TYRE] Armar a janela de marca de pneu (mesmo ponto do crime; reusa o hook).
    if Config.TyreMarks and Config.TyreMarks.Enable then
        local armMs = (Config.TyreMarks.ArmWindowSeconds or 45) * 1000
        VPChopArmTyreWindow(src, armMs)  -- [AUDIT-FIX H1] arma janela server-side
        TriggerClientEvent('vp_chopshop:armTyreMark', src, armMs)
    end

    -- [F4 testemunhas] Devolver o bônus aplicado p/ o client notificar (cosmético).
    return { ok = true, bonusXp = bonusXp, bonusCash = bonusCash }
end)

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [FASE2 placas] FORJAR + APLICAR placa falsa  |  [FASE3] reversão segura   ║
-- ╚══════════════════════════════════════════════════════════════════════════╝

-- ─── Estado por jogador (cooldowns das novas ações) ──────────────────────────
local ForgeCooldown  = {} ---@type table<number, number>  src → expiry (GetGameTimer)
local ApplyCooldown  = {} ---@type table<number, number>
local RemoveCooldown = {} ---@type table<number, number>

AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1] capturar antes de qualquer yield
    ForgeCooldown[src]  = nil
    ApplyCooldown[src]  = nil
    RemoveCooldown[src] = nil
end)

--- Cooldowns (segundos → ms) com fallbacks seguros.
local function forgeCdMs()  return (tonumber(Config.Plates and Config.Plates.ForgeCooldownSeconds)  or 15) * 1000 end
local function applyCdMs()  return (tonumber(Config.Plates and Config.Plates.ApplyCooldownSeconds)  or 5)  * 1000 end
local function removeCdMs() return (tonumber(Config.Plates and Config.Plates.RemoveCooldownSeconds) or 3)  * 1000 end

--- Normaliza/valida formato de placa GTA (alfanumérico, ≤ 8). Devolve uppercase sem espaços.
---@param raw any
---@return string|nil
local function sanitizePlate(raw)
    if type(raw) ~= 'string' then return nil end
    local p = raw:gsub('%s+', ''):upper()
    if p == '' or #p > 8 then return nil end
    -- Apenas A-Z e 0-9 (rejeita injeção/metadata maliciosa de lua executor)
    if p:find('[^A-Z0-9]') then return nil end
    return p
end

-- ─── Bancada mais próxima do jogador (gate de forja) ─────────────────────────
--- A forja exige estar JUNTO a uma bancada (ServerBenches + ValidatePlayerNearCoords),
--- exatamente como o craft normal. Não confiamos em índice vindo do client.
---@param src number
---@return boolean
local function isPlayerNearAnyBench(src)
    if not ServerBenches then return false end
    for _, bench in ipairs(ServerBenches) do
        if bench and bench.coords and ValidatePlayerNearCoords(src, bench.coords) then
            return true
        end
    end
    return false
end

-- ─── Callback: FORJAR placa falsa ─────────────────────────────────────────────
-- Fluxo DEDICADO (fora de Config.BenchRecipes) porque o output herda a placa do
-- `stolen_plate` específico. Consome a placa roubada escolhida + insumos, com ROLLBACK
-- atômico (padrão de server/bench.lua), e devolve `fake_plate` com metadata { plate }.
lib.callback.register('vp_chopshop:forgeFakePlate', function(src, sourcePlate)
    -- Feature desligada
    if not Config.Plates or not Config.Plates.Enable then return { ok = false, err = 'disabled' } end

    -- Guards de fonte + jogador carregado
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    -- Cooldown anti-farm
    local now = GetGameTimer()
    if ForgeCooldown[src] and now < ForgeCooldown[src] then return { ok = false, err = 'cooldown' } end

    -- Proximidade de bancada (verdade server-side — nunca confiar no client)
    if not isPlayerNearAnyBench(src) then return { ok = false, err = 'distance' } end

    -- Gate de tier (Fase 2 = tier 2 por padrão)
    local needTier = tonumber(Config.Plates.ForgeTier) or 2
    local prog = VPChopGetProgression(src)
    if not prog or prog.tier < needTier then return { ok = false, err = 'tier' } end

    -- Resolver a `stolen_plate` a usar. O client pode mandar a placa-fonte escolhida;
    -- validamos o formato e CONFIRMAMOS que o jogador realmente possui esse item com
    -- essa metadata (Search 'slots' → metadata.plate). Sem confiar no client.
    local wantPlate = sanitizePlate(sourcePlate)  -- pode ser nil (pega a primeira disponível)
    local slots = exports.ox_inventory:Search(src, 'slots', 'stolen_plate')
    if type(slots) ~= 'table' or #slots == 0 then return { ok = false, err = 'no_source' } end

    local chosenMeta, chosenPlate
    for i = 1, #slots do
        local s = slots[i]
        local meta = s and s.metadata
        local pl = meta and sanitizePlate(meta.plate)
        if pl then
            if not wantPlate or wantPlate == pl then
                chosenMeta, chosenPlate = meta, pl
                break
            end
        end
    end
    if not chosenPlate then return { ok = false, err = 'no_source' } end

    -- Conferir insumos ANTES de remover qualquer coisa
    local inputs = Config.Plates.ForgeInputs or {}
    for itemName, need in pairs(inputs) do
        if InvCount(src, itemName) < (tonumber(need) or 0) then return { ok = false, err = 'inputs' } end
    end

    -- ── Remoção atômica com rollback (padrão server/bench.lua) ──
    -- 1) Consumir a `stolen_plate` ESPECÍFICA (match por metadata → remove a instância certa).
    local removedStolen = exports.ox_inventory:RemoveItem(src, 'stolen_plate', 1, chosenMeta) == true
    if not removedStolen then return { ok = false, err = 'remove' } end

    -- 2) Consumir insumos; se algum falhar, devolver tudo o que já saiu.
    local removed = {}
    for itemName, need in pairs(inputs) do
        local n = tonumber(need) or 0
        if n > 0 then
            if not InvRemove(src, itemName, n) then
                for rName, rAmt in pairs(removed) do InvAdd(src, rName, rAmt) end
                exports.ox_inventory:AddItem(src, 'stolen_plate', 1, chosenMeta)  -- restaurar placa-fonte
                return { ok = false, err = 'remove' }
            end
            removed[itemName] = n
        end
    end

    -- 3) Entregar a placa FALSA com metadata { plate = placa da roubada }.
    local added = exports.ox_inventory:AddItem(src, 'fake_plate', 1, { plate = chosenPlate })
    if not added then
        -- Inventário cheio: reverter insumos E a placa-fonte (rollback completo).
        for rName, rAmt in pairs(removed) do InvAdd(src, rName, rAmt) end
        exports.ox_inventory:AddItem(src, 'stolen_plate', 1, chosenMeta)
        return { ok = false, err = 'inventory' }
    end

    -- Sucesso: ativar cooldown e creditar XP (reason 'fake_plate' na XP_TABLE).
    ForgeCooldown[src] = now + forgeCdMs()
    VPChopAddXp(src, tonumber(Config.Plates.ForgeXp) or 22, 'fake_plate')
    VPChopDiscordLog('[FASE2 placas] Forja de placa falsa',
        ('Placa-fonte: %s | src: %s'):format(chosenPlate, tostring(src)))

    -- [EVIDENCE] A forja não envolve veículo: vestígio fica no local do jogador (junto à
    -- bancada, já validado por isPlayerNearAnyBench). Coords do ped server-side.
    VPChopLeaveEvidence(src, GetEntityCoords(GetPlayerPed(src)), 'plate_forge')
    -- [TYRE] Armar a janela de marca de pneu (mesmo ponto do crime; reusa o hook).
    if Config.TyreMarks and Config.TyreMarks.Enable then
        local armMs = (Config.TyreMarks.ArmWindowSeconds or 45) * 1000
        VPChopArmTyreWindow(src, armMs)  -- [AUDIT-FIX H1] arma janela server-side
        TriggerClientEvent('vp_chopshop:armTyreMark', src, armMs)
    end

    return { ok = true, plate = chosenPlate }
end)

-- ─── Broadcast filtrado: setar/restaurar a placa VISÍVEL nos clientes próximos ─
--- A placa falsa em si NÃO vai em statebag (segurança); só um MARCADOR booleano vai.
--- A placa visível é cosmética → pode ir no broadcast e no re-sync de scope.
---@param netId integer
---@param text string  texto da placa a exibir
---@param coords vector3|nil
local function broadcastPlateText(netId, text, coords)
    local radius = tonumber(Config.Plates and Config.Plates.VisibleSyncRadius) or 200.0
    for _, pid in ipairs(GetPlayers()) do
        local pidN = tonumber(pid)
        if pidN then
            local send = true
            if coords then
                local pped = GetPlayerPed(pidN)
                send = pped and pped ~= 0 and #(GetEntityCoords(pped) - coords) < radius
            end
            if send then
                TriggerClientEvent('vp_chopshop:client:setVisiblePlate', pidN, netId, text)
            end
        end
    end
end

-- ─── Callback: APLICAR placa falsa ────────────────────────────────────────────
lib.callback.register('vp_chopshop:applyFakePlate', function(src, netId, sourcePlate)
    if not Config.Plates or not Config.Plates.Enable then return { ok = false, err = 'disabled' } end
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    local now = GetGameTimer()
    if ApplyCooldown[src] and now < ApplyCooldown[src] then return { ok = false, err = 'cooldown' } end

    -- Resolver veículo (netId vem do client; revalidamos tudo)
    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return { ok = false, err = 'vehicle' } end

    -- Proximidade server-side
    local maxDist = tonumber(Config.Plates.ApplyMaxDistance) or 4.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then return { ok = false, err = 'range' } end

    -- [F3 garagem] BlockOnOwned REMOVIDO: agora a placa falsa pode ser aplicada em QUALQUER
    -- carro, inclusive owned. O risco de a garagem gravar a placa FALSA em player_vehicles é
    -- eliminado de outra forma: o hook de garagem (qbx_garages parkVehicle) chama o export
    -- vp_chopshop:GetRealPlateForProps ANTES do SaveVehicle, revertendo props.plate para a REAL.
    -- Assim a garagem NUNCA salva a falsa, e no próximo spawn o disfarce é re-aplicado (Frente 2).
    -- Config.Plates.BlockOnOwned permanece na config como `false` (sem efeito) por compatibilidade.

    -- Ler a metadata da `fake_plate` que o jogador possui (placa-alvo do disfarce).
    -- O client manda a placa escolhida; confirmamos posse + formato (trust-no-client).
    local wantPlate = sanitizePlate(sourcePlate)
    local slots = exports.ox_inventory:Search(src, 'slots', 'fake_plate')
    if type(slots) ~= 'table' or #slots == 0 then return { ok = false, err = 'no_item' } end

    local chosenMeta, fakePlate
    for i = 1, #slots do
        local s = slots[i]
        local meta = s and s.metadata
        local pl = meta and sanitizePlate(meta.plate)
        if pl then
            if not wantPlate or wantPlate == pl then
                chosenMeta, fakePlate = meta, pl
                break
            end
        end
    end
    if not fakePlate then return { ok = false, err = 'no_item' } end

    -- Placa REAL ATUAL resolvida no servidor. Se já houver disfarce ativo neste carro,
    -- a "real" verdadeira é a resolvida pelo resolver (não empilhar disfarces).
    local visibleNow = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', '')  -- [AUDIT-FIX M2] guard de nil
    local realPlate = VPChopMDT.GetRealPlate(visibleNow)
    if not realPlate or realPlate == '' then return { ok = false, err = 'no_plate' } end

    -- Aplicar a si mesma é no-op inútil; rejeitar.
    if fakePlate == realPlate then return { ok = false, err = 'same' } end

    -- Colisão: a placa falsa já está em uso por OUTRO carro? (PK em vp_chop_fake_plates)
    if VPChopDbFakePlateInUse(fakePlate) then return { ok = false, err = 'in_use' } end

    -- Persistir o mapeamento (INSERT puro = checagem atômica de colisão por PK).
    local appliedBy = ServerChopPlayerKey(src)
    if not VPChopDbInsertFakePlate(fakePlate, realPlate, appliedBy) then
        return { ok = false, err = 'in_use' }
    end

    -- Consumir a `fake_plate` específica (match por metadata).
    if exports.ox_inventory:RemoveItem(src, 'fake_plate', 1, chosenMeta) ~= true then
        -- Falha rara: reverter o INSERT para não deixar mapeamento órfão.
        VPChopDbDeleteFakePlate(fakePlate)
        return { ok = false, err = 'remove' }
    end

    -- [PERF] Atualizar o cache em memória (real → falsa) para o entityCreated re-aplicar no spawn.
    cacheSetDisguise(realPlate, fakePlate)

    -- Statebag: MARCADOR de que há disfarce ativo + a placa REAL (replicado p/ re-sync robusto).
    -- A placa FALSA NÃO vai no statebag (segurança); a visível é setada via broadcast cosmético.
    local stateOk = pcall(function()
        Entity(veh).state:set('vpFakeRealPlate', realPlate, true)
    end)
    if not stateOk then
        -- Em teoria nunca falha; se falhar, o disfarce ainda funciona via broadcast + DB.
    end

    ApplyCooldown[src] = now + applyCdMs()

    -- Broadcast cosmético: clientes próximos exibem a placa FALSA.
    broadcastPlateText(netId, fakePlate, GetEntityCoords(veh))

    -- MDT: registrar (o crime segue a REAL; a consulta normal vê a falsa naturalmente).
    VPChopMDT.ReportActivity(realPlate, src, 'fake_plate_applied')
    VPChopDiscordLog('[FASE2 placas] Placa falsa aplicada',
        ('Falsa: %s → Real: %s | src: %s'):format(fakePlate, realPlate, tostring(src)))

    -- [EVIDENCE] Aplicar a placa falsa no veículo deixa vestígio no local. `veh` validado acima;
    -- `realPlate` (REAL, resolvida via VPChopMDT.GetRealPlate) já em escopo → heat scaling.
    do
        local evCoords = (veh and veh ~= 0 and DoesEntityExist(veh))
            and GetEntityCoords(veh) or GetEntityCoords(GetPlayerPed(src))
        VPChopLeaveEvidence(src, evCoords, 'plate_apply', realPlate)
        -- [TYRE] Armar a janela de marca de pneu (mesmo ponto do crime; reusa o hook).
        if Config.TyreMarks and Config.TyreMarks.Enable then
            local armMs = (Config.TyreMarks.ArmWindowSeconds or 45) * 1000
            VPChopArmTyreWindow(src, armMs)  -- [AUDIT-FIX H1] arma janela server-side
            TriggerClientEvent('vp_chopshop:armTyreMark', src, armMs)
        end
    end

    return { ok = true, fake = fakePlate }
end)

-- ─── Callback: REMOVER placa falsa (POLÍCIA) ─────────────────────────────────
-- Fura o disfarce: restaura a placa REAL visível, apaga o mapeamento e limpa o statebag.
lib.callback.register('vp_chopshop:removeFakePlate', function(src, netId)
    if not Config.Plates or not Config.Plates.Enable then return { ok = false, err = 'disabled' } end
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    -- Gate de JOB policial (verdade server-side; o target no client é só UX)
    local policeJobs = Config.Plates.PoliceJobs or { 'police', 'bcso', 'sheriff' }
    if not BridgeIsPolice(src, policeJobs) then return { ok = false, err = 'not_police' } end

    local now = GetGameTimer()
    if RemoveCooldown[src] and now < RemoveCooldown[src] then return { ok = false, err = 'cooldown' } end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return { ok = false, err = 'net' } end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return { ok = false, err = 'vehicle' } end

    local maxDist = (tonumber(Config.Plates.ApplyMaxDistance) or 4.0) + 1.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then return { ok = false, err = 'range' } end

    -- Placa VISÍVEL atual = candidata a falsa. Buscar a real mapeada.
    local visible = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', '')  -- [AUDIT-FIX M2] guard de nil
    local realPlate = VPChopDbGetRealByFake(visible)
    if not realPlate then return { ok = false, err = 'no_fake' } end

    RemoveCooldown[src] = now + removeCdMs()

    -- Apagar mapeamento + limpar statebag + restaurar placa REAL visível.
    VPChopDbDeleteFakePlate(visible)
    cacheSetDisguise(realPlate, nil)  -- [PERF] sincroniza o cache em memória
    pcall(function() Entity(veh).state:set('vpFakeRealPlate', nil, true) end)
    broadcastPlateText(netId, realPlate, GetEntityCoords(veh))

    VPChopMDT.ReportActivity(realPlate, src, 'fake_plate_removed')
    VPChopDiscordLog('[FASE2 placas] Placa falsa REMOVIDA pela polícia',
        ('Falsa: %s → Real restaurada: %s | src: %s'):format(visible, realPlate, tostring(src)))

    return { ok = true, real = realPlate }
end)

-- ─── Callback: o veículo tem disfarce ativo? (UX do target policial) ──────────
-- Permite ao client mostrar a opção de remoção SÓ em carros disfarçados. Trust-no-client:
-- a remoção em si revalida tudo. Aqui só ajudamos a UI a não poluir todos os carros.
lib.callback.register('vp_chopshop:isFakePlated', function(src, netId)
    if not IsValidSource(src) then return false end
    netId = tonumber(netId)
    if not netId or netId <= 0 then return false end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local visible = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', '')  -- [AUDIT-FIX M2] guard de nil
    return VPChopDbFakePlateInUse(visible)
end)

-- ─── Callback: texto da placa FALSA a exibir (re-sync de scope) ───────────────
-- Chamado pelo handler de statebag no client quando entra no scope de um carro disfarçado.
-- Lê a placa REAL do statebag (replicado) e devolve a FALSA mapeada para exibição cosmética.
-- A placa falsa não vai no statebag por segurança — por isso o client a pede aqui.
lib.callback.register('vp_chopshop:getVisibleFakePlate', function(src, netId)
    if not IsValidSource(src) then return nil end
    netId = tonumber(netId)
    if not netId or netId <= 0 then return nil end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    local realPlate = nil
    pcall(function() realPlate = Entity(veh).state.vpFakeRealPlate end)
    if not realPlate or realPlate == '' then return nil end
    return VPChopDbGetFakeByReal(realPlate)
end)

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [F2 persist] PERSISTÊNCIA TOTAL + re-aplicação no spawn                    ║
-- ╚══════════════════════════════════════════════════════════════════════════╝

-- ─── [F2 persist] Limpeza ao a entidade sumir (SÓ carros NÃO-owned/transientes) ─
-- ANTES: este handler deletava o mapeamento de QUALQUER carro disfarçado ao despawnar,
-- o que QUEBRAVA a persistência (ao guardar um carro owned, o disfarce sumia para sempre).
--
-- AGORA: o disfarce (mapeamento DB) só é removido pela POLÍCIA (removeFakePlate) ou por
-- remoção manual/admin — NUNCA por despawn de carro owned. Para carros NÃO-owned
-- (transientes, que não voltam após restart), limpamos no despawn para não acumular lixo
-- nem reservar uma falsa para sempre.
--
-- Distinção owned vs transiente: carros owned do qbx têm `Entity(veh).state.vehicleid`
-- (setado no spawn da garagem/qbx_vehicles). Presença de vehicleid → owned → NÃO deletar.
AddEventHandler('entityRemoved', function(entity)
    if not entity or entity == 0 then return end
    if GetEntityType(entity) ~= 2 then return end  -- 2 = veículo (guarda de performance)
    -- Marcador rápido: só nos importa se há disfarce ativo neste carro.
    local okState, marker = pcall(function() return Entity(entity).state.vpFakeRealPlate end)
    if not okState or marker == nil then return end

    -- [F2 persist] Carro owned? Então PRESERVAR o mapeamento (persistência total) —
    -- ele será re-aplicado no próximo spawn (entityCreated abaixo).
    local okOwned, vehicleId = pcall(function() return Entity(entity).state.vehicleid end)
    if okOwned and vehicleId ~= nil then
        return  -- owned → não deletar; o disfarce sobrevive ao guardar / restart
    end

    -- Carro transiente (sem vehicleid): limpar para não acumular lixo.
    -- O marcador `marker` É a placa REAL (statebag vpFakeRealPlate) → limpar o cache por ela.
    -- A placa VISÍVEL no momento do despawn é a falsa registrada → deletar a linha do DB por ela.
    if type(marker) == 'string' and marker ~= '' then
        cacheSetDisguise(marker, nil)  -- [PERF] sincroniza o cache em memória
    end
    local okPlate, visible = pcall(function()
        return (GetVehicleNumberPlateText(entity) or ''):gsub('%s+', '')
    end)
    if okPlate and visible and visible ~= '' then
        CreateThread(function()  -- thread: await fora de contexto seguro do handler
            VPChopDbDeleteFakePlate(visible)
        end)
    end
end)

-- ─── [F2 persist] Re-aplicação do disfarce ao o veículo aparecer ──────────────
-- Quando um veículo spawna, sua placa é a REAL (garantimos isso no hook de garagem da
-- Frente 3: a garagem nunca grava a falsa). Resolvemos a placa real e, se houver disfarce
-- mapeado no DB, re-aplicamos: placa falsa VISÍVEL nos clientes próximos + statebag
-- 'vpFakeRealPlate'. Sobrevive a restart porque o mapeamento vive no DB.
--
-- Guardas de performance: filtramos a veículos (GetEntityType==2) e damos um pequeno Wait
-- para a placa estar pronta. Só batemos no DB se a placa real tiver disfarce — 1 SELECT
-- escalar por spawn de veículo COM disfarce (a esmagadora maioria não tem → 1 SELECT barato).
AddEventHandler('entityCreated', function(entity)
    if not entity or entity == 0 then return end
    if GetEntityType(entity) ~= 2 then return end  -- só veículos
    if not (Config.Plates and Config.Plates.Enable and Config.Plates.Persist ~= false) then return end
    -- [PERF] Se NÃO há nenhum disfarce ativo no servidor inteiro, sair imediatamente —
    -- sem criar thread nem Wait. A esmagadora maioria do tempo o cache está vazio.
    if next(DisguiseByReal) == nil then return end

    CreateThread(function()
        -- Pequena espera: a placa pode não estar pronta no exato tick do entityCreated.
        Wait(250)
        if not DoesEntityExist(entity) then return end

        -- Se já há marcador de disfarce ativo, nada a fazer (evita reprocesso).
        local okMarker, marker = pcall(function() return Entity(entity).state.vpFakeRealPlate end)
        if okMarker and marker ~= nil then return end

        -- Placa atual = REAL (garantido pela garagem). [PERF] Checa o CACHE em memória primeiro
        -- (O(1), sem DB) — a esmagadora maioria dos veículos (trânsito NPC) não tem disfarce e sai
        -- aqui sem tocar no banco. Só carros realmente disfarçados seguem adiante.
        local real = (GetVehicleNumberPlateText(entity) or ''):gsub('%s+', '')
        if real == '' then return end
        local fake = DisguiseByReal[real]
        if not fake or fake == '' or fake == real then return end

        local netId = NetworkGetNetworkIdFromEntity(entity)
        if not netId or netId == 0 then return end

        -- Re-aplicar: statebag (marcador + real replicada) + broadcast cosmético da falsa.
        pcall(function() Entity(entity).state:set('vpFakeRealPlate', real, true) end)
        broadcastPlateText(netId, fake, GetEntityCoords(entity))
    end)
end)

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [F3 garagem] Export para o hook de garagem (qbx_garages / qb-garages)      ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- O patch do garages chama isto ANTES de SaveVehicle. Se o veículo tiver disfarce ativo,
-- devolvemos uma cópia de `props` com `props.plate` revertida para a placa REAL — assim a
-- garagem NUNCA grava a placa falsa em player_vehicles. O mapeamento DB NÃO é apagado:
-- no próximo spawn (entityCreated acima) o disfarce volta. Acoplamento defensivo de 1 linha
-- no garages. Resolução da real: statebag 'vpFakeRealPlate' (rápido) com fallback ao DB.
---@param veh integer  handle do veículo (server-side)
---@param props table  ox_lib vehicle props (contém props.plate = placa visível atual)
---@return table props  mesma table com plate corrigida para a REAL (se houver disfarce)
exports('GetRealPlateForProps', function(veh, props)
    if type(props) ~= 'table' then return props end
    if not (veh and veh ~= 0 and DoesEntityExist(veh)) then return props end

    -- 1) Tentar pelo statebag (replicado, sem custo de DB).
    local real
    local okState, marker = pcall(function() return Entity(veh).state.vpFakeRealPlate end)
    if okState and type(marker) == 'string' and marker ~= '' then
        real = marker
    end

    -- 2) Fallback: a placa visível (que pode ser a falsa) → resolver real pelo DB.
    if not real then
        local visible = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', '')
        if visible ~= '' then
            local mapped = VPChopDbGetRealByFake(visible)
            if mapped and mapped ~= '' then real = mapped end
        end
    end

    if not real or real == '' then return props end  -- sem disfarce → props inalterada

    -- Reverter SÓ a placa nos props (mantém todo o resto). Opcional: refletir na entidade
    -- antes do DeleteVehicle do garages, para qualquer leitura intermediária ver a real.
    props.plate = real
    pcall(function() SetVehicleNumberPlateText(veh, real) end)
    return props
end)
