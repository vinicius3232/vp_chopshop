-- server/session/action_session.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-F] ActionSession — AUTORIZAÇÃO TEMPORAL + COMMIT server-authoritative
--  de uma AÇÃO FÍSICA. PR-F: BASE TYRE (wheel_*). PR-G: ADVANCED (door/engine/carcass).
--
--    client START → servidor autoriza + trava a peça (ChopSession.LockPart)
--    client roda UX/minigame
--    client COMPLETE → servidor REVALIDA tudo → executa o commit real UMA vez
--    retry do COMPLETE → devolve o MESMO resultado, ZERO side effects extras
--
--  ⚠ ActionSession NÃO PROVA que o minigame foi jogado honestamente. Um executor
--  ainda pode START → esperar MinDurationMs → COMPLETE. É autorização + commit
--  server-authoritative — NÃO é "minigame proof", "anti-cheat completo" nem "prova
--  de input humano".
--
--  Prova: ação autorizada · jogador certo · ChopSession certa · veículo/VSID certo ·
--  peça certa · participante · raised · distância · ferramenta · estado · tempo
--  mínimo · single-use · mutex.
--
--  Sem `_nonce`: um segredo que nunca sai do servidor não acrescenta nada sobre
--  `actionId + src ownership + server state`. `actionId` é ID OPACO, não segredo.
--
--  NÃO é God object: o DOMÍNIO (MarkPart/reward/tool/entitlement/PART_CHOPPED/…)
--  vive num executor separado (server/action/base_tyre.lua), registrado via
--  ActionSession.RegisterExecutor.
--
--  IN-MEMORY (sem persistência — mesma limitação da ChopSession).
-- ═══════════════════════════════════════════════════════════════════════════════

ActionSession = {}

---@type table<string, table>         actionId → action
local Sessions   = {}
---@type table<string, string>        (src..':'..sessionId..':'..action) → actionId
local OpenByKey  = {}
---@type table<number, string>        src → actionId da ÚNICA action OPEN do jogador
local OpenBySrc  = {}
local _seq       = 0

-- Backstop: uma action nunca deveria ficar em COMMITTING mais que isto. Os
-- executores de domínio não têm Wait/loop — retornam em ~1 frame (inventory ops são
-- exports síncronos). Se algo travar de fato (yield infinito por edição futura), o
-- sweeper destrava a peça. Folgado o suficiente p/ nunca pegar um executor legítimo.
local COMMIT_MAX_MS = 60000
---@type table<string, fun(act: table): table>   kind → executor
local _executors = {}
---@type table<string, table>   kind → { minDurKey, distance(number|fn), validate(v)->err? }
local _kinds = {}

--- Erros de COMPLETE que representam INTENÇÃO recuperável do jogador (afastou-se,
--- soltou a ferramenta, pré-requisito ainda não satisfeito) — a action fecha como
--- CANCELLED (não FAILED), sem log de suspeita. O resto é FAILED.
local RECOVERABLE = {
    distance = true, no_tool = true, no_saw = true, no_screwdriver = true,
    no_welder_adv = true, not_raised = true, hood_first = true, engine_first = true,
}

local StartRate, CompleteRate = {}, {}

local TERMINAL = { COMPLETED = true, CANCELLED = true, EXPIRED = true, FAILED = true }

-- ─── Tempo (seam de teste) ─────────────────────────────────────────────────────
local _clock
local function nowMs() return (_clock or GetGameTimer)() end

-- ─── Acesso a entidade (seam de teste) ────────────────────────────────────────
local EntityAPI = {
    get    = function(netId) return NetworkGetEntityFromNetworkId(netId) end,
    exists = function(e) return e and e ~= 0 and DoesEntityExist(e) end,
}

local function dbg(...)
    if (Config.ActionSession and Config.ActionSession.Debug) or Config.Debug then
        print(('[vp_chopshop][ActionSession] %s'):format(table.concat({ ... }, ' ')))
    end
end

local function cfg() return Config.ActionSession or {} end

