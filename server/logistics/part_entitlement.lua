-- server/logistics/part_entitlement.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 SEC-1] PART ENTITLEMENT — LEDGER LOGÍSTICO AUTORITATIVO DE PEÇAS FÍSICAS.
--
--  Resolve P0-SEC-01 e P0-SEC-02:
--  Elimina a confiança cega em partKey ou carry visual enviado pelo client.
--  Toda peça física removida (portas, capô, porta-malas, motor, catalisador)
--  possui um entitlement server-authoritative com ciclo de vida:
--    ISSUED → CONSUMED (bancada / fence)
--       └─→ LOST (player drop / cleanup)
--
--  INVARIANTE ECONÔMICO:
--  1) O client NUNCA dita partKey nem recompensa: o servidor deriva partKey do entitlement.
--  2) Consumo AT-MOST-ONCE: chamar 2× o mesmo entitlementId resulta em 0 recompensa na 2ª vez.
--  3) Concorrência: atomic consume sem yields intermediários.
--  4) Replay: ActionSession COMPLETE devolve exatamente o mesmo entitlementId sem novo Issue.
--  5) Ownership: apenas o jogador que removeu a peça pode consumi-la.
-- ═══════════════════════════════════════════════════════════════════════════════

PartEntitlement = {}

---@alias PartEntitlementState 'ISSUED'|'CONSUMED'|'LOST'

---@type table<string, table>              entitlementId → entitlement
local Entitlements = {}
---@type table<string, string>             (sessionId..':'..partKey) → entitlementId (idempotência)
local BySourcePart = {}
local _seq = 0

---@type table<string, table<number, number>> bucket → src → expiryMs
local RateLimits = {}

local function dbg(...)
    if Config.Debug then
        print(('[vp_chopshop][PartEntitlement] %s'):format(table.concat({ ... }, ' ')))
    end
end

--- Normaliza a chave do jogador para comparação exata livre de falsos-positivos.
--- Remove prefixos como 'qbx:', 'qb:', 'esx:', 'src:' mantendo o ID real.
---@param val string|number|nil
---@return string
local function normalizeKey(val)
    if not val then return '' end
    local s = tostring(val)
    s = s:gsub('^%a+:', '')
    return string.upper(s:gsub('%s+', ''))
end

-- ─── Emissão ───────────────────────────────────────────────────────────────────

--- Emite (ou devolve o existente) o entitlement de uma peça física removida.
--- IDEMPOTENTE por (sessionId, partKey): replays/retries nunca geram um 2º entitlement.
---@param sessionId string
---@param src number
---@param partKey string
---@param sourceNetId? number
---@param opts? { origin?: string, meta?: table }
---@return string|nil entitlementId, boolean|string isNewOrErr
function PartEntitlement.Issue(sessionId, src, partKey, sourceNetId, opts)
    if type(sessionId) ~= 'string' or type(partKey) ~= 'string' then return nil, 'args' end
    if not src or src <= 0 then return nil, 'invalid_src' end

    local ownerKey = ServerChopPlayerKey(src)
    if not ownerKey or ownerKey == '' then return nil, 'no_owner' end

    -- Idempotência atômica síncrona sem yield
    local key = sessionId .. ':' .. partKey
    local existing = BySourcePart[key]
    if existing and Entitlements[existing] then
        return existing, false
    end

    _seq = _seq + 1
    local now = os.time()
    local e = {
        id             = ('pe:%d'):format(_seq),
        ownerKey       = ownerKey,
        ownerSrc       = src,
        partKey        = partKey,
        sessionId      = sessionId,
        sourceNetId    = tonumber(sourceNetId) or 0,
        origin         = (opts and opts.origin) or 'advanced',
        state          = 'ISSUED',
        createdAt      = now,
        updatedAt      = now,
        consumedAt     = nil,
        consumedBy     = nil,
        consumedAction = nil,
    }
    Entitlements[e.id] = e
    BySourcePart[key]  = e.id
    dbg('Issue', e.id, 'partKey', partKey, 'session', sessionId, 'owner', ownerKey)
    return e.id, true
end

-- ─── Leitura ───────────────────────────────────────────────────────────────────

---@param id string
---@return table|nil
function PartEntitlement.Get(id)
    local e = Entitlements[id]
    if not e then return nil end
    return {
        id             = e.id,
        ownerKey       = e.ownerKey,
        ownerSrc       = e.ownerSrc,
        partKey        = e.partKey,
        sessionId      = e.sessionId,
        sourceNetId    = e.sourceNetId,
        origin         = e.origin,
        state          = e.state,
        createdAt      = e.createdAt,
        updatedAt      = e.updatedAt,
        consumedAt     = e.consumedAt,
        consumedBy     = e.consumedBy,
        consumedAction = e.consumedAction,
    }
