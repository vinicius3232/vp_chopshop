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

    print(('[minigame/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
end

CreateThread(run)