local function partLockTtlMs()
    return math.floor(tonumber((Config.ChopSession or {}).PartLockTtlMs) or 60000)
end

--- TTL de uma ActionSession OPEN. INVARIANT: uma action OPEN nunca pode durar mais
--- que o lock autoritativo da peça (`ChopSession.LockPart`) — senão a action fica
--- "viva" com a peça já destravada. Clamp automático se a config estiver errada.
local function actionTtlMs()
    local t   = math.floor(tonumber(cfg().ActionTtlMs) or 45000)
    local lock = partLockTtlMs()
    if t >= lock then
        local clamped = math.max(1000, lock - 1000)
        dbg(('ActionTtlMs (%d) >= PartLockTtlMs (%d) → clamp p/ %d'):format(t, lock, clamped))
        return clamped
    end
    return t
end

local function minDurationMs(kind)
    local md = cfg().MinDurationMs or {}
    return math.floor(tonumber(md[kind]) or 1500)
end

---@param kind string
---@param fn fun(act: table): table   → { ok, err?, result? }
function ActionSession.RegisterExecutor(kind, fn)
    _executors[kind] = fn
end

--- Registra o CONTRATO de um kind de ação (validação específica de domínio).
--- @param kind string
--- @param spec { minDurKey: string, distance: number|fun():number,
---               validate: fun(v: { src, sessionId, netId, action }): string|nil }
function ActionSession.RegisterKind(kind, spec)
    _kinds[kind] = spec
end

local function kindDistance(spec)
    local d = spec.distance
    if type(d) == 'function' then d = d() end
    return tonumber(d) or ((Config.VehicleNearLiftRadius or 5.0) + 2.0)
end

-- ─── Helpers de lifecycle ─────────────────────────────────────────────────────

local function keyOf(src, sessionId, action) return ('%s:%s:%s'):format(src, sessionId, action) end

--- Larga o lock da peça + limpa o índice OpenByKey. Idempotente.
local function releaseAction(act, newStatus, reason)
    if act.status == 'OPEN' or act.status == 'COMMITTING' then
        pcall(ChopSession.UnlockPart, act.sessionId, act.action, act.lockToken)
    end
    act.status  = newStatus
    act.reason  = reason
    act.terminalAt = nowMs()
    local k = keyOf(act.src, act.sessionId, act.action)
    if OpenByKey[k] == act.id then OpenByKey[k] = nil end
    if OpenBySrc[act.src] == act.id then OpenBySrc[act.src] = nil end
    dbg('release', act.id, '→', newStatus, '(' .. tostring(reason) .. ')')
end

-- ─── START ────────────────────────────────────────────────────────────────────