end

---@param id string
---@return PartEntitlementState|nil
function PartEntitlement.State(id)
    local e = Entitlements[id]
    return e and e.state or nil
end

-- ─── Validação ─────────────────────────────────────────────────────────────────

--- Valida se o entitlement existe, pertence ao jogador e está com estado ISSUED.
---@param id string
---@param src number
---@param expectedPartKey? string
---@return boolean ok, string|table errOrEntitlement
function PartEntitlement.Validate(id, src, expectedPartKey)
    if type(id) ~= 'string' or id == '' then return false, 'invalid_id' end
    local e = Entitlements[id]
    if not e then return false, 'not_found' end

    if e.state == 'CONSUMED' then return false, 'already_consumed' end
    if e.state ~= 'ISSUED' then return false, 'bad_state' end

    local playerKey = ServerChopPlayerKey(src)
    if normalizeKey(e.ownerKey) ~= normalizeKey(playerKey) then
        return false, 'owner_mismatch'
    end

    if expectedPartKey and e.partKey ~= expectedPartKey then
        return false, 'invalid_type'
    end

    return true, e
end

-- ─── Consumo Atômico (At-Most-Once) ────────────────────────────────────────────

--- Consome atômica e definitivamente o entitlement.
--- Garante que apenas a primeira chamada tem sucesso e concede os dados da peça.
---@param id string
---@param src number
---@param actionName string
---@param expectedPartKey? string
---@return { ok: boolean, err?: string, partKey?: string, sourceNetId?: number, sessionId?: string, entitlement?: table }
function PartEntitlement.Consume(id, src, actionName, expectedPartKey)
    local okVal, valRes = PartEntitlement.Validate(id, src, expectedPartKey)
    if not okVal then
        return { ok = false, err = valRes }
    end

    local e = valRes
    -- ⚠ Consumo atômico sem yield entre a validação e a mudança de estado
    e.state          = 'CONSUMED'
    e.consumedAt     = os.time()
    e.consumedBy     = ServerChopPlayerKey(src)
    e.consumedAction = actionName or 'unknown'
    e.updatedAt      = os.time()

    dbg('Consume', id, 'partKey', e.partKey, 'action', actionName, 'by', src)
    return {
        ok          = true,
        partKey     = e.partKey,
        sourceNetId = e.sourceNetId,
        sessionId   = e.sessionId,
        entitlement = PartEntitlement.Get(id),
    }
end

-- ─── Rate Limiting Defensivo ───────────────────────────────────────────────────

---@param src number
---@param bucket string
---@param cooldownMs number
---@return boolean allowed
function PartEntitlement.CheckRateLimit(src, bucket, cooldownMs)
    if not src or src <= 0 then return false end
    RateLimits[bucket] = RateLimits[bucket] or {}
    local now = GetGameTimer()
    local expiry = RateLimits[bucket][src] or 0
    if now < expiry then
        return false
    end
    RateLimits[bucket][src] = now + (tonumber(cooldownMs) or 500)
    return true
end

--- Log de atividade suspeita
---@param src number
---@param reason string
---@param details? string
function PartEntitlement.LogSuspicious(src, reason, details)
    local msg = ('[SECURITY][PartEntitlement] src: %s (%s) | reason: %s | details: %s'):format(
        tostring(src),
        tostring(ServerChopPlayerKey(src)),
        tostring(reason),
        tostring(details or 'none')
    )
    print(('[vp_chopshop] %s'):format(msg))
    if type(VPChopDiscordLog) == 'function' then
        pcall(VPChopDiscordLog, 'Alerta de Segurança - PartEntitlement', msg)
    end
end

-- ─── Cleanup ───────────────────────────────────────────────────────────────────

AddEventHandler('playerDropped', function()
    local src = source
    for _, bucket in pairs(RateLimits) do
        bucket[src] = nil
    end
end)

-- ─── Seam de Teste ─────────────────────────────────────────────────────────────
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    PartEntitlement._test = {
        reset = function() Entitlements, BySourcePart, RateLimits, _seq = {}, {}, {}, 0 end,
        _all  = function() return Entitlements end,
        normalizeKey = normalizeKey,
    }
end

dbg('módulo PartEntitlement carregado')
