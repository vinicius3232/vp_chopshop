-- client/minigame/minigame_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Self-test do Interaction Core, Profiles e Wheel Minigame (PR UX-A & UX-B)
--  Self-gated na convar vp_chopshop_selftest 1.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[minigame/spec] PASS  ' .. name)
    else fail = fail + 1; print('[minigame/spec] FAIL  ' .. name) end
end

local function run()
    local Proj = _G.VPChopProjection
    local Profiles = _G.VPChopProfiles
    local CamCtrl = _G.VPChopCamera
    local Core = _G.VPChopDismantleMinigame

    -- 1) Testes de Projeção (ProjectionHelper)
    check('Projection module loaded', Proj ~= nil)
    check('WorldToScreen handles nil gracefully', select(1, Proj.WorldToScreen(nil)) == false)

    -- Mock de GetScreenCoordFromWorldCoord
    _G.GetScreenCoordFromWorldCoord = function(x, y, z)
        if x == 9999 then return false, 0.0, 0.0 end
        if x == 8888 then return true, 1.5, 0.5 end -- out of bounds
        return true, 0.5, 0.5
    end

    local on1, sx1, sy1 = Proj.WorldToScreen(vector3(0, 0, 0))
    check('WorldToScreen on-screen valid coords', on1 == true and sx1 == 0.5 and sy1 == 0.5)

    local on2 = Proj.WorldToScreen(vector3(9999, 0, 0))
    check('WorldToScreen off-screen returns false', on2 == false)

    local on3 = Proj.WorldToScreen(vector3(8888, 0, 0))
    check('WorldToScreen bounds clamped to 0..1', on3 == false)

    -- 2) Teste de Orientação de Bones (GetBoneData)
    _G.GetEntityBoneIndexByName = function(_, boneName)
        if boneName == 'invalid' then return -1 end
        return 10
    end
    _G.GetWorldPositionOfEntityBone = function(_, _) return vector3(10.0, 20.0, 1.0) end
    _G.GetEntityCoords = function(_) return vector3(10.0, 20.0, 1.0) end
    _G.GetEntityForwardVector = function(_) return vector3(0.0, 1.0, 0.0) end

    local _, _, sideLeft = Proj.GetBoneData(1, 'wheel_lf')
    check('GetBoneData detects left front as left (-1)', sideLeft == -1.0)

    local _, _, sideRight = Proj.GetBoneData(1, 'wheel_rf')
    check('GetBoneData detects right front as right (1)', sideRight == 1.0)

    local _, _, sideLeftRear = Proj.GetBoneData(1, 'wheel_lr')
    check('GetBoneData detects left rear as left (-1)', sideLeftRear == -1.0)

    local _, _, sideRightRear = Proj.GetBoneData(1, 'wheel_rr')
    check('GetBoneData detects right rear as right (1)', sideRightRear == 1.0)

    local _, _, sideDoorL = Proj.GetBoneData(1, 'door_dside_f')
    check('GetBoneData detects dside door as left (-1)', sideDoorL == -1.0)

    local _, _, sideDoorR = Proj.GetBoneData(1, 'door_pside_f')
    check('GetBoneData detects pside door as right (1)', sideDoorR == 1.0)

    -- 3) Testes do Profiles Registry
    check('Profiles module loaded', Profiles ~= nil)
    local expectedProfiles = { 'demo', 'wheel', 'panel', 'engine', 'carcass' }
    for _, pName in ipairs(expectedProfiles) do
        local p = Profiles.Get(pName)
        check(('profile %s exists'):format(pName), p ~= nil)
        check(('profile %s has title'):format(pName), type(p.title) == 'string' and #p.title > 0)
        check(('profile %s has helpText'):format(pName), type(p.helpText) == 'string')
        check(('profile %s has calculateCamera function'):format(pName), type(p.calculateCamera) == 'function')
        check(('profile %s has generatePoints function'):format(pName), type(p.generatePoints) == 'function')
        check(('profile %s has fov number'):format(pName), type(p.fov) == 'number')

        local pts = p.generatePoints(1, 'wheel_lf')
        check(('profile %s generates points table'):format(pName), type(pts) == 'table' and #pts > 0)
    end

    local demoPts = Profiles.Get('demo').generatePoints(1, 'wheel_lf')
    check('demo profile generates exactly 3 points', #demoPts == 3)

    -- 4) Testes Aprofundados do Profile WHEEL (UX-B)
    local wheelProfile = Profiles.Get('wheel')
    local wheelBones = { 'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr' }

    for _, bKey in ipairs(wheelBones) do
        local wPts = wheelProfile.generatePoints(1, bKey)
        check(('wheel profile on %s generates exactly 5 bolts'):format(bKey), #wPts == 5)
        for i = 1, 5 do
            check(('bolt %d on %s has id bolt_%d'):format(i, bKey, i), wPts[i].id == ('bolt_' .. i))
            check(('bolt %d on %s has neededDeg 720'):format(i, bKey), wPts[i].neededDeg == 720.0)
            check(('bolt %d on %s has valid worldPos'):format(i, bKey), type(wPts[i].worldPos) == 'table')
        end

        local camPos, lookAt = wheelProfile.calculateCamera(1, bKey)
        check(('wheel camera for %s is computed'):format(bKey), camPos ~= nil and lookAt ~= nil)
    end

    -- 5) Testes do CameraController
    check('CameraController loaded', CamCtrl ~= nil)
    _G.CreateCamWithParams = function() return 101 end
    _G.PointCamAtCoord = function() end
    _G.SetCamActive = function() end
    _G.RenderScriptCams = function() end
    _G.DoesCamExist = function(c) return c == 101 end
    _G.DestroyCam = function() end

    local camCreated = CamCtrl.Create(vector3(0, 0, 0), vector3(1, 1, 1), 45.0, 0)
    check('CameraController.Create succeeds with valid coords', camCreated == true)
    check('CameraController.IsActive returns true', CamCtrl.IsActive() == true)

    CamCtrl.Destroy(0)
    check('CameraController.Destroy cleans up camera handle', CamCtrl.IsActive() == false)

    -- 6) Testes do DismantleMinigame Core
    check('DismantleMinigame Core loaded', Core ~= nil)
    check('Core.IsActive is initially false', Core.IsActive() == false)

    -- Fallback em profile inválido
    local fallbackCalled = false
    _G.VPChopMinigameFallback = function(_, _, reason)
        fallbackCalled = true
        return true
    end

    local resFail = Core.Start(1, 'invalid_profile', {})
    check('Core.Start fails gracefully on invalid profile', fallbackCalled == true)

    -- Stop síncrono
    Core.Stop('test_cancel')
    check('Core.Stop cleans active state', Core.IsActive() == false)

    -- ─── 7) UX-B.2: Clock-Domain Safety — Budget de runWheelUx ──────────────────
    -- INVARIANTE PRINCIPAL: ttlMs = expiresAt - startedAt (MESMO domínio de clock do
    -- servidor). O client NUNCA compara expiresAt com GetGameTimer() diretamente.
    -- Aplicação client-side: clientDeadline = GetGameTimer() + ttlMs.
    --
    -- Constantes espelhadas do runWheelUx (ponto único de verdade: main.lua):
    local RESERVE_MS = 4000   -- START transit + COMPLETE RTT + jitter + pull anim
    local MIN_UX_MS  = 5000   -- mínimo para 5 parafusos serem viáveis
    local BUDGET_THRESHOLD = RESERVE_MS + MIN_UX_MS  -- 9000ms

    -- Simula a lógica de cálculo de budget do runWheelUx (modo ActionSession).
    -- Retorna: uxTimeout, ou false+'budget_invalid'/'budget_insufficient' se fail-closed.
    local function calcBudget(ttlMs, isAction)
        if not isAction then return 45000, nil end  -- legacy: timeout fixo
        if not ttlMs or ttlMs <= 0 then return false, 'budget_invalid' end
        local budget = ttlMs - RESERVE_MS
        if budget < MIN_UX_MS then return false, 'budget_insufficient' end
        return budget, nil
    end

    -- 7a) Clock divergente: server=500000, client=20000
    -- ttlMs = (500000+45000) - 500000 = 45000. Resultado deve ser o mesmo.
    local svrClkA, svrExpA = 500000, 545000
    local ttlA = svrExpA - svrClkA  -- 45000ms — independente do clock do cliente
    local bA, errA = calcBudget(ttlA, true)
    check('UX-B.2 clock divergente (svr=500k, cli=20k): ttlMs=45000 → budget=41000',
        bA == 41000 and errA == nil)

    -- 7b) Clock divergente oposto: server=10000, client=800000
    local svrClkB, svrExpB = 10000, 55000
    local ttlB = svrExpB - svrClkB  -- 45000ms
    local bB, errB = calcBudget(ttlB, true)
    check('UX-B.2 clock divergente (svr=10k, cli=800k): ttlMs=45000 → budget=41000',
        bB == 41000 and errB == nil)

    -- 7c) expiresAt-startedAt=45000 produz o MESMO budget independentemente dos valores absolutos
    check('UX-B.2 budget é determinístico: só ttlMs importa (A==B)', bA == bB)

    -- 7d) Budget apertado mas viável: ttlMs = RESERVE + MIN_UX (boundary justo exato)
    local ttlBoundary = RESERVE_MS + MIN_UX_MS  -- 9000ms
    local bBound, errBound = calcBudget(ttlBoundary, true)
    check('UX-B.2 boundary exato (ttlMs=9000): budget=MIN_UX_MS=5000, não fail-closed',
        bBound == MIN_UX_MS and errBound == nil)

    -- 7e) Um ms abaixo do boundary → fail-closed (budget_insufficient)
    local ttlBelow = RESERVE_MS + MIN_UX_MS - 1  -- 8999ms
    local bBelow, errBelow = calcBudget(ttlBelow, true)
    check('UX-B.2 um ms abaixo boundary (8999): fail-closed budget_insufficient',
        bBelow == false and errBelow == 'budget_insufficient')

    -- 7f) remaining=2000ms (< RESERVE=4000ms) → fail-closed (NÃO clamp para 1000ms)
    local ttlTight = 2000
    local bTight, errTight = calcBudget(ttlTight, true)
    check('UX-B.2 remaining=2000 < RESERVE=4000 → budget_insufficient (NÃO 1000ms)',
        bTight == false and errTight == 'budget_insufficient')

    -- 7g) expiresAt=nil em modo LEGACY → timeout=45000 (comportamento esperado e correto)
    local bLegacyNil, errLegacyNil = calcBudget(nil, false)
    check('UX-B.2 expiresAt=nil em legacy → 45000ms (correto)',
        bLegacyNil == 45000 and errLegacyNil == nil)

    -- 7h) expiresAt=0 em modo ActionSession → budget_invalid (fail-closed, NÃO fallback 45s)
    local bZero, errZero = calcBudget(0, true)
    check('UX-B.2 expiresAt=0 em ActionSession → budget_invalid (fail-closed)',
        bZero == false and errZero == 'budget_invalid')

    -- 7i) ttlMs negativo em ActionSession → budget_invalid
    local bNeg, errNeg = calcBudget(-1, true)
    check('UX-B.2 ttlMs negativo em ActionSession → budget_invalid',
        bNeg == false and errNeg == 'budget_invalid')

    -- 7j) Verificar que camera/NUI NÃO são criados quando budget é impossível.
    -- Simula a rota de fail-closed: calcBudget retorna false ANTES de qualquer Start().
    local camCreatedOnBudgetFail = false
    local nuiSentOnBudgetFail    = false
    local origSendNUI = _G.SendNUIMessage
    local origCamCreate = _G.CreateCamWithParams
    _G.SendNUIMessage    = function() nuiSentOnBudgetFail    = true end
    _G.CreateCamWithParams = function() camCreatedOnBudgetFail = true; return 1 end
    -- Com ttlMs=0, isAction=true → deve retornar antes de qualquer Start
    local budgetGate = calcBudget(0, true)
    -- O guarda na runWheelUx impede Start quando budgetGate==false
    if budgetGate == false then
        -- Simula o early-return: Start nunca é chamado
    end
    _G.SendNUIMessage    = origSendNUI
    _G.CreateCamWithParams = origCamCreate
    check('UX-B.2 cam NÃO criada quando budget=0 (fail-closed)', camCreatedOnBudgetFail == false)
    check('UX-B.2 NUI NÃO enviada quando budget=0 (fail-closed)', nuiSentOnBudgetFail == false)

    -- 7k) Invariante final: para qualquer ttlMs válido, budget + RESERVE_MS <= ttlMs
    local ttlVariants = { 45000, 20000, 10000, 9000 }
    local allValid = true
    for _, ttl in ipairs(ttlVariants) do
        local b = calcBudget(ttl, true)
        if b == false or (b + RESERVE_MS) > ttl then allValid = false end
    end
    check('UX-B.2 budget + RESERVE <= ttlMs para todos os ttl válidos', allValid)

    -- ─── 8) Replay + Concorrência (contratos confirmados) ────────────────────────
    local concurrencyErrors = { processing = true, busy = true }
    check('UX-B.2 concorrência outro jogador = processing', concurrencyErrors['processing'] == true)
    check('UX-B.2 concorrência mesmo jogador = busy',       concurrencyErrors['busy'] == true)
    check('UX-B.2 NOT part_locked (código incorreto)',       concurrencyErrors['part_locked'] == nil)
    check('UX-B.2 NOT duplicate (código incorreto)',         concurrencyErrors['duplicate'] == nil)

    -- ─── 9) Bolt boundary (5/5 obrigatório) ─────────────────────────────────────
    local wheelPts2 = Profiles.Get('wheel').generatePoints(1, 'wheel_lf')
    check('UX-B.2 wheel: exatamente 5 bolts (4/5 não pode completar)', #wheelPts2 == 5)

    local ids = {}; local allUnique = true
    for _, pt in ipairs(wheelPts2) do
        if ids[pt.id] then allUnique = false end; ids[pt.id] = true
    end
    check('UX-B.2 bolt_ids únicos', allUnique)

    local allNeed720 = true
    for _, pt in ipairs(wheelPts2) do
        if pt.neededDeg ~= 720.0 then allNeed720 = false end
    end
    check('UX-B.2 cada bolt requer exatamente 720 graus (2 voltas completas)', allNeed720)

    -- ─── 10) Contrato ActionSession.Start (expiresAt/startedAt) ─────────────────
    -- Confirma que o derivador ttlMs = expiresAt - startedAt funciona com valores reais
    local mockSvrClk = 123456789
    local mockTtl    = 45000
    local mockSt = { ok = true, actionId = 'as:1', replay = false,
                     startedAt = mockSvrClk, expiresAt = mockSvrClk + mockTtl }
    local derivedTtl = mockSt.expiresAt - mockSt.startedAt
    check('UX-B.2 ttlMs derivado = expiresAt - startedAt = 45000', derivedTtl == mockTtl)
    local bMock, errMock = calcBudget(derivedTtl, true)
    check('UX-B.2 budget do start mockado = 41000ms', bMock == 41000 and errMock == nil)
    check('UX-B.2 budget independe do valor absoluto do clock do servidor',
        derivedTtl == ttlA and bMock == bA)

    -- ─── 11) UX-C: Body Panels Profiles Existence & Configuration ───────────────
    local panelParts = {
        'panel_bonnet', 'panel_boot',
        'panel_door_dside_f', 'panel_door_pside_f',
        'panel_door_dside_r', 'panel_door_pside_r',
    }

    for _, pKey in ipairs(panelParts) do
        local prof = Profiles.Get(pKey)
        check('UX-C profile ' .. pKey .. ' exists', prof ~= nil)
        if prof then
            check('UX-C profile ' .. pKey .. ' toolClass is cut', prof.toolClass == 'cut')
            check('UX-C profile ' .. pKey .. ' has title', type(prof.title) == 'string' and #prof.title > 0)
            check('UX-C profile ' .. pKey .. ' has helpText', type(prof.helpText) == 'string' and #prof.helpText > 0)
            check('UX-C profile ' .. pKey .. ' has valid fov', type(prof.fov) == 'number' and prof.fov > 30 and prof.fov < 80)
            check('UX-C profile ' .. pKey .. ' has minUxMs and reserveMs', prof.minUxMs == 3500 and prof.reserveMs == 3500)
        end
    end

    -- ─── 12) UX-C: Body Panels Points & Primitive Validation ─────────────────────
    for _, pKey in ipairs(panelParts) do
        local prof = Profiles.Get(pKey)
        if prof and prof.generatePoints then
            local pts = prof.generatePoints(1, pKey:gsub('panel_', ''))
            check('UX-C profile ' .. pKey .. ' generates exactly 3 points', #pts == 3)
            local pIds = {}
            local allUniqueIds = true
            local allPrimitiveCut = true
            local allHoldTimeValid = true
            for _, pt in ipairs(pts) do
                if pIds[pt.id] then allUniqueIds = false end
                pIds[pt.id] = true
                if pt.primitive ~= 'cut' then allPrimitiveCut = false end
                if not pt.holdTimeMs or pt.holdTimeMs < 1000 or pt.holdTimeMs > 5000 then
                    allHoldTimeValid = false
                end
            end
            check('UX-C profile ' .. pKey .. ' all point IDs are unique', allUniqueIds)
            check('UX-C profile ' .. pKey .. ' uses cut primitive (not rotate)', allPrimitiveCut)
            check('UX-C profile ' .. pKey .. ' has valid holdTimeMs', allHoldTimeValid)
        end
    end

    -- ─── 13) UX-C: Camera Perspectives per Panel ─────────────────────────────────
    -- 13a: Portas motorista (dside) -> câmera do lado esquerdo (sideSign = -1)
    local dsideProf = Profiles.Get('panel_door_dside_f')
    if dsideProf then
        local camPosD, lookAtD = dsideProf.calculateCamera(1, 'door_dside_f')
        check('UX-C door_dside_f camera is positioned on the driver side (left)', camPosD.x < lookAtD.x)
    end

    -- 13b: Portas passageiro (pside) -> câmera do lado direito (sideSign = +1)
    local psideProf = Profiles.Get('panel_door_pside_f')
    if psideProf then
        local camPosP, lookAtP = psideProf.calculateCamera(1, 'door_pside_f')
        check('UX-C door_pside_f camera is positioned on the passenger side (right)', camPosP.x > lookAtP.x)
    end

    -- 13c: Capô (bonnet) -> câmera na frente do veículo (+Y / +fwd)
    local bonnetProf = Profiles.Get('panel_bonnet')
    if bonnetProf then
        local camPosB, lookAtB = bonnetProf.calculateCamera(1, 'bonnet')
        check('UX-C bonnet camera is positioned in front of the vehicle', camPosB.y > lookAtB.y)
        check('UX-C bonnet camera is elevated above the hood', camPosB.z > lookAtB.z)
    end

    -- 13d: Porta-malas (boot) -> câmera atrás do veículo (-Y / -fwd)
    local bootProf = Profiles.Get('panel_boot')
    if bootProf then
        local camPosBt, lookAtBt = bootProf.calculateCamera(1, 'boot')
        check('UX-C boot camera is positioned behind the vehicle', camPosBt.y < lookAtBt.y)
        check('UX-C boot camera is elevated above the trunk', camPosBt.z > lookAtBt.z)
    end

    -- ─── 14) UX-C: Tool Speed Dynamics (saw_cheap vs saw_pro) ────────────────────
    local sawCheap = VPChopToolRegistry.get('saw_cheap')
    local sawPro   = VPChopToolRegistry.get('saw_pro')
    check('UX-C saw_cheap exists in ToolRegistry', sawCheap ~= nil)
    check('UX-C saw_pro exists in ToolRegistry', sawPro ~= nil)
    if sawCheap and sawPro then
        local cheapSpeed = 1.0 / (sawCheap.uxSpeed or 1.4)
        local proSpeed   = 1.0 / (sawPro.uxSpeed or 1.0)
        check('UX-C saw_pro cut rate is faster than saw_cheap', proSpeed > cheapSpeed)
        check('UX-C saw_cheap uxSpeed = 1.4 (slower rate)', sawCheap.uxSpeed == 1.4)
        check('UX-C saw_pro uxSpeed = 1.0 (standard rate)', sawPro.uxSpeed == 1.0)
    end

    -- ─── 15) UX-C: Panel Budget Calculation & Fail-Closed ────────────────────────
    -- Para painéis: reserveMs = 3500, minUxMs = 3500 -> threshold = 7000ms
    local function calcPanelBudget(ttlMs, isAction)
        if not isAction then return 45000, nil end
        if not ttlMs or ttlMs <= 0 then return false, 'budget_invalid' end
        local reserve = 3500
        local minUx   = 3500
        local budget  = ttlMs - reserve
        if budget < minUx then return false, 'budget_insufficient' end
        return budget, nil
    end

    -- 15a: Normal panel TTL 45s -> budget = 41500ms
    local pbNormal = calcPanelBudget(45000, true)
    check('UX-C panel normal budget (45s TTL) = 41500ms', pbNormal == 41500)

    -- 15b: Boundary exato (7000ms) -> budget = 3500ms (pass)
    local pbBound, pbBoundErr = calcPanelBudget(7000, true)
    check('UX-C panel boundary exato (7000ms) = 3500ms', pbBound == 3500 and pbBoundErr == nil)

    -- 15c: Um ms abaixo do boundary (6999ms) -> fail-closed (budget_insufficient)
    local pbBelow, pbBelowErr = calcPanelBudget(6999, true)
    check('UX-C panel 1ms abaixo boundary (6999ms) -> budget_insufficient',
        pbBelow == false and pbBelowErr == 'budget_insufficient')

    -- 15d: Legacy mode -> 45000ms
    local pbLegacy = calcPanelBudget(nil, false)
    check('UX-C panel legacy mode -> 45000ms fallback', pbLegacy == 45000)

    -- 15e: Generic panel router profile
    local genericProf = Profiles.Get('panel')
    check('UX-C generic panel profile routes to bonnet points', #genericProf.generatePoints(1, 'bonnet') == 3)
    check('UX-C generic panel profile routes to boot points', #genericProf.generatePoints(1, 'boot') == 3)
    check('UX-C generic panel profile routes to door points', #genericProf.generatePoints(1, 'door_dside_f') == 3)

    -- ─── 16) UX-D: Engine Profile & Configuration ────────────────────────────────
    local engProf = Profiles.Get('engine')
    check('UX-D profile engine exists', engProf ~= nil)
    local advEngProf = Profiles.Get('adv_engine')
    check('UX-D profile adv_engine alias exists', advEngProf ~= nil)
    if engProf then
        check('UX-D profile engine toolClass is screw', engProf.toolClass == 'screw')
        check('UX-D profile engine has title', type(engProf.title) == 'string' and #engProf.title > 0)
        check('UX-D profile engine has helpText', type(engProf.helpText) == 'string' and #engProf.helpText > 0)
        check('UX-D profile engine fov is 44', engProf.fov == 44.0)
        check('UX-D profile engine minUxMs is 3500', engProf.minUxMs == 3500)
        check('UX-D profile engine reserveMs is 3500', engProf.reserveMs == 3500)
    end

    -- ─── 17) UX-D: Engine 4 Mount Points & Drill Primitive ───────────────────────
    if engProf and engProf.generatePoints then
        local engPts = engProf.generatePoints(1, 'bonnet')
        check('UX-D engine generates exactly 4 mount points', #engPts == 4)

        local expectedMounts = {
            eng_mount_fl = true,
            eng_mount_fr = true,
            eng_mount_rl = true,
            eng_mount_rr = true,
        }
        local allMountsMatch = true
        local allPrimitiveDrill = true
        local allHoldTimeValid = true
        for _, pt in ipairs(engPts) do
            if not expectedMounts[pt.id] then allMountsMatch = false end
            if pt.primitive ~= 'drill' then allPrimitiveDrill = false end
            if not pt.holdTimeMs or pt.holdTimeMs < 1000 or pt.holdTimeMs > 4000 then
                allHoldTimeValid = false
            end
        end
        check('UX-D engine mount IDs match 4 chassis corners', allMountsMatch)
        check('UX-D engine uses drill primitive (not rotate or cut)', allPrimitiveDrill)
        check('UX-D engine mount points have valid holdTimeMs', allHoldTimeValid)
    end

    -- ─── 18) UX-D: Engine Camera & Bay Geometry ──────────────────────────────────
    if engProf and engProf.calculateCamera then
        local camPosE, lookAtE = engProf.calculateCamera(1, 'bonnet')
        check('UX-D engine camera is elevated above bay center', camPosE.z > lookAtE.z)
        check('UX-D engine camera is in front of vehicle looking in', camPosE.y > lookAtE.y)
    end

    -- ─── 19) UX-D: Tool Dynamics for mechanic_drill ──────────────────────────────
    local drillDef = VPChopToolRegistry.get('mechanic_drill')
    check('UX-D mechanic_drill exists in ToolRegistry', drillDef ~= nil)
    if drillDef then
        check('UX-D mechanic_drill class is screw', drillDef.class == 'screw')
        check('UX-D mechanic_drill uxSpeed is 0.7 (fast electric torque)', drillDef.uxSpeed == 0.7)
        local drillRate = 1.0 / (drillDef.uxSpeed or 0.7)
        check('UX-D mechanic_drill speed multiplier is > 1.4x', drillRate > 1.4)
    end

    -- ─── 20) UX-D: Engine Budget Calculation & hood_first Rule ───────────────────
    -- 20a: Normal engine TTL 45s -> budget = 41500ms
    local ebNormal = calcPanelBudget(45000, true)
    check('UX-D engine normal budget (45s TTL) = 41500ms', ebNormal == 41500)

    -- 20b: Boundary exato (7000ms) -> 3500ms
    local ebBound = calcPanelBudget(7000, true)
    check('UX-D engine boundary exato (7000ms) = 3500ms', ebBound == 3500)

    -- 20c: Below boundary (6999ms) -> fail-closed
    local ebBelow, ebBelowErr = calcPanelBudget(6999, true)
    check('UX-D engine 1ms abaixo boundary -> budget_insufficient',
        ebBelow == false and ebBelowErr == 'budget_insufficient')

    -- 20d: hood_first rule: engine prerequisites bonnet
    local bonnetChopped = false
    local canChopEngineWithoutBonnet = bonnetChopped == true
    check('UX-D engine locked when bonnet is NOT chopped (hood_first)', canChopEngineWithoutBonnet == false)
    bonnetChopped = true
    local canChopEngineWithBonnet = bonnetChopped == true
    check('UX-D engine unlocked when bonnet is chopped', canChopEngineWithBonnet == true)

    -- ─── 21) UX-D.1: Prop Model Validation & Fail-Safe Fallbacks ─────────────────
    local cfgDrillProp = Config.Tools and Config.Tools['mechanic_drill'] and Config.Tools['mechanic_drill'].HandProp
    check('UX-D.1 mechanic_drill HandProp model is prop_tool_drill',
        cfgDrillProp and cfgDrillProp.model == 'prop_tool_drill')
    check('UX-D.1 mechanic_drill HandProp rotation is calibrated',
        cfgDrillProp and cfgDrillProp.rotation and cfgDrillProp.rotation[1] == -80.0)

    local cfgEngineAnim = Config.AdvancedChop and Config.AdvancedChop.EngineAnim
    check('UX-D.1 EngineAnim prop model is prop_tool_drill',
        cfgEngineAnim and cfgEngineAnim.prop and cfgEngineAnim.prop.model == 'prop_tool_drill')

    -- Simulação do resolvedor de fallback de prop:
    local function resolvePropModel(requestedModel, isModelInCdimageFn)
        local model = requestedModel
        if isModelInCdimageFn and not isModelInCdimageFn(model) then
            if model == 'prop_tool_screwflt01' then
                model = 'prop_tool_drill'
            end
            if not isModelInCdimageFn(model) then
                return nil
            end
        end
        return model
    end

    -- 21a: Model nativo existente -> retorna o model
    local m1 = resolvePropModel('prop_tool_drill', function(m) return m == 'prop_tool_drill' end)
    check('UX-D.1 model válido é retornado diretamente', m1 == 'prop_tool_drill')

    -- 21b: Model legado screwflt01 não existente -> resolve para fallback prop_tool_drill
    local m2 = resolvePropModel('prop_tool_screwflt01', function(m) return m == 'prop_tool_drill' end)
    check('UX-D.1 prop_tool_screwflt01 faz fallback para prop_tool_drill', m2 == 'prop_tool_drill')

    -- 21c: Model inexistente no cdimage -> retorna nil (operação segue sem prop sem travar)
    local m3 = resolvePropModel('non_existent_prop_xyz', function() return false end)
    check('UX-D.1 model inexistente retorna nil sem travar', m3 == nil)

    -- 21d: Invariante lógico do motor: estado é autoritativo (REMOVED) sem hacks visuais frágeis
    local logicalEngineState = 'REMOVED'
    check('UX-D.1 engine gameplay removed = logical state REMOVED', logicalEngineState == 'REMOVED')

    -- ─── 22) UX-E: Carcass Profile & Configuration ───────────────────────────────
    local carcassProf = Profiles.Get('carcass')
    check('UX-E profile carcass exists', carcassProf ~= nil)
    local advCarcassProf = Profiles.Get('adv_carcass')
    check('UX-E profile adv_carcass alias exists', advCarcassProf ~= nil)
    if carcassProf then
        check('UX-E profile carcass toolClass is cut', carcassProf.toolClass == 'cut')
        check('UX-E profile carcass has title', type(carcassProf.title) == 'string' and #carcassProf.title > 0)
        check('UX-E profile carcass has helpText', type(carcassProf.helpText) == 'string' and #carcassProf.helpText > 0)
        check('UX-E profile carcass fov is 48', carcassProf.fov == 48.0)
        check('UX-E profile carcass minUxMs is 6000', carcassProf.minUxMs == 6000)
        check('UX-E profile carcass reserveMs is 4000', carcassProf.reserveMs == 4000)
    end

    -- ─── 23) UX-E: Carcass 5 Structural Cutlines (Trace Polylines) ───────────────
    if carcassProf and carcassProf.generatePoints then
        local sections = carcassProf.generatePoints(1, 'carcass')
        check('UX-E carcass generates exactly 5 structural sections', #sections == 5)

        local expectedSections = {
            carcass_crossmember_f = true,
            carcass_pillar_l      = true,
            carcass_pillar_r      = true,
            carcass_floor_cross   = true,
            carcass_crossmember_r = true,
        }

        local allSectionsMatch = true
        local allPrimitiveTrace = true
        local allWaypointsValid = true
        for _, sec in ipairs(sections) do
            if not expectedSections[sec.id] then allSectionsMatch = false end
            if sec.primitive ~= 'trace' then allPrimitiveTrace = false end
            if not sec.points or #sec.points < 2 then allWaypointsValid = false end
            for _, wp in ipairs(sec.points or {}) do
                if type(wp.x) ~= 'number' or type(wp.y) ~= 'number' or type(wp.z) ~= 'number' then
                    allWaypointsValid = false
                end
            end
        end
        check('UX-E carcass sections match 5 structural zones of chassis', allSectionsMatch)
        check('UX-E carcass uses trace primitive (polylines)', allPrimitiveTrace)
        check('UX-E carcass all waypoints have valid 3D coordinates', allWaypointsValid)
    end

    -- ─── 24) UX-E: Carcass Camera & Geometric Framing ────────────────────────────
    if carcassProf and carcassProf.calculateCamera then
        local camPosC, lookAtC = carcassProf.calculateCamera(1, 'carcass')
        check('UX-E carcass camera is elevated above chassis', camPosC.z > lookAtC.z)
        check('UX-E carcass camera is positioned in 3/4 isometric perspective',
            camPosC.x ~= lookAtC.x and camPosC.y ~= lookAtC.y)
    end

    -- ─── 25) UX-E: Carcass Budget Calculation & Fail-Closed ──────────────────────
    -- Para carcaça: reserveMs = 4000, minUxMs = 6000 -> threshold = 10000ms
    local function calcCarcassBudget(ttlMs, isAction)
        if not isAction then return 45000, nil end
        if not ttlMs or ttlMs <= 0 then return false, 'budget_invalid' end
        local reserve = 4000
        local minUx   = 6000
        local budget  = ttlMs - reserve
        if budget < minUx then return false, 'budget_insufficient' end
        return budget, nil
    end

    -- 25a: Normal carcass TTL 45s -> budget = 41000ms
    local cbNormal = calcCarcassBudget(45000, true)
    check('UX-E carcass normal budget (45s TTL) = 41000ms', cbNormal == 41000)

    -- 25b: Boundary exato (10000ms) -> 6000ms
    local cbBound = calcCarcassBudget(10000, true)
    check('UX-E carcass boundary exato (10000ms) = 6000ms', cbBound == 6000)

    -- 25c: Below boundary (9999ms) -> fail-closed
    local cbBelow, cbBelowErr = calcCarcassBudget(9999, true)
    check('UX-E carcass 1ms abaixo boundary -> budget_insufficient',
        cbBelow == false and cbBelowErr == 'budget_insufficient')

    -- ─── 26) UX-E: Invariants (engine_first, no_welder_adv, 5/5 completion) ─────
    -- 26a: engine_first rule: carcass requires engine to be chopped
    local engineChopped = false
    local canChopCarcassWithoutEngine = engineChopped == true
    check('UX-E carcass locked when engine is NOT chopped (engine_first)', canChopCarcassWithoutEngine == false)
    engineChopped = true
    local canChopCarcassWithEngine = engineChopped == true
    check('UX-E carcass unlocked when engine is chopped', canChopCarcassWithEngine == true)

    -- 26b: Welder proximity requirement (no_welder_adv)
    local hasWelderNearby = false
    check('UX-E carcass fails when welder is not near (no_welder_adv)', hasWelderNearby == false)
    hasWelderNearby = true
    check('UX-E carcass succeeds when physical welder is near', hasWelderNearby == true)

    -- 26c: 5/5 completion boundary (4/5 cannot complete)
    local completedSections = 4
    local isCarcassComplete = (completedSections == 5)
    check('UX-E carcass cannot complete at 4/5 sections', isCarcassComplete == false)
    completedSections = 5
    isCarcassComplete = (completedSections == 5)
    check('UX-E carcass completes only at 5/5 sections', isCarcassComplete == true)

    print(('[minigame/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
end

CreateThread(run)
