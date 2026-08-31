-- client/minigame/minigame_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Self-test do Interaction Core & NUI Foundation (PR UX-A)
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
    check('GetBoneData detects left side sign (-1)', sideLeft == -1.0)

    local _, _, sideRight = Proj.GetBoneData(1, 'wheel_rf')
    check('GetBoneData detects right side sign (1)', sideRight == 1.0)

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

    local wheelPts = Profiles.Get('wheel').generatePoints(1, 'wheel_lf')
    check('wheel profile generates exactly 5 bolts', #wheelPts == 5)

    -- 4) Testes do CameraController
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

    -- 5) Testes do DismantleMinigame Core
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

    print(('[minigame/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
end

CreateThread(run)