--- Núcleo genérico de START. `kind` já resolvido + validado (registrado via
--- RegisterKind). Client manda SÓ { sessionId, action } — netId/model/vsid/tool/
--- duração/reward/origin/entitlement/preço são TODOS derivados server-side.
--- @return table   { ok, actionId?, replay?, startedAt?, expiresAt?, err? }
local function startCore(src, sessionId, partKey, kind)
    if cfg().Enable == false then return { ok = false, err = 'disabled' } end
    if not (src and GetPlayerName(src)) then return { ok = false, err = 'player' } end
    if type(sessionId) ~= 'string' then return { ok = false, err = 'args' } end
    if type(partKey) ~= 'string' or #partKey < 3 or #partKey > 32 then return { ok = false, err = 'part' } end
    local spec = _kinds[kind]
    if not spec then return { ok = false, err = 'part' } end

    local t = nowMs()
    local k = keyOf(src, sessionId, partKey)

    -- [PR-G hardening] REPLAY IDEMPOTENTE ANTES do rate-limit: MESMO (src, sessionId,
    -- partKey) com action OPEN/COMMITTING → devolve a existente. Um retry idêntico
    -- em <StartRateLimitMs NUNCA pode receber 'processing'.
    local existingId = OpenByKey[k]
    if existingId then
        local ex = Sessions[existingId]
        if ex and ex.status == 'OPEN' and t <= ex.expiresAtMs then
            return { ok = true, actionId = ex.id, replay = true,
                     startedAt = ex.startedAtMs, expiresAt = ex.expiresAtMs }
        end
        if ex and ex.status == 'COMMITTING' then
            return { ok = false, err = 'processing' }              -- índice NÃO é limpo
        end
        if ex and ex.status == 'OPEN' then releaseAction(ex, 'EXPIRED', 'stale_on_start') end
        OpenByKey[k] = nil
    end

    -- rate limit (defense-in-depth) — SÓ para um START NOVO.
    if StartRate[src] and t < StartRate[src] then return { ok = false, err = 'processing' } end
    StartRate[src] = t + math.floor(tonumber(cfg().StartRateLimitMs) or 500)

    -- UMA action OPEN **ou COMMITTING** por jogador — retry com partKey DIFERENTE
    -- não abre uma 2ª (não trava várias peças; não escapa de um commit em curso).
    local mineId = OpenBySrc[src]
    if mineId then
        local mine = Sessions[mineId]
        if mine and (mine.status == 'COMMITTING'
                     or (mine.status == 'OPEN' and t <= mine.expiresAtMs)) then
            return { ok = false, err = 'busy' }                    -- índice NÃO é limpo
        end
        if mine and mine.status == 'OPEN' then releaseAction(mine, 'EXPIRED', 'stale_on_start') end
        OpenBySrc[src] = nil
    end

    local s = ChopSession.Get(sessionId)                        -- ACTIVE (terminal → nil)
    if not s then return { ok = false, err = 'no_session' } end
    if not (s.vehicle and s.vehicle.identity) then return { ok = false, err = 'no_session' } end
    if not ChopSession.HasParticipant(sessionId, src) then return { ok = false, err = 'not_participant' } end
    if s.raised ~= true then return { ok = false, err = 'not_raised' } end
    if s.state == 'READY_FOR_DISCARD' then return { ok = false, err = 'discarding' } end

    local netId = s.vehicle.netId
    local ent = EntityAPI.get(netId)
    if not EntityAPI.exists(ent) then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearVehicle(src, ent, kindDistance(spec)) then return { ok = false, err = 'distance' } end

    if ChopSession.GetPartState(sessionId, partKey) ~= nil then return { ok = false, err = 'done' } end

    -- Contrato de domínio do kind (ferramenta + pré-requisitos + welder, etc.).
    local vErr = spec.validate({ src = src, sessionId = sessionId, netId = netId, action = partKey })
    if vErr then return { ok = false, err = vErr } end

    -- Config fail-safe: TTL efetivo (clampado abaixo do PartLockTtl) não comporta o
    -- tempo mínimo → NÃO cria uma action impossível de concluir.
    local ttl  = actionTtlMs()
    local minD = minDurationMs(spec.minDurKey)
    if ttl <= minD + 1000 then
        dbg(('ActionTtl efetivo (%d) <= MinDuration (%d) → START recusado (misconfigured)'):format(ttl, minD))
        return { ok = false, err = 'misconfigured' }
    end

    -- Trava a peça — o LockPart decide colisão entre players (mesma peça → processing).
    local locked, tok = ChopSession.LockPart(sessionId, partKey)
    if not locked then return { ok = false, err = tok == 'discarding' and 'discarding' or 'processing' } end

    _seq = _seq + 1
    local act = {
        id            = ('as:%d'):format(_seq),
        status        = 'OPEN',
        src           = src,
        sessionId     = sessionId,
        vsid          = s.vehicle.identity,
        netId         = netId,
        action        = partKey,
        kind          = kind,
        startedAtMs   = t,
        expiresAtMs   = t + ttl,
        minDurationMs = minD,
        lockToken     = tok,
        result        = nil,
    }
    Sessions[act.id] = act
    OpenByKey[k]     = act.id
    OpenBySrc[src]   = act.id
    dbg('Start', act.id, kind, 'session', sessionId, 'part', partKey, 'src', src)
    return { ok = true, actionId = act.id, replay = false,
             startedAt = act.startedAtMs, expiresAt = act.expiresAtMs }
