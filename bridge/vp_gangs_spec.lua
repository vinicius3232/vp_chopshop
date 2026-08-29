-- bridge/vp_gangs_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [INT-01A] Self-test da ponte vp_chopshop → vp_gangs (contractVersion 1).
--  Self-gated na convar vp_chopshop_selftest 1. Fakes: exports.vp_gangs /
--  exports.qbx_core / ChopSession / GetResourceState. Não sobe FiveM.
--
--  Prova: filtro phase 1-4 (vin_scratch/plate_theft NÃO emitem) · operationId
--  domínio-derivado · payload V1 sem amount/plate/netId/citizenid · caminho novo
--  (recordExternalCrime) · compat SÓ em reasons pre-mutation
--  (forbidden_caller/disabled/bridge_disabled) · rejeição legítima
--  (not_official/replay/no_gang/bad_payload) NÃO cai no compat · ERRO AMBÍGUO
--  (pcall_error/no_result) NUNCA compensa (at-most-once) · fail-safe vp_gangs
--  stopped · handler end-to-end.
--
--  Todo setup/teardown de ambiente vive DENTRO de run() para não vazar
--  (ex.: não sobrescrever o ChopSession real que os outros specs usam).
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
    local realGetPl    = _G.FAKE_EXPORTS.qbx_core and _G.FAKE_EXPORTS.qbx_core.GetPlayer
    local realVpState  = _G.FAKE_RESOURCES.vp_gangs

    local RECORD_CALLS, REWARD_CALLS = {}, {}
    local RECORD_RET = { ok = true }
    local RECORD_THROWS, RECORD_NIL = false, false

    _G.FAKE_RESOURCES.vp_gangs = 'started'
    _G.FAKE_RESOURCES.qbx_core = _G.FAKE_RESOURCES.qbx_core or 'started'
    _G.ChopSession = { GetByVehicle = function(netId) return (netId == 100) and { id = 'cs:7' } or nil end }
    _G.FAKE_EXPORTS.vp_gangs = {
        recordExternalCrime = function(_, src, payload)
            RECORD_CALLS[#RECORD_CALLS + 1] = { src = src, payload = payload }
            if RECORD_THROWS then error('simulated vp_gangs crash AFTER possible mutation') end
            if RECORD_NIL then return nil end
            return RECORD_RET
        end,
        rewardGangActivity = function(_, cid, activity, opts)
            REWARD_CALLS[#REWARD_CALLS + 1] = { cid = cid, activity = activity, opts = opts or {} }
        end,
    }
    _G.FAKE_EXPORTS.qbx_core = _G.FAKE_EXPORTS.qbx_core or {}
    _G.FAKE_EXPORTS.qbx_core.GetPlayer = function(_, src)
        return { PlayerData = { citizenid = 'CID_' .. tostring(src) } }
    end

    local function reset()
        RECORD_CALLS, REWARD_CALLS = {}, {}
        RECORD_RET = { ok = true }
        RECORD_THROWS, RECORD_NIL = false, false
        _G.FAKE_RESOURCES.vp_gangs = 'started'
    end
    local function payload(op, pk, ph) return VPChopGangsBuildPayload(op or 'cs:7:bonnet:p1', pk or 'bonnet', ph or 1) end

    local ok, err = pcall(function()
        -- ── 1) FILTRO: só phase 1-4 de peça real ─────────────────────────
        check('phase 1 peça real → emit',          VPChopGangsShouldEmit('door_dside_f', 1) == true)
        check('phase 4 peça real → emit',          VPChopGangsShouldEmit('adv_carcass', 4) == true)
        check('phase 0 → NO emit',                 VPChopGangsShouldEmit('bonnet', 0) == false)
        check('phase 5 → NO emit',                 VPChopGangsShouldEmit('bonnet', 5) == false)
        check('vin_scratch (phase 0) → NO emit',   VPChopGangsShouldEmit('vin_scratch', 0) == false)
        check('vin_scratch mesmo c/ phase 1 → NO', VPChopGangsShouldEmit('vin_scratch', 1) == false)
        check('plate_theft (phase 1) → NO emit',   VPChopGangsShouldEmit('plate_theft', 1) == false)
        check('partKey nil → NO emit',             VPChopGangsShouldEmit(nil, 1) == false)
        check('partKey vazio → NO emit',           VPChopGangsShouldEmit('', 1) == false)

        -- ── 2) operationId domínio-derivado ────────────────────────────
        check('operationId = cs:id : partKey : phase', VPChopGangsOperationId(100, 'bonnet', 2) == 'cs:7:bonnet:p2')
        check('sem ChopSession → operationId nil',      VPChopGangsOperationId(999, 'bonnet', 2) == nil)

        -- ── 3) payload V1 mínimo ──────────────────────────────────────
        local p = VPChopGangsBuildPayload('cs:7:bonnet:p1', 'bonnet', 1)
        check('payload.contractVersion == 1', p.contractVersion == 1)
        check('payload.crime == part_chopped', p.crime == 'part_chopped')
        check('payload.operationId', p.operationId == 'cs:7:bonnet:p1')
        check('payload.partKey', p.partKey == 'bonnet')
        check('payload.phase == 1 (número)', p.phase == 1)
        check('payload SEM amount', p.amount == nil)
        check('payload SEM plate', p.plate == nil)
        check('payload SEM netId', p.netId == nil)
        check('payload SEM citizenid', p.citizenid == nil)
        check('payload SEM reward/payout', p.reward == nil and p.payout == nil)

        -- ── 4) dispatch: caminho NOVO (recordExternalCrime ok) ────────
        reset()
        local r = VPChopGangsDispatch(42, payload())
        check('recordExternalCrime chamado 1×', #RECORD_CALLS == 1)
        check('src repassado (não é identidade — vp_gangs resolve)', RECORD_CALLS[1].src == 42)
        check('payload repassado', RECORD_CALLS[1].payload.operationId == 'cs:7:bonnet:p1')
        check('ok → NÃO cai no compat', #REWARD_CALLS == 0)
        check('dispatch devolve res.ok', r.ok == true)

        -- ── 5) COMPAT só em reasons PRE-MUTATION ─────────────────────
        reset(); RECORD_RET = { ok = false, reason = 'forbidden_caller' }
        r = VPChopGangsDispatch(42, payload())
        check('forbidden_caller → fallback rewardGangActivity 1×', #REWARD_CALLS == 1)
        check('fallback cid resolvido server-side', REWARD_CALLS[1] and REWARD_CALLS[1].cid == 'CID_42')
        check('fallback activity = vehicle_chop', REWARD_CALLS[1] and REWARD_CALLS[1].activity == 'vehicle_chop')
        check('fallback opts vazio → 0 payout', REWARD_CALLS[1] and next(REWARD_CALLS[1].opts) == nil)
        check('dispatch marca compat = true', r.compat == true)

        reset(); RECORD_RET = { ok = false, reason = 'disabled' }
        VPChopGangsDispatch(42, payload())
        check('disabled → também cai no compat', #REWARD_CALLS == 1)

        reset(); RECORD_RET = { ok = false, reason = 'bridge_disabled' }
        VPChopGangsDispatch(42, payload())
        check('bridge_disabled → também cai no compat', #REWARD_CALLS == 1)

        -- ── 6) REJEIÇÃO LEGÍTIMA (pós-avaliação) NÃO cai no compat ───
        reset(); RECORD_RET = { ok = false, reason = 'not_official' }
        r = VPChopGangsDispatch(42, payload())
        check('not_official → SEM fallback (rejeição legítima)', #REWARD_CALLS == 0)
        check('dispatch propaga reason', r.reason == 'not_official')

        reset(); RECORD_RET = { ok = false, reason = 'replay' }
        VPChopGangsDispatch(42, payload())
        check('replay (idempotência do vp_gangs) → SEM fallback', #REWARD_CALLS == 0)

        reset(); RECORD_RET = { ok = false, reason = 'no_gang' }
        VPChopGangsDispatch(42, payload())
        check('no_gang (chop solo) → SEM fallback', #REWARD_CALLS == 0)

        reset(); RECORD_RET = { ok = false, reason = 'bad_payload' }
        VPChopGangsDispatch(42, payload())
        check('bad_payload → SEM fallback', #REWARD_CALLS == 0)

        -- ── 6b) ERRO AMBÍGUO (pode ter mutado antes de falhar) → at-most-once ──
        reset(); RECORD_THROWS = true
        r = VPChopGangsDispatch(42, payload())
        check('recordExternalCrime LANÇA erro → reason pcall_error', r.reason == 'pcall_error')
        check('pcall_error → REWARD_CALLS == 0 (NÃO compensa)', #REWARD_CALLS == 0)
        check('pcall_error → r.compat ausente', r.compat == nil)

        reset(); RECORD_NIL = true
        r = VPChopGangsDispatch(42, payload())
        check('recordExternalCrime retorna nil → reason no_result', r.reason == 'no_result')
        check('no_result → REWARD_CALLS == 0 (NÃO compensa)', #REWARD_CALLS == 0)

        -- ── 7) FAIL-SAFE: vp_gangs stopped ──────────────────────────
        reset(); _G.FAKE_RESOURCES.vp_gangs = 'missing'
        r = VPChopGangsDispatch(42, payload())
        check('vp_gangs stopped → recordExternalCrime NÃO chamado', #RECORD_CALLS == 0)
        check('vp_gangs stopped → SEM fallback', #REWARD_CALLS == 0)
        check('dispatch devolve vp_gangs_stopped', r.reason == 'vp_gangs_stopped')

        -- ── 8) HANDLER end-to-end (VPChopEvt.PART_CHOPPED) ──────────
        reset()
        VPChopGangsOnPartChopped(42, 100, 'bonnet', 2)
        check('handler: peça real phase 2 + sessão → 1 recordExternalCrime', #RECORD_CALLS == 1)
        check('handler: operationId correto', RECORD_CALLS[1] and RECORD_CALLS[1].payload.operationId == 'cs:7:bonnet:p2')

        reset(); VPChopGangsOnPartChopped(42, 100, 'vin_scratch', 0)
        check('handler: vin_scratch → 0 emissões', #RECORD_CALLS == 0 and #REWARD_CALLS == 0)

        reset(); VPChopGangsOnPartChopped(42, 100, 'plate_theft', 1)
        check('handler: plate_theft → 0 emissões', #RECORD_CALLS == 0 and #REWARD_CALLS == 0)

        reset(); VPChopGangsOnPartChopped(42, 999, 'bonnet', 2)
        check('handler: sem ChopSession → 0 emissões (fail-closed)', #RECORD_CALLS == 0)
    end)

    -- ── teardown ────────────────────────────────────────────────────
    _G.ChopSession             = realCS
    _G.FAKE_EXPORTS.vp_gangs    = realVpGangs
    if _G.FAKE_EXPORTS.qbx_core then _G.FAKE_EXPORTS.qbx_core.GetPlayer = realGetPl end
    _G.FAKE_RESOURCES.vp_gangs  = realVpState

    if not ok then error(err) end
    print(('[int:vp_gangs/spec] ─── RESUMO: %d/%d PASS%s ───'):format(
        pass, total, fail > 0 and (('  (%d FAIL)'):format(fail)) or ''))
    if fail > 0 then error(('int:vp_gangs_spec: %d/%d failed'):format(fail, total)) end
end

if _G.CreateThread then CreateThread(run) else run() end
