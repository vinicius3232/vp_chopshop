-- server/session/action_session.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.15 PR-F] ActionSession — AUTORIZAÇÃO TEMPORAL + COMMIT server-authoritative
--  de uma AÇÃO FÍSICA. Vertical slice desta PR: BASE TYRE (wheel_*).
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

-- Backstop: uma action nunca deveria ficar em COMMITTING mais que isto. O executor
-- de domínio (VPChopChopPartCommit) não tem Wait/loop — retorna em ~1 frame. Se algo
-- travar (edição futura com yield infinito), o sweeper destrava a peça.
local COMMIT_MAX_MS = 30000
---@type table<string, fun(act: table): table>   kind → executor
local _executors = {}

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

-- ─── START (BASE TYRE) ────────────────────────────────────────────────────────

--- @param src number
--- @param sessionId string
--- @param partKey string
--- @return table   { ok, actionId?, replay?, startedAt?, expiresAt?, err? }
function ActionSession.StartBaseTyre(src, sessionId, partKey)
    if cfg().Enable == false then return { ok = false, err = 'disabled' } end
    if not (src and GetPlayerName(src)) then return { ok = false, err = 'player' } end
    if type(sessionId) ~= 'string' then return { ok = false, err = 'args' } end
    if type(partKey) ~= 'string' or #partKey < 3 or #partKey > 32 then return { ok = false, err = 'part' } end

    -- rate limit (defense-in-depth)
    local t = nowMs()
    if StartRate[src] and t < StartRate[src] then return { ok = false, err = 'processing' } end
    StartRate[src] = t + math.floor(tonumber(cfg().StartRateLimitMs) or 500)

    local pdef = ChopParts and ChopParts[partKey]
    if not pdef or pdef.kind ~= 'tyre' then return { ok = false, err = 'part' } end

    -- START idempotente: MESMO (src, sessionId, partKey) com action OPEN válida →
    -- devolve a existente (cobre resposta START perdida). Nunca 'processing' p/ retry
    -- idêntico legítimo.
    local k = keyOf(src, sessionId, partKey)
    local existingId = OpenByKey[k]
    if existingId then
        local ex = Sessions[existingId]
        if ex and ex.status == 'OPEN' and t <= ex.expiresAtMs then
            return { ok = true, actionId = ex.id, replay = true,
                     startedAt = ex.startedAtMs, expiresAt = ex.expiresAtMs }
        end
        -- expirada / stale → limpa e segue p/ um START fresco
        if ex and ex.status == 'OPEN' then releaseAction(ex, 'EXPIRED', 'stale_on_start') end
        OpenByKey[k] = nil
    end

    -- UMA action OPEN por jogador. Um retry com partKey DIFERENTE não abre uma 2ª
    -- (e não deixa o jogador travar várias peças de uma vez). Precisa terminar /
    -- cancelar a atual primeiro.
    local mineId = OpenBySrc[src]
    if mineId then
        local mine = Sessions[mineId]
        if mine and mine.status == 'OPEN' and t <= mine.expiresAtMs then
            return { ok = false, err = 'busy' }
        end
        if mine and mine.status == 'OPEN' then releaseAction(mine, 'EXPIRED', 'stale_on_start') end
        OpenBySrc[src] = nil
    end

    -- Revalidações server-side (client não manda netId/model/vsid/kind/tool/…).
    local s = ChopSession.Get(sessionId)                        -- ACTIVE (terminal → nil)
    if not s then return { ok = false, err = 'no_session' } end
    if not (s.vehicle and s.vehicle.identity) then return { ok = false, err = 'no_session' } end
    if not ChopSession.HasParticipant(sessionId, src) then return { ok = false, err = 'not_participant' } end
    if s.raised ~= true then return { ok = false, err = 'not_raised' } end
    if s.state == 'READY_FOR_DISCARD' then return { ok = false, err = 'discarding' } end

    local netId = s.vehicle.netId
    local ent = EntityAPI.get(netId)
    if not EntityAPI.exists(ent) then return { ok = false, err = 'vehicle' } end
    if not ValidatePlayerNearVehicle(src, ent, (Config.VehicleNearLiftRadius or 5.0) + 2.0) then
        return { ok = false, err = 'distance' }
    end

    if ChopSession.GetPartState(sessionId, partKey) ~= nil then return { ok = false, err = 'done' } end
    if not VPChopHasTool(src, false) then return { ok = false, err = 'no_tool' } end

    -- Config fail-safe: se o TTL efetivo (já clampado abaixo do PartLockTtl) não
    -- comporta o tempo mínimo da ação, NÃO cria uma action impossível de concluir.
    local ttl = actionTtlMs()
    local minD = minDurationMs('tyre')
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
        kind          = 'tyre',
        startedAtMs   = t,
        expiresAtMs   = t + ttl,
        minDurationMs = minDurationMs('tyre'),
        lockToken     = tok,
        result        = nil,
    }
    Sessions[act.id] = act
    OpenByKey[k]     = act.id
    OpenBySrc[src]   = act.id
    dbg('StartBaseTyre', act.id, 'session', sessionId, 'part', partKey, 'src', src)
    return { ok = true, actionId = act.id, replay = false,
             startedAt = act.startedAtMs, expiresAt = act.expiresAtMs }