end

--- BASE TYRE (wheel_*). DENY `action_disabled` quando o kill-switch legacy está
--- ativo (RequireBaseTyres=false) — nesse modo só o callback legacy processa tyre.
function ActionSession.StartBaseTyre(src, sessionId, partKey)
    if not VPChopActionModeTyre() then return { ok = false, err = 'action_disabled' } end
    if VPChopPartGtaClass(partKey) ~= 'tyre' then return { ok = false, err = 'part' } end
    return startCore(src, sessionId, partKey, 'tyre')
end

--- ADVANCED (PR-G): door (bonnet/boot/door_*), engine (adv_engine), carcass (adv_carcass).
--- Deriva o kind server-side (client só manda `action`). DENY `action_disabled`
--- quando o modo legacy está ativo (RequireAdvanced=false OU EnforceRaised=false).
function ActionSession.StartAdvanced(src, sessionId, partKey)
    if not VPChopActionModeAdvanced() then return { ok = false, err = 'action_disabled' } end
    if not (Config.AdvancedChop and Config.AdvancedChop.Enable) then return { ok = false, err = 'disabled' } end
    -- Paridade com o legacy: mesmo rate-limit de 3s entre ações avançadas
    -- (o executor marca o cooldown via advMarkCooldown).
    if type(VPChopAdvOnCooldown) == 'function' and VPChopAdvOnCooldown(src) then
        return { ok = false, err = 'processing' }
    end
    local kind
    if partKey == 'adv_engine' then kind = 'adv_engine'
    elseif partKey == 'adv_carcass' then kind = 'adv_carcass'
    elseif VPChopPartGtaClass(partKey) == 'door' then kind = 'adv_door'
    end
    if not kind then return { ok = false, err = 'part' } end
    return startCore(src, sessionId, partKey, kind)
end

-- ─── COMPLETE ─────────────────────────────────────────────────────────────────

--- Revalidação completa antes de COMMITTING. Retorna nil (ok) ou uma string de erro.
local function revalidate(act)
    if cfg().Enable == false then return 'disabled' end
    if Config.ChopSession and Config.ChopSession.Enable == false then return 'disabled' end
    if not (act.src and GetPlayerName(act.src)) then return 'player' end
    local spec = _kinds[act.kind]
    if not spec then return 'internal' end
    local s = ChopSession.Get(act.sessionId)
    if not s then return 'no_session' end
    if not (s.vehicle and s.vehicle.identity == act.vsid) then return 'vsid_mismatch' end
    if s.vehicle.netId ~= act.netId then return 'vsid_mismatch' end
    if not ChopSession.HasParticipant(act.sessionId, act.src) then return 'not_participant' end
    if s.raised ~= true then return 'not_raised' end
    if s.state == 'READY_FOR_DISCARD' then return 'discarding' end
    local ent = EntityAPI.get(act.netId)
    if not EntityAPI.exists(ent) then return 'vehicle' end
    if not ValidatePlayerNearVehicle(act.src, ent, kindDistance(spec)) then return 'distance' end
    if ChopSession.GetPartState(act.sessionId, act.action) ~= nil then return 'done' end
    -- Contrato de domínio do kind: ferramenta + pré-requisitos + welder (revalidado).
    return spec.validate({ src = act.src, sessionId = act.sessionId, netId = act.netId, action = act.action })
end

