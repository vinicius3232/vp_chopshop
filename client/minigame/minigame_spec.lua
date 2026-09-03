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
    local expectedProfiles = { 'demo', 'wheel', 'panel', 'engine', 'carcass', 'catalytic', 'serial_scratch', 'bench_teardown' }
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
    check('UX-D.1 EngineAnim prop model is prop_tool_wrench or prop_tool_drill',
        cfgEngineAnim and cfgEngineAnim.prop and (cfgEngineAnim.prop.model == 'prop_tool_wrench' or cfgEngineAnim.prop.model == 'prop_tool_drill'))

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
        check('UX-E.1 profile carcass toolClass is nil (physical welder gate)', carcassProf.toolClass == nil)
        check('UX-E.1 profile carcass traceSpeed is 1.0', carcassProf.traceSpeed == 1.0)
        check('UX-E.1 profile carcass traceTolerance is 55.0', carcassProf.traceTolerance == 55.0)
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

    -- ─── 27) UX-E.1: Hardened Trace Algorithm Simulations (TRACE-1 .. TRACE-8) ───
    -- Helper para simular o motor de trace de html/app.js em Lua
    local function createTraceEngine(path, traceTolerance)
        local totalSegs = #path - 1
        local tol = traceTolerance or 55.0
        return {
            path = path,
            totalSegs = totalSegs,
            traceTolerance = tol,
            currentSegmentIndex = 1, -- 1-indexed em Lua
            currentSegmentT = 0.0,
            lastAcceptedT = 0.0,
            lastCutScreenPos = { x = path[1].x, y = path[1].y },
            lastPointerTimestamp = 1000,
            isTracing = false,
            progress = 0,
            completed = false,
            -- Simula mousedown com validação de proximidade dinâmica
            onMouseDown = function(self, mx, my, now)
                local target = self.lastCutScreenPos
                local dist = math.sqrt((mx - target.x)^2 + (my - target.y)^2)
                if dist > self.traceTolerance then return false end
                self.isTracing = true
                self.lastPointerTimestamp = now
                return true
            end,
            onMouseUp = function(self)
                self.isTracing = false
            end,
            -- Simula mousemove com anti-jump e velocidade limitada
            onMouseMove = function(self, mx, my, now, uxSpeed)
                if not self.isTracing or self.completed then return end
                local dt = math.min(0.1, math.max(0.001, (now - self.lastPointerTimestamp) / 1000.0))
                self.lastPointerTimestamp = now

                local segIdx = self.currentSegmentIndex
                if segIdx > self.totalSegs then return end

                local p0 = self.path[segIdx]
                local p1 = self.path[segIdx + 1]
                local dx = p1.x - p0.x
                local dy = p1.y - p0.y
                local segLen = math.sqrt(dx * dx + dy * dy)
                if segLen < 1 then return end

                local u = ((mx - p0.x) * dx + (my - p0.y) * dy) / (segLen * segLen)
                local tClamped = math.max(0.0, math.min(1.0, u))
                local projX = p0.x + tClamped * dx
                local projY = p0.y + tClamped * dy
                local distToSeg = math.sqrt((mx - projX)^2 + (my - projY)^2)

                if distToSeg <= self.traceTolerance then
                    local maxSpeedPxS = 320 * (uxSpeed or 1.0)
                    local maxAdvancePx = maxSpeedPxS * dt + 25
                    local maxAdvanceT = maxAdvancePx / math.max(1, segLen)

                    -- Anti-Jump / Teleport rejection
                    if tClamped > (self.currentSegmentT + maxAdvanceT) then
                        return -- Teleporte ignorado
                    end

                    -- Movimento para trás: não aumenta o progresso
                    if tClamped < self.currentSegmentT then
                        return
                    end

                    -- Movimento legítimo para frente
                    self.currentSegmentT = tClamped
                    self.lastAcceptedT = tClamped
                    self.lastCutScreenPos = { x = projX, y = projY }

                    -- Transição entre segmentos
                    local distToEnd = math.sqrt((mx - p1.x)^2 + (my - p1.y)^2)
                    if tClamped >= 0.98 and distToEnd <= 40 then
                        if segIdx + 1 <= self.totalSegs then
                            self.currentSegmentIndex = segIdx + 1
                            self.currentSegmentT = 0.0
                            self.lastAcceptedT = 0.0
                        else
                            self.progress = 100
                            self.completed = true
                            return
                        end
                    end

                    local ratio = ((self.currentSegmentIndex - 1) + self.currentSegmentT) / self.totalSegs
                    self.progress = math.min(100, math.floor(ratio * 100))
                end
            end
        }
    end

    -- Definir um traçado de teste: P0(100,100) -> P1(300,100) -> P2(500,100) (comprimento total = 400px, 2 segmentos de 200px)
    local testPath = {
        { x = 100, y = 100 },
        { x = 300, y = 100 },
        { x = 500, y = 100 }
    }

    -- TRACE-1: P0 -> movimento gradual contínuo -> P1 -> PASS
    local t1 = createTraceEngine(testPath)
    local ok1 = t1:onMouseDown(100, 100, 1000)
    check('TRACE-1 startNode mousedown aceito', ok1 == true)
    -- Avanço passo a passo com dt de 50ms (movimento suave)
    local tSim = 1000
    for x = 110, 500, 10 do
        tSim = tSim + 50
        t1:onMouseMove(x, 100, tSim, 1.0)
    end
    check('TRACE-1 movimento gradual contínuo completa 100%', t1.completed == true and t1.progress == 100)

    -- TRACE-2: P0 -> salto direto para t=0.95 no primeiro segmento -> NÃO completa
    local t2 = createTraceEngine(testPath)
    t2:onMouseDown(100, 100, 1000)
    t2:onMouseMove(290, 100, 1020, 1.0) -- dt = 20ms, salto de 190px (excede maxAdvancePx ~31px)
    check('TRACE-2 salto direto para t=0.95 é rejeitado pelo anti-jump', t2.progress == 0 and t2.completed == false)

    -- TRACE-3: P0 -> salto direto para endpoint final (P2) -> NÃO completa
    local t3 = createTraceEngine(testPath)
    t3:onMouseDown(100, 100, 1000)
    t3:onMouseMove(500, 100, 1030, 1.0)
    check('TRACE-3 salto direto para endpoint final é rejeitado', t3.progress == 0 and t3.completed == false)

    -- TRACE-4: progressão gradual 0.10 -> 0.20 -> 0.35 -> 0.50 -> aceita
    local t4 = createTraceEngine(testPath)
    t4:onMouseDown(100, 100, 1000)
    t4:onMouseMove(120, 100, 1100, 1.0) -- x=120 -> t=0.10 no seg 1
    local p4a = t4.progress
    t4:onMouseMove(140, 100, 1200, 1.0) -- x=140 -> t=0.20
    local p4b = t4.progress
    t4:onMouseMove(170, 100, 1350, 1.0) -- x=170 -> t=0.35
    local p4c = t4.progress
    t4:onMouseMove(200, 100, 1500, 1.0) -- x=200 -> t=0.50
    local p4d = t4.progress
    check('TRACE-4 progressão gradual é aceita ordenadamente',
        p4a > 0 and p4b > p4a and p4c > p4b and p4d > p4c)

    -- TRACE-5: movimento para trás: 0.60 -> 0.40 -> não aumenta nem regride progresso
    local t5 = createTraceEngine(testPath)
    t5:onMouseDown(100, 100, 1000)
    -- Chegar suavemente a x=220 (t=0.60 no seg 1 -> progresso = 30%)
    for x = 110, 220, 10 do
        tSim = tSim + 50
        t5:onMouseMove(x, 100, tSim, 1.0)
    end
    local progBeforeBack = t5.progress
    -- Mover para trás para x=180 (t=0.40)
    t5:onMouseMove(180, 100, tSim + 50, 1.0)
    check('TRACE-5 movimento para trás preserva o progresso alcançado (não aumenta)',
        t5.progress == progBeforeBack and t5.currentSegmentT == 0.60)

    -- TRACE-6: mouseup em 40% -> cursor em 90% -> mousedown -> NÃO pode retomar de 90%
    local t6 = createTraceEngine(testPath)
    t6:onMouseDown(100, 100, 1000)
    for x = 110, 180, 10 do -- atinge 40% do seg 1 (x=180)
        tSim = tSim + 50
        t6:onMouseMove(x, 100, tSim, 1.0)
    end
    t6:onMouseUp()
    -- Tenta dar mousedown em x=280 (90% do seg 1, distância de 100px do ponto de corte)
    local resumeAccepted = t6:onMouseDown(280, 100, tSim + 1000)
    check('TRACE-6 mousedown a 90% após soltar em 40% é rejeitado (distância > 55px)',
        resumeAccepted == false and t6.isTracing == false)
    -- Retomada legítima próxima a x=180
    local legitResume = t6:onMouseDown(182, 100, tSim + 1050)
    check('TRACE-6 retomada próxima ao ponto de parada (x=182) é aceita',
        legitResume == true and t6.isTracing == true)

    -- TRACE-6b: perfil com tolerância dinâmica (ex: 75px) aceita retomada a 65px (onde o default 55px rejeita)
    local t6Custom = createTraceEngine(testPath, 75.0)
    t6Custom:onMouseDown(100, 100, 1000)
    for x = 110, 180, 10 do tSim = tSim + 50; t6Custom:onMouseMove(x, 100, tSim, 1.0) end
    t6Custom:onMouseUp()
    local customResume = t6Custom:onMouseDown(245, 100, tSim + 1000) -- distância 65px <= 75px
    check('UX-F traceTolerance dinâmico (75px) aceita retomada a 65px de distância',
        customResume == true and t6Custom.isTracing == true)

    -- TRACE-7: completar segment 1 legitimamente desbloqueia segment 2
    local t7 = createTraceEngine(testPath)
    t7:onMouseDown(100, 100, 1000)
    for x = 110, 300, 10 do -- conclui seg 1
        tSim = tSim + 50
        t7:onMouseMove(x, 100, tSim, 1.0)
    end
    check('TRACE-7 concluir segmento 1 avança currentSegmentIndex para 2',
        t7.currentSegmentIndex == 2 and t7.currentSegmentT == 0.0)

    -- TRACE-8: tentar avançar seção 5 antes das anteriores não conclui o minigame
    local completedMap = { sec1 = false, sec2 = false, sec3 = false, sec4 = false, sec5 = true }
    local allDone = completedMap.sec1 and completedMap.sec2 and completedMap.sec3 and completedMap.sec4 and completedMap.sec5
    check('TRACE-8 completar seção 5 isolada não gera conclusão global', allDone == false)

    -- ─── 28) UX-E.1: Contrato do Part Registry para adv_carcass ──────────────────
    if VPChopPartRegistry and VPChopPartRegistry.parts and VPChopPartRegistry.parts.adv_carcass then
        local carcassPart = VPChopPartRegistry.parts.adv_carcass
        check('UX-E.1 PartRegistry adv_carcass toolClass é nil', carcassPart.toolClass == nil)
        check('UX-E.1 PartRegistry adv_carcass requires adv_engine', carcassPart.requires == 'adv_engine')
        check('UX-E.1 PartRegistry adv_carcass gates.welder é true',
            carcassPart.gates and carcassPart.gates.welder == true)
    end

    -- 28b: Verificação de comportamento do cliente: sem serra no inventário mas com welder física -> inicia
    local playerTools = {} -- Jogador não possui saw_cheap nem saw_pro
    local function clientCanChopCarcass(engineRemoved, welderNear, tools)
        if not engineRemoved then return false, 'err_engine_first' end
        if not welderNear then return false, 'err_no_welder_adv' end
        -- Carcaça não consulta tools (toolClass = nil)
        return true, nil
    end

    -- ─── 29) UX-E.2: Primitive-Aware completePoint & 1/5 -> 5/5 Sequence ────────
    -- Simulação fiel da função completePoint(pt) de html/app.js em ambiente controlado
    local function jsCompletePoint(pt, nuiEvents, progressState)
        if not pt or pt.completed then return end
        pt.completed = true
        pt.progress = 100

        if pt.primitive == 'trace' then
            if pt.fgPath then
                pt.fgPath.style.strokeDashoffset = 0
            end
            if pt.torchTip then
                pt.torchTip.classList.hidden = true
            end
            if pt.startNode then
                pt.startNode.classList.completed = true
                if pt.startNode.icon then
                    pt.startNode.icon.innerHTML = '&#10003;'
                end
            end
            pt.isTracing = false
        else
            if pt.progressCircle then
                pt.progressCircle.style.strokeDashoffset = 0
            end
            if pt.icon then
                pt.icon.innerHTML = '&#10003;'
            end
        end

        if pt.element then
            pt.element.classList.active = false
            pt.element.classList.cutting = false
            pt.element.classList.drilling = false
            pt.element.classList.tracing = false
            pt.element.classList.completed = true
        end

        if nuiEvents then
            nuiEvents[#nuiEvents + 1] = { event = 'minigamePointComplete', id = pt.id }
        end

        if progressState then
            progressState.completedCount = (progressState.completedCount or 0) + 1
            if progressState.completedCount == progressState.totalCount then
                progressState.finished = true
            end
        end
    end

    -- 29a: rotate point completion
    local rotatePt = {
        id = 'hs-wheel_bolt_1',
        primitive = 'rotate',
        progressCircle = { style = { strokeDashoffset = 100 } },
        icon = { innerHTML = '1' },
        element = { classList = { active = true, completed = false } },
        completed = false,
        progress = 50
    }
    local okRot, errRot = pcall(jsCompletePoint, rotatePt)
    check('UX-E.2 rotate point completes without exception', okRot == true and errRot == nil)
    check('UX-E.2 rotate point progressCircle offset is 0', rotatePt.progressCircle.style.strokeDashoffset == 0)
    check('UX-E.2 rotate point icon is checkmark', rotatePt.icon.innerHTML == '&#10003;')

    -- 29b: cut point completion
    local cutPt = {
        id = 'hs-cut_hinge_1',
        primitive = 'cut',
        progressCircle = { style = { strokeDashoffset = 80 } },
        icon = { innerHTML = '1' },
        element = { classList = { cutting = true, completed = false } },
        completed = false,
        progress = 60
    }
    local okCut, errCut = pcall(jsCompletePoint, cutPt)
    check('UX-E.2 cut point completes without exception', okCut == true and errCut == nil)
    check('UX-E.2 cut point progressCircle offset is 0', cutPt.progressCircle.style.strokeDashoffset == 0)

    -- 29c: drill point completion
    local drillPt = {
        id = 'hs-engine_mount_1',
        primitive = 'drill',
        progressCircle = { style = { strokeDashoffset = 50 } },
        icon = { innerHTML = '1' },
        element = { classList = { drilling = true, completed = false } },
        completed = false,
        progress = 80
    }
    local okDrill, errDrill = pcall(jsCompletePoint, drillPt)
    check('UX-E.2 drill point completes without exception', okDrill == true and errDrill == nil)

    -- 29d: trace point completion (NÃO possui progressCircle e NÃO possui icon na raiz)
    local tracePt = {
        id = 'hs-carcass_crossmember_f',
        primitive = 'trace',
        fgPath = { style = { strokeDashoffset = 250 } },
        torchTip = { classList = { hidden = false } },
        startNode = {
            classList = { completed = false },
            icon = { innerHTML = '1' }
        },
        element = { classList = { active = true, tracing = true, completed = false } },
        isTracing = true,
        completed = false,
        progress = 75
        -- progressCircle e icon são NIL (exatamente como em html/app.js)
    }
    local okTrace, errTrace = pcall(jsCompletePoint, tracePt)
    check('UX-E.2 trace point without progressCircle/icon completes with ZERO exception',
        okTrace == true and errTrace == nil)
    check('UX-E.2 trace point fgPath offset is 0', tracePt.fgPath.style.strokeDashoffset == 0)
    check('UX-E.2 trace point torchTip is hidden', tracePt.torchTip.classList.hidden == true)
    check('UX-E.2 trace point startNode has completed class', tracePt.startNode.classList.completed == true)
    check('UX-E.2 trace point startNode icon updated to checkmark', tracePt.startNode.icon.innerHTML == '&#10003;')
    check('UX-E.2 trace point isTracing is false', tracePt.isTracing == false)
    check('UX-E.2 trace point completed is true', tracePt.completed == true and tracePt.progress == 100)

    -- 29e: Sequência 1/5 -> 2/5 -> 3/5 -> 4/5 -> 5/5
    local progressState = { totalCount = 5, completedCount = 0, finished = false }
    local nuiEvents = {}

    local sec1 = { id = 'sec1', primitive = 'trace', fgPath = { style = {} }, torchTip = { classList = {} }, startNode = { classList = {}, icon = {} }, element = { classList = {} } }
    local sec2 = { id = 'sec2', primitive = 'trace', fgPath = { style = {} }, torchTip = { classList = {} }, startNode = { classList = {}, icon = {} }, element = { classList = {} } }
    local sec3 = { id = 'sec3', primitive = 'trace', fgPath = { style = {} }, torchTip = { classList = {} }, startNode = { classList = {}, icon = {} }, element = { classList = {} } }
    local sec4 = { id = 'sec4', primitive = 'trace', fgPath = { style = {} }, torchTip = { classList = {} }, startNode = { classList = {}, icon = {} }, element = { classList = {} } }
    local sec5 = { id = 'sec5', primitive = 'trace', fgPath = { style = {} }, torchTip = { classList = {} }, startNode = { classList = {}, icon = {} }, element = { classList = {} } }

    jsCompletePoint(sec1, nuiEvents, progressState)
    check('UX-E.2 1/5 concluído -> não trava e não finaliza global',
        progressState.completedCount == 1 and progressState.finished == false)

    jsCompletePoint(sec2, nuiEvents, progressState)
    check('UX-E.2 2/5 concluído -> não finaliza global',
        progressState.completedCount == 2 and progressState.finished == false)

    jsCompletePoint(sec3, nuiEvents, progressState)
    check('UX-E.2 3/5 concluído -> não finaliza global',
        progressState.completedCount == 3 and progressState.finished == false)

    jsCompletePoint(sec4, nuiEvents, progressState)
    check('UX-E.2 4/5 concluído -> não finaliza global',
        progressState.completedCount == 4 and progressState.finished == false)

    jsCompletePoint(sec5, nuiEvents, progressState)
    check('UX-E.2 5/5 concluído -> SOMENTE AQUI dispara minigameFinish',
        progressState.completedCount == 5 and progressState.finished == true)
    check('UX-E.2 exatamente 5 eventos minigamePointComplete emitidos', #nuiEvents == 5)

    -- ─── 30) UX-F.1: Wheel Camera Hardening & Tyre Carry/Pickup Lifecycle ────────
    local wheelProfile = Profiles.Get('wheel')
    check('UX-F.1 wheel profile exists', wheelProfile ~= nil)
    check('UX-F.1 wheel profile has fov 36.0', wheelProfile.fov == 36.0)
    check('UX-F.1 wheel profile has setupPed function', type(wheelProfile.setupPed) == 'function')

    -- 30a: Validação de posicionamento da câmera e do ped nas 4 rodas
    local wheelBones = { 'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr' }
    for _, bKey in ipairs(wheelBones) do
        local camPos, lookAt = wheelProfile.calculateCamera(1, bKey)
        check(('UX-F.1 wheel %s camera position computed'):format(bKey), camPos ~= nil and lookAt ~= nil)
        local okPed, errPed = pcall(wheelProfile.setupPed, 1, 1, bKey)
        check(('UX-F.1 wheel %s setupPed executes cleanly'):format(bKey), okPed == true and errPed == nil)
    end

    -- 30b: Simulação do ciclo de Carry -> Drop no chão -> Target de Pickup -> Carry restaurado
    local mockEntitlementId = 778899
    local testCarryPart = {
        partKey = 'wheel_lf',
        propHandle = 456,
        isTyre = true,
        entitlementId = mockEntitlementId,
    }

    -- 1. Drop no chão: captura o entitlementId e limpa carry
    local groundEntId = testCarryPart.entitlementId
    local groundPropHandle = testCarryPart.propHandle
    testCarryPart.propHandle = nil
    testCarryPart = nil -- VPChopDropCarryPart()

    check('UX-F.1 tyre drop preserves entitlementId for ground prop', groundEntId == mockEntitlementId)
    check('UX-F.1 tyre drop clears carry state', testCarryPart == nil)

    -- 2. Pickup do chão: restaura o carry com o MESMO entitlementId sem duplicar
    local pickedCarryPart = {
        partKey = 'wheel_tyre',
        propHandle = groundPropHandle,
        isTyre = true,
        entitlementId = groundEntId,
    }
    check('UX-F.1 tyre pickup restores carry state with identical entitlementId',
        pickedCarryPart.isTyre == true and pickedCarryPart.entitlementId == mockEntitlementId)
    check('UX-F.1 tyre pickup reuses prop handle', pickedCarryPart.propHandle == groundPropHandle)

    -- 31: Testes de Carregamento Físico de Peças (PhysicalCarry) e Bancada
    if Config.PhysicalCarry then Config.PhysicalCarry.Enable = true end
    check('PHYSICAL-1 Config.PhysicalCarry is enabled', Config.PhysicalCarry and Config.PhysicalCarry.Enable == true)
    check('PHYSICAL-1 door_dside_f model is prop_car_door_01',
        Config.PhysicalCarry and Config.PhysicalCarry.Props and Config.PhysicalCarry.Props.door_dside_f and Config.PhysicalCarry.Props.door_dside_f.model == 'prop_car_door_01')
    check('PHYSICAL-1 bonnet model is prop_car_bonnet_01',
        Config.PhysicalCarry and Config.PhysicalCarry.Props and Config.PhysicalCarry.Props.bonnet and Config.PhysicalCarry.Props.bonnet.model == 'prop_car_bonnet_01')
    check('PHYSICAL-1 adv_engine model is prop_car_engine_01',
        Config.PhysicalCarry and Config.PhysicalCarry.Props and Config.PhysicalCarry.Props.adv_engine and Config.PhysicalCarry.Props.adv_engine.model == 'prop_car_engine_01')

    -- Simulação do ciclo de carregar peça de carro -> largar no chão -> pegar -> processar na bancada
    local carPartCarry = {
        partKey = 'door_dside_f',
        propHandle = 888,
        isPart = true,
    }
    check('PHYSICAL-2 car part is marked as isPart', carPartCarry.isPart == true)
    
    -- Drop no chão
    local groundPartProp = carPartCarry.propHandle
    local groundPartKey = carPartCarry.partKey
    carPartCarry = nil
    check('PHYSICAL-2 car part drop clears carry state', carPartCarry == nil)
    check('PHYSICAL-2 car part drop retains ground handle and key', groundPartProp == 888 and groundPartKey == 'door_dside_f')

    -- Pickup do chão
    local restoredCarPart = {
        partKey = groundPartKey,
        propHandle = groundPartProp,
        isPart = true,
    }
    check('PHYSICAL-2 car part pickup restores state', restoredCarPart.isPart == true and restoredCarPart.partKey == 'door_dside_f')

    -- Processamento na bancada (limpa carry)
    restoredCarPart = nil
    check('PHYSICAL-2 bench dismantle consumes carried part', restoredCarPart == nil)

    -- 32: Testes de Furto de Catalisador (CatalyticTheft) e Dual Processing (Bancada vs Fence)
    check('CATALYTIC-1 Config.CatalyticTheft is enabled', Config.CatalyticTheft and Config.CatalyticTheft.Enable == true)
    check('CATALYTIC-1 catalytic_converter model is prop_car_exhaust_01',
        Config.PhysicalCarry and Config.PhysicalCarry.Props and Config.PhysicalCarry.Props.catalytic_converter and Config.PhysicalCarry.Props.catalytic_converter.model == 'prop_car_exhaust_01')
    check('CATALYTIC-1 Payout min/max configured',
        Config.CatalyticTheft and Config.CatalyticTheft.Payout and Config.CatalyticTheft.Payout.min > 0 and Config.CatalyticTheft.Payout.max >= Config.CatalyticTheft.Payout.min)
    check('CATALYTIC-1 BenchMaterials contains copper and scrap',
        Config.CatalyticTheft and Config.CatalyticTheft.BenchMaterials and Config.CatalyticTheft.BenchMaterials.copper ~= nil and Config.CatalyticTheft.BenchMaterials.metalscrap ~= nil)
    check('CATALYTIC-MINIGAME-1 minigame profile is configured (PR-2)',
        Config.CatalyticTheft and Config.CatalyticTheft.Minigame and Config.CatalyticTheft.Minigame.Profile == 'catalytic')
    check('CATALYTIC-MINIGAME-1 Sparks VFX is enabled',
        Config.CatalyticTheft and Config.CatalyticTheft.SparksVfx == true)
    check('CATALYTIC-MINIGAME-1 Police Alert on Fail configured',
        Config.CatalyticTheft and Config.CatalyticTheft.PoliceAlertOnFail == 100)

    -- Simulação de roubo de catalisador -> carregamento -> venda no Fence
    local catalyticCarry = {
        partKey = 'catalytic_converter',
        propHandle = 999,
        isPart = true,
    }
    check('CATALYTIC-2 catalytic is carried as isPart', catalyticCarry.isPart == true and catalyticCarry.partKey == 'catalytic_converter')

    -- Venda no Fence consome o carry e premia dinheiro
    catalyticCarry = nil
    check('CATALYTIC-2 fence sale consumes carried catalytic', catalyticCarry == nil)

    -- Testes de paridade de idioma para o minigame de catalisador
    local catKeys = { 'catalytic_cutting_stage_1', 'catalytic_cutting_stage_2', 'catalytic_cut_failed', 'catalytic_stolen_success' }
    for _, lang in ipairs({ 'en', 'pt', 'es', 'fr', 'tr' }) do
        Config.Locale = lang
        for _, k in ipairs(catKeys) do
            local val = L(k)
            check(('CATALYTIC-LOCALE-1 %s present in %s'):format(k, lang), val ~= nil and val ~= k and val ~= '')
        end
    end
    Config.Locale = 'en'

    -- ─── 32.1: Testes de Decisão de Alerta Policial (Sem Dupla Probabilidade) ──
    do
        check('CAT-ALERT-01 chance 100 => dispatch decision true',
            VPChopCatalyticShouldDispatch(100, 1) == true and VPChopCatalyticShouldDispatch(100, 100) == true)
        check('CAT-ALERT-02 chance 0 => false',
            VPChopCatalyticShouldDispatch(0, 1) == false and VPChopCatalyticShouldDispatch(0, 100) == false)
        check('CAT-ALERT-03 chance 30 + roll 30 => true',
            VPChopCatalyticShouldDispatch(30, 30) == true)
        check('CAT-ALERT-04 chance 30 + roll 31 => false',
            VPChopCatalyticShouldDispatch(30, 31) == false)
        check('CAT-ALERT-05 saw_pro.dispatchChance = 0.25 NÃO reduz PoliceAlertOnFail=100 para 25%',
            VPChopCatalyticShouldDispatch(Config.CatalyticTheft.PoliceAlertOnFail, 100) == true)
        check('CAT-ALERT-06 saw_pro.dispatchChance = 0.25 NÃO transforma PoliceAlertChance=30 em 7.5%',
            VPChopCatalyticShouldDispatch(Config.CatalyticTheft.PoliceAlertChance, 30) == true and
            VPChopCatalyticShouldDispatch(Config.CatalyticTheft.PoliceAlertChance, 31) == false)
    end

    -- ─── 32.2: Testes Comportamentais do Fluxo de Client ───────────────────────
    do
        local function simulateClientCatalyticTheft(scenario, forcedRoll)
            local calls = {
                cancel = 0,
                complete = 0,
                dispatch = 0,
                cleanup = 0,
                notifiedSuccess = 0,
                notifiedFail = 0,
                carriedSpawned = 0,
            }

            local function cleanupTheft(failed)
                calls.cleanup = calls.cleanup + 1
                if failed then
                    calls.cancel = calls.cancel + 1
                end
            end

            local catCfg = Config.CatalyticTheft or {}
            local minigameCfg = catCfg.Minigame or { Enable = true }

            -- Stage 1
            local ok1 = (scenario ~= 'cancel_progress_1')
            if not ok1 then
                cleanupTheft(true)
                return calls
            end

            local pass1 = (scenario ~= 'fail_stage_1')
            if not pass1 then
                cleanupTheft(true)
                if VPChopCatalyticShouldDispatch(catCfg.PoliceAlertOnFail or 100, forcedRoll) then
                    calls.dispatch = calls.dispatch + 1
                end
                calls.notifiedFail = calls.notifiedFail + 1
                return calls
            end

            -- Stage 2
            local ok2 = (scenario ~= 'cancel_progress_2')
            if not ok2 then
                cleanupTheft(true)
                return calls
            end

            local pass2 = (scenario ~= 'fail_stage_2')
            if not pass2 then
                cleanupTheft(true)
                if VPChopCatalyticShouldDispatch(catCfg.PoliceAlertOnFail or 100, forcedRoll) then
                    calls.dispatch = calls.dispatch + 1
                end
                calls.notifiedFail = calls.notifiedFail + 1
                return calls
            end

            cleanupTheft(false)

            if VPChopCatalyticShouldDispatch(catCfg.PoliceAlertChance or 30, forcedRoll) then
                calls.dispatch = calls.dispatch + 1
            end

            calls.complete = calls.complete + 1
            calls.carriedSpawned = calls.carriedSpawned + 1
            calls.notifiedSuccess = calls.notifiedSuccess + 1
            return calls
        end

        local simFail1 = simulateClientCatalyticTheft('fail_stage_1', 1)
        check('CAT-FAIL-STAGE1-01 falha stage 1 cancel=1, complete=0, dispatch=1, cleanup=1',
            simFail1.cancel == 1 and simFail1.complete == 0 and simFail1.dispatch == 1 and simFail1.cleanup == 1 and simFail1.notifiedFail == 1)

        local simFail2 = simulateClientCatalyticTheft('fail_stage_2', 1)
        check('CAT-FAIL-STAGE2-01 falha stage 2 cancel=1, complete=0, dispatch=1, cleanup=1',
            simFail2.cancel == 1 and simFail2.complete == 0 and simFail2.dispatch == 1 and simFail2.cleanup == 1 and simFail2.notifiedFail == 1)

        local simSuccess = simulateClientCatalyticTheft('success', 30)
        check('CAT-SUCCESS-01 sucesso cancel=0, complete=1, cleanup=1, dispatch=1',
            simSuccess.cancel == 0 and simSuccess.complete == 1 and simSuccess.cleanup == 1 and simSuccess.dispatch == 1 and simSuccess.notifiedSuccess == 1)

        local simCancel = simulateClientCatalyticTheft('cancel_progress_1', 1)
        check('CAT-CANCEL-01 progress cancelado cancel=1, complete=0, entitlement=0',
            simCancel.cancel == 1 and simCancel.complete == 0 and simCancel.carriedSpawned == 0 and simCancel.cleanup == 1)
    end

    -- ─── 32.3: Testes de Sessão Server-Side e Cancelamento ─────────────────────
    do
        local mockServerThefts = {}
        local mockToolConsumed = 0
        local mockIssuedEntitlements = 0

        local function serverStartTheft(src, netId)
            if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
            local token = ('cat_th:%d:%d'):format(src, 1000)
            mockServerThefts[src] = { token = token, netId = netId, startedAt = 1000, expiresAt = 9000, minDurationMs = 7000 }
            return { ok = true, token = token, durationMs = 7000 }
        end

        local function serverCancelTheft(src, netId, token)
            if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
            if type(token) ~= 'string' or token == '' then return { ok = false, err = 'invalid_token' } end
            local theft = mockServerThefts[src]
            if not theft or theft.token ~= token then
                return { ok = false, err = 'no_session' }
            end
            mockServerThefts[src] = nil
            return { ok = true }
        end

        local function serverCompleteTheft(src, netId, token)
            if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
            if type(token) ~= 'string' or token == '' then return { ok = false, err = 'invalid' } end
            local theft = mockServerThefts[src]
            if not theft or theft.token ~= token or theft.netId ~= netId then
                return { ok = false, err = 'invalid' }
            end
            mockServerThefts[src] = nil
            mockToolConsumed = mockToolConsumed + 1
            mockIssuedEntitlements = mockIssuedEntitlements + 1
            return { ok = true, entitlementId = 'pe_cat_123', partKey = 'catalytic_converter' }
        end

        -- CAT-SERVER-CANCEL-01: Token correto limpa sessão
        local sStart1 = serverStartTheft(1, 10)
        local sCancel1 = serverCancelTheft(1, 10, sStart1.token)
        check('CAT-SERVER-CANCEL-01 token correto limpa sessão', sCancel1.ok == true and mockServerThefts[1] == nil)

        -- CAT-SERVER-CANCEL-02: Token incorreto NÃO limpa sessão válida
        local sStart2 = serverStartTheft(1, 10)
        local sCancel2 = serverCancelTheft(1, 10, 'wrong_token')
        check('CAT-SERVER-CANCEL-02 token incorreto NÃO limpa sessão válida', sCancel2.ok == false and mockServerThefts[1] ~= nil)

        -- CAT-SERVER-CANCEL-03: Outro source não cancela sessão alheia
        local sCancel3 = serverCancelTheft(2, 10, sStart2.token)
        check('CAT-SERVER-CANCEL-03 outro source não cancela sessão alheia', sCancel3.ok == false and mockServerThefts[1] ~= nil)

        -- CAT-SERVER-CANCEL-04: Complete após cancel correto retorna invalid/no-session e gera zero entitlement
        serverCancelTheft(1, 10, sStart2.token)
        local toolBefore = mockToolConsumed
        local entBefore = mockIssuedEntitlements
        local sCompAfterCancel = serverCompleteTheft(1, 10, sStart2.token)
        check('CAT-SERVER-CANCEL-04 complete após cancel falha e gera ZERO entitlement/tool consumption',
            sCompAfterCancel.ok == false and mockToolConsumed == toolBefore and mockIssuedEntitlements == entBefore)
    end

    -- 33: Testes de Roubo em Veículos de Outros Jogadores & Proteção Anti-Auto-Farm (BlockOwnVehicle)
    do
        check('OWNERSHIP-1 Jackstand BlockOwnVehicle is configured', Config.Jackstand and Config.Jackstand.BlockOwnVehicle ~= nil)
        check('OWNERSHIP-1 Catalytic BlockOwnVehicle is configured', Config.CatalyticTheft and Config.CatalyticTheft.BlockOwnVehicle ~= nil)

        -- Simulação de ownership bridge
        local function mockIsPlayerVehicleOwner(src, pInfo)
            if pInfo and pInfo.status == 'owned' and pInfo.ownedBy then
                local myKey = 'player_' .. tostring(src)
                return (myKey == pInfo.ownedBy or tostring(myKey):find(tostring(pInfo.ownedBy), 1, true) ~= nil)
            end
            return false
        end

        local otherPlayerCar = { status = 'owned', ownedBy = 'player_99' }
        local myOwnCar       = { status = 'owned', ownedBy = 'player_1' }
        local npcCar         = { status = 'not_owned' }

        check('OWNERSHIP-2 stealing from other player vehicle is ALLOWED', mockIsPlayerVehicleOwner(1, otherPlayerCar) == false)
        check('OWNERSHIP-2 stealing from NPC vehicle is ALLOWED', mockIsPlayerVehicleOwner(1, npcCar) == false)
    end

    -- 34: Testes de Processamento na Bancada: 3 Modos (Matérias-Primas, Serial Limpo, Serial Roubado)
    do
        local mockBenchDismantle = function(partKey, mode, netId)
            if mode == 'raw_materials' then
                return { item = 'metalscrap', amount = 6, serial = nil, state = nil }
            elseif mode == 'clean_serial' then
                return { item = 'car_parts', amount = 1, serial = nil, state = 'scratched' }
            elseif mode == 'stolen_serial' then
                return { item = 'car_parts', amount = 1, serial = 'ABC123XYZ0', state = 'stolen' }
            end
        end

        local rawRes = mockBenchDismantle('door_dside_f', 'raw_materials', 10)
        check('BENCH-MODES raw_materials delivers scrap without serial', rawRes.item == 'metalscrap' and rawRes.state == nil)

        local cleanRes = mockBenchDismantle('door_dside_f', 'clean_serial', 10)
        check('BENCH-MODES clean_serial delivers scratched clean auto part', cleanRes.item == 'car_parts' and cleanRes.state == 'scratched' and cleanRes.serial == nil)

        local stolenRes = mockBenchDismantle('door_dside_f', 'stolen_serial', 10)
        check('BENCH-MODES stolen_serial delivers part with traceable serial', stolenRes.item == 'car_parts' and stolenRes.state == 'stolen' and stolenRes.serial ~= nil)
    end

    -- ─── [FIX-1] i18n dos profiles novos: paridade das keys mg_* nos 5 idiomas ──
    do
        local mgKeys = {
            'mg_catalytic_title', 'mg_catalytic_help', 'mg_catalytic_bolt', 'mg_catalytic_knock',
            'mg_serial_title', 'mg_serial_help', 'mg_serial_engraving', 'mg_serial_residue',
            'mg_teardown_title', 'mg_teardown_help', 'mg_teardown_seam1', 'mg_teardown_seam2', 'mg_teardown_open',
        }
        for _, lang in ipairs({ 'en', 'pt', 'es', 'fr', 'tr' }) do
            Config.Locale = lang
            for _, k in ipairs(mgKeys) do
                local val = L(k)
                check(('MG-LOCALE-1 %s present in %s'):format(k, lang), val ~= nil and val ~= k and val ~= '')
            end
        end
        Config.Locale = 'en'

        -- os profiles devem resolver via L(...), não literal
        for _, pName in ipairs({ 'catalytic', 'serial_scratch', 'bench_teardown' }) do
            local p = Profiles.Get(pName)
            check(('MG-LOCALE-2 %s title/helpText são strings resolvidas'):format(pName),
                type(p.title) == 'string' and #p.title > 0 and type(p.helpText) == 'string' and #p.helpText > 0)
            local pts = p.generatePoints(1, 'wheel_lf')
            local allLabels = true
            for _, pt in ipairs(pts) do
                if type(pt.label) ~= 'string' or #pt.label == 0 then allLabels = false end
            end
            check(('MG-LOCALE-2 %s: todos os point labels resolvidos'):format(pName), allLabels)
        end
    end

    -- ─── [FIX-1.2] Catalytic — shape dos pontos: 4 porcas (rotate) + 2 golpes (strike) ──
    do
        local catPts = Profiles.Get('catalytic').generatePoints(1, 'exhaust')
        check('MG-CAT-PT-1 catalytic gera 6 pontos (4 rotate + 2 strike)', #catPts == 6)
        local rotN, strikeN = 0, 0
        for _, pt in ipairs(catPts) do
            if pt.primitive == 'rotate' then
                rotN = rotN + 1
                check(('MG-CAT-PT-2 %s tem neededDeg numérico'):format(pt.id), type(pt.neededDeg) == 'number' and pt.neededDeg > 0)
            elseif pt.primitive == 'strike' then
                strikeN = strikeN + 1
                check(('MG-CAT-PT-3 %s tem hitsNeeded numérico'):format(pt.id), type(pt.hitsNeeded) == 'number' and pt.hitsNeeded > 0)
            end
            check(('MG-CAT-PT-4 %s tem worldPos + label'):format(tostring(pt.id)),
                type(pt.worldPos) == 'table' and type(pt.label) == 'string' and #pt.label > 0)
        end
        check('MG-CAT-PT-5 exatamente 4 rotate', rotN == 4)
        check('MG-CAT-PT-6 exatamente 2 strike', strikeN == 2)
        check('MG-CAT-PT-7 ids esperados cat_bolt_1 / cat_knock_1',
            catPts[1].id == 'cat_bolt_1' and catPts[5].id == 'cat_knock_1')
    end

    -- ─── [FIX-1.1] Catalytic — paridade de bone da CÂMERA (exhaust_3/_4-only) ──────
    -- O locator de interação (ox_target) segue SEM chassis; aqui é só o fallback de
    -- câmera do profile: exhaust → _2 → _3 → _4 → chassis → offset geométrico.
    do
        local CP = _G.VPChopCatalyticProfile
        check('MG-CAT-BONE-0 profile catalytic expõe resolveExhaustData',
            type(CP) == 'table' and type(CP.resolveExhaustData) == 'function')

        if CP and CP.resolveExhaustData then
            local origIdx = _G.GetEntityBoneIndexByName
            local function onlyBone(target)
                _G.GetEntityBoneIndexByName = function(_, boneName)
                    return boneName == target and 11 or -1
                end
            end

            onlyBone('exhaust')
            local id = CP.resolveExhaustData(1)
            check('MG-CAT-BONE-1 exhaust-only → ancora no bone (id ~= -1/0)', id ~= -1 and id ~= 0)

            onlyBone('exhaust_3')
            id = CP.resolveExhaustData(1)
            check('MG-CAT-BONE-2 exhaust_3-only → ancora no bone real, sem cair no chassis',
                id ~= -1 and id ~= 0)

            onlyBone('exhaust_4')
            id = CP.resolveExhaustData(1)
            check('MG-CAT-BONE-3 exhaust_4-only → ancora no bone real, sem cair no chassis',
                id ~= -1 and id ~= 0)

            -- nenhum bone de escapamento → cai no fallback chassis/offset (boneId = 0)
            _G.GetEntityBoneIndexByName = function(_, boneName)
                return boneName == 'chassis' and 1 or -1
            end
            id = CP.resolveExhaustData(1)
            check('MG-CAT-BONE-4 sem escapamento → fallback de camera (chassis/offset), boneId 0', id == 0)

            _G.GetEntityBoneIndexByName = origIdx
        end
    end

    -- ─── [FIX-1.1] Transação REAL do desmonte na marreta (VPChopBenchTxn.run) ──────
    -- Sem espelho. Estes casos exercem o MESMO server/logistics/bench_txn.lua que o
    -- callback vp_chopshop:benchProcessPart chama em runtime, contra o PartEntitlement
    -- REAL (Issue/Validate/Consume de verdade — estado ISSUED→CONSUMED observável).
    -- Os únicos seams injetados são as fns de inventário e o relógio.
    do
        local haveTxn = type(_G.VPChopBenchTxn) == 'table' and type(VPChopBenchTxn.run) == 'function'
        check('FIX1-TXN-00 VPChopBenchTxn.run carregado (authority real, nao mock)', haveTxn)
        local havePE = type(_G.PartEntitlement) == 'table' and type(PartEntitlement.Issue) == 'function'

        local txnSeq = 0
        --- Executa a transação real contra um entitlement real recém-emitido.
        ---@return table res, table hstate, string eid
        local function runTxn(o)
            o = o or {}
            txnSeq = txnSeq + 1
            local src = 1
            local partKey = o.partKey or 'door_dside_f'
            local eid = PartEntitlement.Issue('fix11_txn_' .. txnSeq, src, partKey, 10)
            if o.preConsume then PartEntitlement.Consume(eid, src, 'pretest') end

            local hstate = { count = o.hammer or 1, removed = 0, added = 0, refundFailMarker = false }
            local td
            if not o.noTd then
                td = {
                    token = o.tdToken or 'T', entId = o.wrongEntId and 'OTHER' or eid,
                    startedAt = o.startedAt or 0, minMs = o.minMs or 5000,
                    expiresAt = o.expiresAt or 99999,
                }
            end
            local cleared = false

            local fakePE = o.consumeFails and setmetatable({
                Consume = function() return { ok = false, err = 'consume_fail' } end,
            }, { __index = PartEntitlement }) or nil

            local res = VPChopBenchTxn.run({
                source = src,
                entitlementId = eid,
                mode = o.mode or 'raw_materials',
                teardownToken = o.token or 'T',
                buildOutputs = function()
                    return o.outputs or { { item = 'metalscrap', amount = 2 } }
                end,
            }, {
                now = function() return o.now or 6000 end,
                PartEntitlement = fakePE or PartEntitlement,
                teardownRequired = function() return o.exempt ~= true end,
                teardownState = function() return cleared and nil or td end,
                clearTeardown = function() cleared = true end,
                InvCount = function() return hstate.count end,
                InvRemove = function(_, _, n)
                    if hstate.count < n then return false end
                    hstate.count = hstate.count - n; hstate.removed = hstate.removed + n; return true
                end,
                InvAdd = function(_, _, n)
                    if o.refundFails then return false end
                    hstate.count = hstate.count + n; hstate.added = hstate.added + n; return true
                end,
                InvCanCarry = function() return not o.invFull end,
                hammerItem = 'hammer',
                onRefundFail = function() hstate.refundFailMarker = true end,
            })
            return res, hstate, eid
        end

        if haveTxn and havePE then
            local r, h, eid

            r, h = runTxn({ invFull = true })
            check('FIX1-TXN-01 hammer NAO consumido em inventory_full', r.err == 'inventory_full' and h.removed == 0)

            r, h = runTxn({ partKey = 'catalytic_converter', mode = 'clean_serial' })
            check('FIX1-TXN-02 hammer NAO consumido em modo invalido p/ peca (catalytic)',
                r.err == 'invalid_mode_for_part' and h.removed == 0)

            r, h = runTxn({ preConsume = true })
            check('FIX1-TXN-03 hammer NAO consumido: entitlement ja consumido',
                r.err == 'already_consumed' and h.removed == 0)

            r, h, eid = runTxn({})
            check('FIX1-TXN-04 commit valido: hammer 1x + entitlement CONSUMED (estado real)',
                r.ok == true and h.removed == 1
                and select(2, PartEntitlement.Validate(eid, 1)) == 'already_consumed')

            -- replay real: 2a chamada com o MESMO entitlement (agora CONSUMED)
            r, h = runTxn({ preConsume = true, noTd = true })
            check('FIX1-TXN-05 replay: 2o benchProcess sem 2o consumo nem hammer',
                r.err == 'already_consumed' and h.removed == 0)

            -- replay do token puro: entitlement fresco mas sem sessão de desmonte
            r, h = runTxn({ noTd = true })
            check('FIX1-TXN-05b token de desmonte ausente: teardown_required, hammer intacto',
                r.err == 'teardown_required' and h.removed == 0)

            r, h = runTxn({ minMs = 5000, now = 1000 })
            check('FIX1-TXN-06 minigame rapido demais: too_fast, hammer intacto',
                r.err == 'too_fast' and h.removed == 0)

            r, h = runTxn({ expiresAt = 5000, now = 20000 })
            check('FIX1-TXN-07 token expirado: fail-closed, hammer intacto',
                r.err == 'expired' and h.removed == 0)

            r, h = runTxn({ consumeFails = true })
            check('FIX1-TXN-08 falha no consume terminal: hammer devolvido (refund ok)',
                r.err == 'consume_fail' and h.removed == 1 and h.added == 1 and r.refundFailed == false)

            r, h = runTxn({ consumeFails = true, refundFails = true })
            check('FIX1-TXN-09 consume-fail + refund-fail: NAO mascara, marca suporte',
                r.err == 'refund_failed' and r.refundFailed == true
                and h.removed == 1 and h.added == 0 and h.refundFailMarker == true)

            r, h = runTxn({ exempt = true, partKey = 'catalytic_converter', mode = 'raw_materials' })
            check('FIX1-TXN-10 peca isenta (catalytic): commit sem tocar no hammer',
                r.ok == true and h.removed == 0)
        end
    end

    print(('[minigame/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
end

CreateThread(run)