end

-- ─── COMPLETE ─────────────────────────────────────────────────────────────────

--- Revalidação completa antes de COMMITTING. Retorna nil (ok) ou uma string de erro.
local function revalidate(act)
    if cfg().Enable == false then return 'disabled' end
    if Config.ChopSession and Config.ChopSession.Enable == false then return 'disabled' end
    if not (act.src and GetPlayerName(act.src)) then return 'player' end
    local s = ChopSession.Get(act.sessionId)
    if not s then return 'no_session' end
    if not (s.vehicle and s.vehicle.identity == act.vsid) then return 'vsid_mismatch' end
    if s.vehicle.netId ~= act.netId then return 'vsid_mismatch' end
    if not ChopSession.HasParticipant(act.sessionId, act.src) then return 'not_participant' end
    if s.raised ~= true then return 'not_raised' end
    if s.state == 'READY_FOR_DISCARD' then return 'discarding' end
    local ent = EntityAPI.get(act.netId)
    if not EntityAPI.exists(ent) then return 'vehicle' end
    if not ValidatePlayerNearVehicle(act.src, ent, (Config.VehicleNearLiftRadius or 5.0) + 2.0) then return 'distance' end
    local pdef = ChopParts and ChopParts[act.action]
    if not pdef or pdef.kind ~= 'tyre' then return 'part' end
    if not VPChopHasTool(act.src, false) then return 'no_tool' end
    if ChopSession.GetPartState(act.sessionId, act.action) ~= nil then return 'done' end
    return nil
end

--- @param src number
--- @param actionId string
--- @return table
function ActionSession.Complete(src, actionId)
    if type(actionId) ~= 'string' then return { ok = false, err = 'invalid' } end
    local t = nowMs()
    if CompleteRate[src] and t < CompleteRate[src] then return { ok = false, err = 'processing' } end
    CompleteRate[src] = t + math.floor(tonumber(cfg().CompleteRateLimitMs) or 500)

    local act = Sessions[actionId]
    if not act then return { ok = false, err = 'invalid' } end
    if act.src ~= src then return { ok = false, err = 'owner' } end

    if act.status == 'COMPLETED' then
        return { ok = true, replay = true, result = act.result }         -- ZERO side effects
    end
    if act.status == 'COMMITTING' then return { ok = false, err = 'processing' } end
    if TERMINAL[act.status] then return { ok = false, err = 'closed', status = act.status } end
    -- OPEN
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
        -- cancelamento "de intenção" (distance/tool/…) vs falha dura — ambos fecham a
        -- action, destravam a peça, e NÃO produzem reward/entitlement/PART_CHOPPED.
        releaseAction(act, (rErr == 'distance' or rErr == 'no_tool' or rErr == 'not_raised') and 'CANCELLED' or 'FAILED', rErr)
        return { ok = false, err = rErr }
    end

    -- OPEN → COMMITTING (sem yield entre o check acima e esta escrita — FiveM Lua é
    -- single-thread cooperativo): 2º COMPLETE concorrente vê COMMITTING → 'processing'.
    act.status      = 'COMMITTING'
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
            -- Backstop: um executor legítimo retorna em ~1 frame. Se ficar preso
            -- MUITO além disso (yield infinito por edição futura), destrava a peça.
            if t - (act.committingAt or act.startedAtMs) > COMMIT_MAX_MS then
                releaseAction(act, 'FAILED', 'commit_timeout')
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
    -- Client manda SOMENTE { sessionId, action }. Tudo o mais é derivado server-side.
    return ActionSession.StartBaseTyre(src, payload.sessionId, payload.action)
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
        reset        = function() Sessions, OpenByKey, _seq = {}, {}, 0; StartRate, CompleteRate = {}, {} end,
        _all         = function() return Sessions end,
        setEntityAPI = function(tbl) for k, v in pairs(tbl) do EntityAPI[k] = v end end,
        setClock     = function(fn) _clock = fn end,
        sweep        = sweepOnce,
    }
end

dbg('módulo carregado')