--- @param src number
--- @param actionId string
--- @return table
function ActionSession.Complete(src, actionId)
    if type(actionId) ~= 'string' then return { ok = false, err = 'invalid' } end

    local act = Sessions[actionId]
    if not act then return { ok = false, err = 'invalid' } end
    if act.src ~= src then return { ok = false, err = 'owner' } end

    -- [PR-G hardening] RETRIEVAL IDEMPOTENTE ANTES do rate-limit: um retry do
    -- COMPLETE sobre uma action já terminal NUNCA pode virar 'processing' só por
    -- ter chegado em <CompleteRateLimitMs.
    if act.status == 'COMPLETED' then
        return { ok = true, replay = true, result = act.result }         -- ZERO side effects
    end
    if act.status == 'COMMITTING' then return { ok = false, err = 'processing' } end
    if TERMINAL[act.status] then return { ok = false, err = 'closed', status = act.status } end

    -- OPEN → daqui pra frente é PROCESSAMENTO NOVO: rate-limit se aplica.
    local t = nowMs()
    if CompleteRate[src] and t < CompleteRate[src] then return { ok = false, err = 'processing' } end
    CompleteRate[src] = t + math.floor(tonumber(cfg().CompleteRateLimitMs) or 500)

    if t > act.expiresAtMs then
        releaseAction(act, 'EXPIRED', 'timeout')
        return { ok = false, err = 'expired' }
    end
    local elapsed = t - act.startedAtMs
    if elapsed < act.minDurationMs then
        -- NÃO cancela — client legítimo espera o restante e chama de novo.
        return { ok = false, err = 'too_fast', waitMs = act.minDurationMs - elapsed }
    end

    local rErr = revalidate(act)
    if rErr then
        -- intenção recuperável (distance/tool/pré-requisito) → CANCELLED; falha dura →
        -- FAILED. Ambos fecham a action, destravam a peça, e NÃO produzem
        -- reward/entitlement/PART_CHOPPED.
        releaseAction(act, RECOVERABLE[rErr] and 'CANCELLED' or 'FAILED', rErr)
        return { ok = false, err = rErr }
    end

    -- [PR-G hardening] PIN do lock da peça ANTES de executar o domínio: a partir do
    -- COMMITTING a peça é FAIL-CLOSED (nem TTL nem sweeper liberam — só UnlockPart
    -- com o token certo, no terminal). Se o pin falhar (token perdido), NÃO roda o
    -- domínio.
    if not ChopSession.PinPartLock(act.sessionId, act.action, act.lockToken) then
        releaseAction(act, 'FAILED', 'lock_lost')
        return { ok = false, err = 'lock_lost' }
    end

    -- OPEN → COMMITTING (sem yield entre o check acima e esta escrita — FiveM Lua é
    -- single-thread cooperativo): 2º COMPLETE concorrente vê COMMITTING → 'processing'.
    act.status       = 'COMMITTING'
    act.committingAt = t

    local executor = _executors[act.kind]
    if not executor then
        releaseAction(act, 'FAILED', 'no_executor')
        return { ok = false, err = 'internal' }
    end

    local ok, r = pcall(executor, act)                 -- ESTE passo pode yieldar
    if not ok or type(r) ~= 'table' then
        releaseAction(act, 'FAILED', 'executor_error')
        return { ok = false, err = 'internal' }
    end
    if not r.ok then
        -- ex.: outro player removeu a peça entre a revalidação e o commit → 'done'
        releaseAction(act, 'FAILED', r.err or 'domain')
        return { ok = false, err = r.err or 'domain' }
    end

    act.result = r.result or {}
    releaseAction(act, 'COMPLETED', 'ok')
    return { ok = true, replay = false, result = act.result }
end

-- ─── CANCEL ───────────────────────────────────────────────────────────────────

--- @param src number
--- @param actionId string
--- @return table
function ActionSession.Cancel(src, actionId)
    if type(actionId) ~= 'string' then return { ok = false, err = 'invalid' } end
    local act = Sessions[actionId]
    if not act then return { ok = false, err = 'invalid' } end
    if act.src ~= src then return { ok = false, err = 'owner' } end
    if act.status == 'COMPLETED' then return { ok = true, already_completed = true } end
    if act.status == 'COMMITTING' then return { ok = false, err = 'processing' } end
    if TERMINAL[act.status] then return { ok = true, already = act.status } end
    releaseAction(act, 'CANCELLED', 'client_cancel')
    return { ok = true }
end

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

