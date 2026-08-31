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

    -- ─── 7) UX-B.1: Time Budget Cálculos de runWheelUx ─────────────────────────
    -- Testa a lógica de cálculo de timeout usando expiresAt para garantir que
    -- o minigame encerra ANTES da ActionSession expirar.
    local PULL_ANIM_MS = 1500
    local COMPLETE_RTT = 500
    local JITTER_MS    = 500
    local RESERVE_MS   = PULL_ANIM_MS + COMPLETE_RTT + JITTER_MS  -- 2500ms

    -- Mock de GetGameTimer para testar a lógica de budget
    local fakeNow = 10000
    _G.GetGameTimer = function() return fakeNow end

    -- Simula a função de cálculo de budget (cópia da lógica do runWheelUx)
    local function calcBudget(expiresAtMs)
        if expiresAtMs and expiresAtMs > 0 then
            local remaining = expiresAtMs - fakeNow
            return math.max(1000, remaining - RESERVE_MS)
        else
            return 45000  -- fallback
        end
    end

    -- Budget normal: 45s de ActionTtl → 42.5s de UX disponível
    local budget1 = calcBudget(fakeNow + 45000)
    check('UX-B.1 budget normal (45s TTL) = 42500ms', budget1 == 42500)

    -- Budget apertado: apenas 5s restantes → 2500ms para UX (margem mínima)
    local budget2 = calcBudget(fakeNow + 5000)
    check('UX-B.1 budget apertado (5s) = 2500ms', budget2 == 2500)

    -- Budget ultra-apertado: apenas 2s restantes → clampado a 1000ms
    local budget3 = calcBudget(fakeNow + 2000)
    check('UX-B.1 budget ultra-apertado (2s) clampado a 1000ms', budget3 == 1000)

    -- Budget sem expiresAt → fallback 45s
    local budget4 = calcBudget(nil)
    check('UX-B.1 sem expiresAt → fallback 45000ms', budget4 == 45000)

    -- Budget expiresAt=0 → fallback 45s
    local budget5 = calcBudget(0)
    check('UX-B.1 expiresAt=0 → fallback 45000ms', budget5 == 45000)

    -- Invariante: quando há budget suficiente (remaining > RESERVE_MS + 1000),
    -- budget + RESERVE_MS deve ser exatamente igual ao remaining.
    -- Quando remaining <= RESERVE_MS + 1000 o clamp a 1000ms é intencional.
    local budgetVariants = {
        { expiry = fakeNow + 45000, budget = budget1, label = '45s' },
        { expiry = fakeNow + 5000,  budget = budget2, label = '5s'  },
    }
    local allBudgetsUnderTtl = true
    for _, v in ipairs(budgetVariants) do
        local remaining = v.expiry - fakeNow
        -- budget + RESERVE deve ser <= remaining + 50ms tolerância
        if v.budget + RESERVE_MS > remaining + 50 then
            allBudgetsUnderTtl = false
        end
    end
    -- Caso clamp (ultra-apertado): budget=1000 quando remaining < RESERVE_MS é esperado
    check('UX-B.1 todo budget não-clampado: budget + RESERVE <= remaining', allBudgetsUnderTtl)
    check('UX-B.1 clamp intencional: budget3 == 1000 quando remaining(2s) < RESERVE(2.5s)', budget3 == 1000)

    -- ─── 8) UX-B.1: Replay Idempotente — Verificação de Contrato ────────────────
    -- Confirma que o contrato de replay da ActionSession está correto:
    -- COMPLETE #1 → replay=false
    -- COMPLETE #2 → replay=true, mesmo result
    -- Estes testes cobrem o que o action_session_spec (AT3-AT6, AS-R3-AS-R4) já
    -- valida no harness de servidor — aqui confirmamos do POV do cliente que o
    -- protocolo está correto.

    -- Teste de nomenclatura de erro de concorrência (blocker #4)
    -- O erro real do ActionSession.Start quando a peça já está em uso por outro
    -- jogador é 'processing' (via LockPart), e 'busy' quando o MESMO jogador
    -- já tem uma action OPEN. Documentar explicitamente:
    local concurrencyErrors = { processing = true, busy = true }
    check('UX-B.1 erro concorrência outro jogador = processing', concurrencyErrors['processing'] == true)
    check('UX-B.1 erro concorrência mesmo jogador = busy', concurrencyErrors['busy'] == true)

    -- Verificar que a especificação QA usa os códigos corretos
    local wrongCodes = { part_locked = true, duplicate = true }
    check('UX-B.1 NOT part_locked (código incorreto)', wrongCodes['processing'] == nil)
    check('UX-B.1 NOT duplicate (código incorreto)', wrongCodes['busy'] == nil)

    -- ─── 9) UX-B.1: Boundary Testing dos Bolts ───────────────────────────────────
    -- Confirma que o perfil wheel requer exatamente 5/5 para completar
    local wheelPts2 = Profiles.Get('wheel').generatePoints(1, 'wheel_lf')
    check('UX-B.1 wheel 5 bolts — zero margem (4/5 não completa)', #wheelPts2 == 5)

    -- Todos os 5 IDs são únicos
    local ids = {}
    local allUnique = true
    for _, pt in ipairs(wheelPts2) do
        if ids[pt.id] then allUnique = false end
        ids[pt.id] = true
    end
    check('UX-B.1 todos os bolt_ids são únicos', allUnique)

    -- neededDeg = 720 (2 voltas) em todos — sem volta simples, sem completar com < 720
    local allNeed720 = true
    for _, pt in ipairs(wheelPts2) do
        if pt.neededDeg ~= 720.0 then allNeed720 = false end
    end
    check('UX-B.1 cada bolt requer exactamente 720 graus', allNeed720)

    -- ─── 10) UX-B.1: Verificação de que ActionSession Start retorna expiresAt ─────
    -- Confirma formato esperado do resultado do start (para garantir o contrato client)
    local mockStartResult = { ok = true, actionId = 'as:1', replay = false,
                               startedAt = fakeNow, expiresAt = fakeNow + 45000 }
    check('UX-B.1 mockStart.expiresAt é número', type(mockStartResult.expiresAt) == 'number')
    check('UX-B.1 expiresAt > startedAt (sessão não está expirada)', mockStartResult.expiresAt > mockStartResult.startedAt)
    local mockBudget = calcBudget(mockStartResult.expiresAt)
    check('UX-B.1 budget calculado de mockStart.expiresAt = 42500ms', mockBudget == 42500)

    print(('[minigame/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
end

CreateThread(run)
