-- bridge/vp_gangs_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  Self-test da ponte vp_chopshop → vp_gangs (contractVersion 1).
--  Self-gated na convar vp_chopshop_selftest 1. Fakes: exports.vp_gangs /
--  ChopSession / GetResourceState. Não sobe FiveM.
--
--  Prova (INT-01C — caminho ÚNICO, sem fallback legado):
--   - filtro phase 1-4 (vin_scratch/plate_theft NÃO emitem);
--   - operationId domínio-derivado (nil sem ChopSession);
--   - payload V1 sem amount/plate/netId/citizenid;
--   - recordExternalCrime ok → 1 chamada;
--   - QUALQUER reason (forbidden_caller / adapter_disabled / bridge_disabled /
--     version_unsupported / bad_payload / no_gang / not_official / replay /
--     dedup_capacity / pcall_error / no_result) → só diagnóstico, ZERO fallback;
--   - vp_gangs stopped → domínio continua, nada é chamado;
--   - `rewardGangActivity` NUNCA é chamado pelo vp_chopshop (canário).
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[int:vp_gangs/spec] PASS  ' .. name)
    else fail = fail + 1; print('[int:vp_gangs/spec] FAIL  ' .. name) end
end

local function run()
    -- ── ambiente controlável (restaurado no fim) ─────────────────────────
    local realCS       = _G.ChopSession
    local realVpGangs  = _G.FAKE_EXPORTS.vp_gangs
    local realVpState  = _G.FAKE_RESOURCES.vp_gangs

    local RECORD_CALLS = {}
    local FORBIDDEN_CALLS = {}   -- canário: rewardGangActivity / qbx_core:GetPlayer NÃO devem ser tocados
    local RECORD_RET = { ok = true }
    local RECORD_THROWS, RECORD_NIL = false, false

    _G.FAKE_RESOURCES.vp_gangs = 'started'
    _G.ChopSession = { GetByVehicle = function(netId) return (netId == 100) and { id = 'cs:7' } or nil end }
    _G.FAKE_EXPORTS.vp_gangs = {
        recordExternalCrime = function(_, src, payload)
            RECORD_CALLS[#RECORD_CALLS + 1] = { src = src, payload = payload }
            if RECORD_THROWS then error('simulated vp_gangs crash') end
            if RECORD_NIL then return nil end
            return RECORD_RET
        end,
        rewardGangActivity = function(...)
            FORBIDDEN_CALLS[#FORBIDDEN_CALLS + 1] = { fn = 'rewardGangActivity', args = { ... } }
        end,
    }
    _G.FAKE_EXPORTS.qbx_core = _G.FAKE_EXPORTS.qbx_core or {}
    local realGetPl = _G.FAKE_EXPORTS.qbx_core.GetPlayer
    _G.FAKE_EXPORTS.qbx_core.GetPlayer = function(...)
        FORBIDDEN_CALLS[#FORBIDDEN_CALLS + 1] = { fn = 'qbx_core:GetPlayer', args = { ... } }
        return { PlayerData = { citizenid = 'SHOULD_NOT_BE_USED' } }
    end

    local function reset()
        RECORD_CALLS, FORBIDDEN_CALLS = {}, {}
        RECORD_RET = { ok = true }
        RECORD_THROWS, RECORD_NIL = false, false
        _G.FAKE_RESOURCES.vp_gangs = 'started'
    end
    local function payload(op, pk, ph) return VPChopGangsBuildPayload(op or 'cs:7:bonnet:p1', pk or 'bonnet', ph or 1) end
    local function noFallback(name) check(name .. ' — ZERO fallback (rewardGangActivity/GetPlayer intocados)', #FORBIDDEN_CALLS == 0) end

    local ok, err = pcall(function()
        -- ── 1) FILTRO ──────────────────────────────────────────────────
        check('phase 1 peça real → emit',          VPChopGangsShouldEmit('door_dside_f', 1) == true)
        check('phase 4 peça real → emit',          VPChopGangsShouldEmit('adv_carcass', 4) == true)
        check('phase 0 → NO emit',                 VPChopGangsShouldEmit('bonnet', 0) == false)
        check('phase 5 → NO emit',                 VPChopGangsShouldEmit('bonnet', 5) == false)
        check('vin_scratch (phase 0) → NO emit',   VPChopGangsShouldEmit('vin_scratch', 0) == false)
        check('vin_scratch c/ phase 1 → NO',       VPChopGangsShouldEmit('vin_scratch', 1) == false)
        check('plate_theft (phase 1) → NO emit',   VPChopGangsShouldEmit('plate_theft', 1) == false)
        check('partKey nil → NO emit',             VPChopGangsShouldEmit(nil, 1) == false)
        check('partKey vazio → NO emit',           VPChopGangsShouldEmit('', 1) == false)

        -- ── 2) operationId ────────────────────────────────────────────
        check('operationId = cs:id : partKey : phase', VPChopGangsOperationId(100, 'bonnet', 2) == 'cs:7:bonnet:p2')
        check('sem ChopSession → operationId nil',      VPChopGangsOperationId(999, 'bonnet', 2) == nil)

        -- ── 3) payload V1 ────────────────────────────────────────────
        local p = VPChopGangsBuildPayload('cs:7:bonnet:p1', 'bonnet', 1)
        check('payload.contractVersion == 1', p.contractVersion == 1)
        check('payload.crime == part_chopped', p.crime == 'part_chopped')
        check('payload.operationId', p.operationId == 'cs:7:bonnet:p1')
        check('payload.partKey', p.partKey == 'bonnet')
        check('payload.phase == 1', p.phase == 1)
        check('payload SEM amount/plate/netId/citizenid/reward',
            p.amount == nil and p.plate == nil and p.netId == nil and p.citizenid == nil and p.reward == nil)

        -- ── 4) caminho ÚNICO — recordExternalCrime ok ───────────────
        reset()
        local r = VPChopGangsDispatch(42, payload())
        check('recordExternalCrime chamado 1×', #RECORD_CALLS == 1)
        check('src repassado', RECORD_CALLS[1].src == 42)
        check('dispatch devolve res.ok', r.ok == true)
        noFallback('ok')

        -- ── 5) QUALQUER reason → só diagnóstico, ZERO fallback ──────
        for _, reason in ipairs({ 'forbidden_caller', 'adapter_disabled', 'bridge_disabled',
                                  'version_unsupported', 'bad_payload', 'no_gang', 'not_official',
                                  'replay', 'dedup_capacity' }) do
            reset(); RECORD_RET = { ok = false, reason = reason }
            local rr = VPChopGangsDispatch(42, payload())
            check(('reason %s → dispatch propaga o reason'):format(reason), rr.reason == reason)
            check(('reason %s → SEM r.compat'):format(reason), rr.compat == nil)
            noFallback(reason)
        end

        -- ── 6) erro AMBÍGUO → só diagnóstico, ZERO fallback ────────
        reset(); RECORD_THROWS = true
        local rt = VPChopGangsDispatch(42, payload())
        check('recordExternalCrime lança → reason pcall_error', rt.reason == 'pcall_error')
        noFallback('pcall_error')

        reset(); RECORD_NIL = true
        local rn = VPChopGangsDispatch(42, payload())
        check('recordExternalCrime retorna nil → reason no_result', rn.reason == 'no_result')
        noFallback('no_result')

        -- ── 7) FAIL-SAFE: vp_gangs stopped ────────────────────────
        reset(); _G.FAKE_RESOURCES.vp_gangs = 'missing'
        local rs = VPChopGangsDispatch(42, payload())
        check('vp_gangs stopped → recordExternalCrime NÃO chamado', #RECORD_CALLS == 0)
        check('vp_gangs stopped → reason vp_gangs_stopped', rs.reason == 'vp_gangs_stopped')
        noFallback('vp_gangs_stopped')

        -- ── 8) HANDLER end-to-end ─────────────────────────────────
        reset()
        VPChopGangsOnPartChopped(42, 100, 'bonnet', 2)
        check('handler: peça real + sessão → 1 recordExternalCrime', #RECORD_CALLS == 1)
        check('handler: operationId correto', RECORD_CALLS[1] and RECORD_CALLS[1].payload.operationId == 'cs:7:bonnet:p2')
        noFallback('handler ok')

        reset(); VPChopGangsOnPartChopped(42, 100, 'vin_scratch', 0)
        check('handler: vin_scratch → 0 emissões', #RECORD_CALLS == 0)
        noFallback('handler vin_scratch')

        reset(); VPChopGangsOnPartChopped(42, 100, 'plate_theft', 1)
        check('handler: plate_theft → 0 emissões', #RECORD_CALLS == 0)

        reset(); VPChopGangsOnPartChopped(42, 999, 'bonnet', 2)
        check('handler: sem ChopSession → 0 emissões (fail-closed)', #RECORD_CALLS == 0)

        -- ── 9) canário estático — nem o código-fonte menciona o caminho legado ──
        local f = io.open((arg and arg[1] or '.') .. '/bridge/vp_gangs.lua', 'r')
        local src = f and f:read('*a') or ''
        if f then f:close() end
        check('vp_gangs.lua NÃO faz a chamada :rewardGangActivity(', not src:find(':rewardGangActivity(', 1, true))
        check('vp_gangs.lua NÃO acessa exports.qbx_core (era só p/ o fallback)', not src:find('qbx_core', 1, true))
        check('vp_gangs.lua NÃO tem ACTIVITY_LEGACY', not src:find('ACTIVITY_LEGACY', 1, true))
        check('vp_gangs.lua NÃO tem marcador de remoção de compat', not src:find('REMOVE ESTE BLOCO', 1, true))
    end)

    -- ── teardown ─────────────────────────────────────────────────
    _G.ChopSession                     = realCS
    _G.FAKE_EXPORTS.vp_gangs            = realVpGangs
    _G.FAKE_EXPORTS.qbx_core.GetPlayer  = realGetPl
    _G.FAKE_RESOURCES.vp_gangs          = realVpState

    if not ok then error(err) end
    print(('[int:vp_gangs/spec] ─── RESUMO: %d/%d PASS%s ───'):format(
        pass, total, fail > 0 and (('  (%d FAIL)'):format(fail)) or ''))
    if fail > 0 then error(('int:vp_gangs_spec: %d/%d failed'):format(fail, total)) end
end

if _G.CreateThread then CreateThread(run) else run() end