--- @param src number
function ActionSession.CleanupPlayer(src)
    StartRate[src], CompleteRate[src] = nil, nil
    OpenBySrc[src] = nil
    for _, act in pairs(Sessions) do
        if act.src == src and act.status == 'OPEN' then
            releaseAction(act, 'CANCELLED', 'player_dropped')
        end
        -- COMMITTING NÃO é tocado aqui: o executor coroutine continua rodando mesmo
        -- após o disconnect e chega ao releaseAction (não há Wait no domínio). O
        -- backstop do sweeper cobre o caso patológico de executor travado.
    end
    -- COMPLETED do jogador que saiu podem ficar até o sweeper coletar (replay curto).
end

AddEventHandler('playerDropped', function()
    ActionSession.CleanupPlayer(source)
end)

-- Sweeper leve (event-driven; sem thread por ação).
local function sweepOnce()
    local t = nowMs()
    local retention = math.floor(tonumber(cfg().RetentionMs) or 120000)
    for id, act in pairs(Sessions) do
        if act.status == 'OPEN' then
            if t > act.expiresAtMs then
                releaseAction(act, 'EXPIRED', 'sweeper_timeout')
            elseif not ChopSession.Get(act.sessionId) then
                releaseAction(act, 'FAILED', 'session_gone')
            end
        elseif act.status == 'COMMITTING' then
            -- [PR-G hardening] FAIL-CLOSED: um executor legítimo retorna em ~1 frame.
            -- Se ficar preso MUITO além disso, o sweeper NÃO libera a peça (a
            -- coroutine ainda pode voltar → dois commits). Só loga uma vez e marca
            -- `commitStalled` p/ observabilidade. A peça fica presa (lock pinned) até
            -- o executor retornar OU restart OU tooling admin futuro.
            if not act.commitStalled and t - (act.committingAt or act.startedAtMs) > COMMIT_MAX_MS then
                act.commitStalled = true
                print(('[vp_chopshop][ActionSession] SEVERE: %s preso em COMMITTING > %dms (session %s, part %s) — peça FAIL-CLOSED até o executor retornar.')
                    :format(act.id, COMMIT_MAX_MS, tostring(act.sessionId), tostring(act.action)))
            end
        elseif TERMINAL[act.status] then
            if t - (act.terminalAt or 0) > retention then
                Sessions[id] = nil
            end
        end
    end
end

CreateThread(function()
    local interval = math.floor(tonumber(cfg().SweepIntervalMs) or 5000)
    while true do
        Wait(interval)
        sweepOnce()
    end
end)

-- ─── Callbacks (client) ───────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:action:start', function(src, payload)
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    if type(payload) ~= 'table' then return { ok = false, err = 'args' } end
    -- Client manda SOMENTE { sessionId, action }. O kind é derivado server-side.
    local action = payload.action
    if type(action) ~= 'string' then return { ok = false, err = 'part' } end
    if action == 'adv_engine' or action == 'adv_carcass' then
        return ActionSession.StartAdvanced(src, payload.sessionId, action)
    end
    local gtaClass = VPChopPartGtaClass(action)
    if gtaClass == 'tyre' then
        return ActionSession.StartBaseTyre(src, payload.sessionId, action)
    end
    if gtaClass == 'door' then
        return ActionSession.StartAdvanced(src, payload.sessionId, action)
    end
    return { ok = false, err = 'part' }
end)

lib.callback.register('vp_chopshop:action:complete', function(src, actionId)
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    return ActionSession.Complete(src, actionId)
end)

lib.callback.register('vp_chopshop:action:cancel', function(src, actionId)
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end
    return ActionSession.Cancel(src, actionId)
end)

-- ─── Seam de teste ────────────────────────────────────────────────────────────
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    ActionSession._test = {
        reset        = function() Sessions, OpenByKey, OpenBySrc, _seq = {}, {}, {}, 0; StartRate, CompleteRate = {}, {} end,
        _all         = function() return Sessions end,
        setEntityAPI = function(tbl) for k, v in pairs(tbl) do EntityAPI[k] = v end end,
        setClock     = function(fn) _clock = fn end,
        sweep        = sweepOnce,
    }
end

dbg('módulo carregado')
