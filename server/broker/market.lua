-- server/broker/market.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-1.2] DYNAMIC BROKER MARKET ENGINE
--  Autoridade econômica server-side para precificação dinâmica, pressão de volume,
--  recuperação temporal (lazy), persistência assíncrona segura e aplicação de bounds.
-- ═══════════════════════════════════════════════════════════════════════════════

BrokerMarket = BrokerMarket or {}

local _marketState = {}
local _clockFn = nil
local _rngFn = nil
local _dbInstance = nil
local _isReady = false

local function getNow()
    if _clockFn then return _clockFn() end
    return os.time()
end

local function getRng()
    if _rngFn then return _rngFn() end
    return math.random()
end

local function logDebug(...)
    if Config.Broker and Config.Broker.Debug then
        print('[vp_chopshop:broker_market]', ...)
    end
end

--- Sanitiza e valida números contra NaN, Infinity e tipos inválidos
---@param val any
---@param default number|nil
---@param minVal number|nil
---@param maxVal number|nil
---@return number|nil, boolean
local function sanitizeNumber(val, default, minVal, maxVal)
    if type(val) ~= 'number' or val ~= val or val == math.huge or val == -math.huge then
        return default, false
    end
    local clamped = val
    if minVal and clamped < minVal then clamped = minVal end
    if maxVal and clamped > maxVal then clamped = maxVal end
    return clamped, true
end

--- Retorna a configuração global de mercado
---@return table
local function getMarketConfig()
    return (Config.Broker and Config.Broker.Market) or {
        DemandFloor = 0.40,
        DemandCeiling = 1.30,
        PriceFloor = 0.40,
        PriceCeiling = 2.50,
        Jitter = 0.03,
        FlushIntervalSec = 300,
    }
end

--- Retorna a configuração de uma commodity específica
---@param commodity string
---@return table|nil
local function getCommodityConfig(commodity)
    if not Config.Broker or not Config.Broker.Commodities then return nil end
    return Config.Broker.Commodities[commodity]
end

--- Resolve o multiplicador noturno reutilizando Config.Fence.NightBonus
---@param hour number|nil
---@return number
local function resolveNightMultiplier(hour)
    local nbCfg = Config.Fence and Config.Fence.NightBonus
    if not nbCfg or not nbCfg.Enable then
        return 1.00
    end

    local h = hour
    if h == nil and _G.GetClockHours then
        h = _G.GetClockHours()
    end
    if h == nil then
        return 1.00
    end

    local startH = nbCfg.StartHour or 21
    local endH = nbCfg.EndHour or 6
    local mult = nbCfg.Multiplier or 1.30

    local isNight = false
    if startH > endH then
        -- Janela overnight (ex: 21h às 6h)
        isNight = (h >= startH or h < endH)
    else
        -- Janela intra-dia / normal (ex: 1h às 5h)
        isNight = (h >= startH and h < endH)
    end

    return isNight and mult or 1.00
end

BrokerMarket.ResolveNightMultiplier = resolveNightMultiplier

--- Inicializa o estado em memória para uma commodity se ainda não existir
---@param commodity string
---@param now integer|nil
---@return table
local function ensureState(commodity, now)
    local t = now or getNow()
    if not _marketState[commodity] then
        _marketState[commodity] = {
            demand = 1.0000,
            recentVolume = 0,
            lastRecovery = t,
            dirty = false,
        }
    end
    return _marketState[commodity]
end

--- Informa se a engine de mercado foi inicializada e está pronta com DB saudável
---@return boolean
function BrokerMarket.IsReady()
    return _isReady == true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. RECUPERAÇÃO TEMPORAL (LAZY TIME RECOVERY)
-- ─────────────────────────────────────────────────────────────────────────────

--- Aplica recuperação temporal lazy rumo ao equilíbrio (1.00)
---@param commodity string
---@param now integer|nil
---@return number|nil demand, string|nil err
function BrokerMarket.RecoverDemand(commodity, now)
    if Config.Broker and Config.Broker.Enable == false then
        return nil, 'broker_disabled'
    end
    if not BrokerMarket.IsReady() then
        return nil, 'market_not_ready'
    end

    local cfg = getCommodityConfig(commodity)
    if not cfg then return nil, 'unknown_commodity' end

    local state = ensureState(commodity, now)
    local t = now or getNow()
    local elapsed = t - state.lastRecovery

    if elapsed <= 0 then
        return state.demand
    end

    local deltaHours = elapsed / 3600.0
    local recoveryRate = cfg.recoveryPerHour or 0.15
    local current = state.demand

    if current < 1.0000 then
        -- Recuperação ascendente até no máximo 1.0 (nunca ultrapassa o equilíbrio)
        state.demand = math.min(1.0000, current + (recoveryRate * deltaHours))
        state.dirty = true
    elseif current > 1.0000 then
        -- Arrefecimento descendente até no mínimo 1.0
        state.demand = math.max(1.0000, current - (recoveryRate * deltaHours))
        state.dirty = true
    end

    state.lastRecovery = t
    logDebug(('RecoverDemand: %s -> %.4f (delta %.2fh)'):format(commodity, state.demand, deltaHours))
    return state.demand
end

--- Consulta o índice de demanda atualizado com recuperação temporal lazy
---@param commodity string
---@param now integer|nil
---@return number|nil demand, string|nil err
function BrokerMarket.GetDemandIndex(commodity, now)
    if Config.Broker and Config.Broker.Enable == false then
        return nil, 'broker_disabled'
    end
    if not BrokerMarket.IsReady() then
        return nil, 'market_not_ready'
    end

    local demand, err = BrokerMarket.RecoverDemand(commodity, now)
    if not demand then return nil, err end

    local mCfg = getMarketConfig()
    return math.max(mCfg.DemandFloor, math.min(mCfg.DemandCeiling, demand))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. REGISTRO DE VENDA E PRESSÃO DE VOLUME
-- ─────────────────────────────────────────────────────────────────────────────

--- Registra uma venda e aplica pressão de demanda decrescente
---@param commodity string
---@param count integer
---@param now integer|nil
---@return table
function BrokerMarket.RecordSale(commodity, count, now)
    if Config.Broker and Config.Broker.Enable == false then
        return { ok = false, err = 'broker_disabled' }
    end
    if not BrokerMarket.IsReady() then
        return { ok = false, err = 'market_not_ready' }
    end

    local cfg = getCommodityConfig(commodity)
    if not cfg then
        return { ok = false, err = 'unknown_commodity' }
    end

    if type(count) ~= 'number' or count ~= count or count == math.huge or count == -math.huge or count < 1 or count > 10000 or count ~= math.floor(count) then
        return { ok = false, err = 'invalid_count' }
    end
    local qty = count

    local t = now or getNow()
    local prevDemand = BrokerMarket.RecoverDemand(commodity, t)
    local mCfg = getMarketConfig()

    local pressure = (cfg.salePressure or 0.03) * qty
    local newDemand = math.max(mCfg.DemandFloor, math.min(mCfg.DemandCeiling, prevDemand - pressure))

    local state = _marketState[commodity]
    state.demand = newDemand
    state.recentVolume = state.recentVolume + qty
    state.lastRecovery = t
    state.dirty = true

    logDebug(('RecordSale: %s x%d -> Demand: %.4f (was %.4f)'):format(commodity, qty, newDemand, prevDemand))

    return {
        ok = true,
        commodity = commodity,
        count = qty,
        previousDemand = prevDemand,
        newDemand = newDemand,
        volume = state.recentVolume,
        lastRecovery = state.lastRecovery,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RESOLUÇÃO DE PREÇO SERVER-AUTHORITATIVE
-- ─────────────────────────────────────────────────────────────────────────────

--- Resolve o preço unitário e multiplicadores para uma commodity
--- Regra Hardening: Trust bloqueado ou Heat burning retorna ok=false (NO TRADE)
---@param commodity string
---@param context table|nil
---@return table
function BrokerMarket.ResolvePrice(commodity, context)
    if Config.Broker and Config.Broker.Enable == false then
        return { ok = false, err = 'broker_disabled' }
    end
    if not BrokerMarket.IsReady() then
        return { ok = false, err = 'market_not_ready' }
    end

    local cfg = getCommodityConfig(commodity)
    if not cfg then
        return { ok = false, err = 'unknown_commodity' }
    end

    local ctx = context or {}
    local mCfg = getMarketConfig()

    -- ─── 1. Validação de Regras de Bloqueio (NO TRADE) ──────────────────────
    -- Trust 0 / Bloqueado
    if ctx.isBlockedTrust == true or (ctx.trustLevel ~= nil and ctx.trustLevel <= 0) or (ctx.trustMultiplier ~= nil and ctx.trustMultiplier <= 0) then
        return { ok = false, err = 'trust_required' }
    end

    -- Heat Queimando / Burning
    if ctx.isBurningHeat == true or (ctx.heatMultiplier ~= nil and ctx.heatMultiplier <= 0) or (ctx.heatLabel == 'burning') then
        return { ok = false, err = 'heat_blocked' }
    end

    -- ─── 2. Resolução de Multiplicadores ────────────────────────────────────
    -- Demanda
    local demand
    if ctx.demandOverride ~= nil then
        local validDem, isNum = sanitizeNumber(ctx.demandOverride, nil, mCfg.DemandFloor, mCfg.DemandCeiling)
        if not isNum then
            return { ok = false, err = 'invalid_demand' }
        end
        demand = validDem
    else
        local d = BrokerMarket.GetDemandIndex(commodity, ctx.timestamp)
        demand = d or 1.0000
    end

    -- Trust Multiplier
    local trustMult = ctx.trustMultiplier
    if trustMult ~= nil then
        local sanitized, okNum = sanitizeNumber(trustMult, 1.00, 0.0, 5.0)
        if not okNum then return { ok = false, err = 'invalid_multipliers' } end
        trustMult = sanitized
    else
        local trustLevel = ctx.trustLevel or 1
        local trustTable = { [1] = 1.00, [2] = 1.15, [3] = 1.30, [4] = 1.50 }
        trustMult = trustTable[trustLevel] or 1.00
    end

    -- Progression Tier Multiplier (Reutiliza Config.Progression.FencePriceMult)
    local tierMult = ctx.tierMultiplier
    if tierMult ~= nil then
        local sanitized, okNum = sanitizeNumber(tierMult, 1.00, 0.0, 5.0)
        if not okNum then return { ok = false, err = 'invalid_multipliers' } end
        tierMult = sanitized
    else
        local tier = ctx.progressionTier or 1
        local multTable = (Config.Progression and Config.Progression.FencePriceMult) or {}
        tierMult = multTable[tier] or 1.00
    end

    -- Bônus Noturno (Reutiliza Config.Fence.NightBonus)
    local nightMult = ctx.nightMultiplier
    if nightMult ~= nil then
        local sanitized, okNum = sanitizeNumber(nightMult, 1.00, 0.0, 5.0)
        if not okNum then return { ok = false, err = 'invalid_multipliers' } end
        nightMult = sanitized
    else
        nightMult = resolveNightMultiplier(ctx.hour)
    end

    -- Penalidade de Heat Policial
    local heatMult = ctx.heatMultiplier
    if heatMult ~= nil then
        local sanitized, okNum = sanitizeNumber(heatMult, 1.00, 0.0, 5.0)
        if not okNum then return { ok = false, err = 'invalid_multipliers' } end
        heatMult = sanitized
    else
        if ctx.heatLabel == 'warm' then heatMult = 0.90
        elseif ctx.heatLabel == 'hot' then heatMult = 0.75
        else heatMult = 1.00 end
    end

    -- Jitter de Negociação
    local maxJitter = mCfg.Jitter or 0.03
    local jitterVal = ctx.jitter
    if jitterVal == nil then
        local r = getRng() -- [0.0, 1.0]
        jitterVal = (r * 2.0 - 1.0) * maxJitter -- [-maxJitter, +maxJitter]
    else
        local sanitized, okNum = sanitizeNumber(jitterVal, 0.0, -maxJitter, maxJitter)
        if not okNum then return { ok = false, err = 'invalid_multipliers' } end
        jitterVal = sanitized
    end
    local jitterMult = 1.0 + jitterVal

    -- ─── 3. Cálculo do Preço Bruto e Hard Bounds ────────────────────────────
    local basePrice = cfg.basePrice or 100
    local rawPrice = basePrice * demand * trustMult * tierMult * nightMult * heatMult * jitterMult

    local floorPrice = math.floor(basePrice * mCfg.PriceFloor)
    local ceilingPrice = math.floor(basePrice * mCfg.PriceCeiling)

    local boundedPrice = math.max(floorPrice, math.min(ceilingPrice, math.floor(rawPrice + 0.5)))

    return {
        ok = true,
        unitPrice = boundedPrice,
        basePrice = basePrice,
        demand = demand,
        multipliers = {
            demand = demand,
            trust = trustMult,
            tier = tierMult,
            night = nightMult,
            heat = heatMult,
            jitter = jitterMult,
        },
        bounds = {
            floor = floorPrice,
            ceiling = ceilingPrice,
            hitFloor = (rawPrice < floorPrice),
            hitCeiling = (rawPrice > ceilingPrice),
        },
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. SNAPSHOT E PERSISTÊNCIA ASSÍNCRONA
-- ─────────────────────────────────────────────────────────────────────────────

--- Obtém o snapshot de mercado de uma ou todas as commodities
---@param commodity string|nil
---@param now integer|nil
---@return table
function BrokerMarket.GetSnapshot(commodity, now)
    local t = now or getNow()
    if commodity then
        local cfg = getCommodityConfig(commodity)
        if not cfg then return { ok = false, err = 'unknown_commodity' } end
        local d = BrokerMarket.GetDemandIndex(commodity, t)
        local state = _marketState[commodity] or {}
        return {
            ok = true,
            commodity = commodity,
            demandIndex = d or 1.0000,
            recentVolume = state.recentVolume or 0,
            lastRecovery = state.lastRecovery or t,
            basePrice = cfg.basePrice,
        }
    end

    local result = {}
    if Config.Broker and Config.Broker.Commodities then
        for k, cfg in pairs(Config.Broker.Commodities) do
            local d = BrokerMarket.GetDemandIndex(k, t)
            local state = _marketState[k] or {}
            result[k] = {
                demandIndex = d or 1.0000,
                recentVolume = state.recentVolume or 0,
                lastRecovery = state.lastRecovery or t,
                basePrice = cfg.basePrice,
            }
        end
    end
    return { ok = true, commodities = result }
end

--- Salva o estado de uma commodity no MySQL de forma idempotente
---@param commodity string
---@return boolean
function BrokerMarket.SaveCommodity(commodity)
    local state = _marketState[commodity]
    if not state or not state.dirty then return true end

    local db = _dbInstance or _G.MySQL
    if not db or not db.query or not db.query.await then
        return false
    end

    local ok, res = pcall(function()
        return db.query.await([[
            INSERT INTO `vp_chop_broker_market` (`commodity`, `demand_index`, `recent_volume`, `last_recovery`)
            VALUES (?, ?, ?, FROM_UNIXTIME(?))
            ON DUPLICATE KEY UPDATE
                `demand_index`  = VALUES(`demand_index`),
                `recent_volume` = VALUES(`recent_volume`),
                `last_recovery` = VALUES(`last_recovery`)
        ]], { commodity, state.demand, state.recentVolume, state.lastRecovery })
    end)

    if ok and res ~= nil and (type(res) == 'table' or type(res) == 'number') then
        state.dirty = false
        return true
    else
        logDebug('SaveCommodity SQL error:', res)
        return false
    end
end

--- Executa flush de todas as commodities modificadas
---@param now integer|nil
---@return integer savedCount
function BrokerMarket.Flush(now)
    local count = 0
    for commodity, state in pairs(_marketState) do
        if state.dirty then
            if BrokerMarket.SaveCommodity(commodity) then
                count = count + 1
            end
        end
    end
    return count
end

--- Seam de teste determinístico para disparo de flush periódico
---@param now integer|nil
---@return integer savedCount
function BrokerMarket.TriggerPeriodicFlush(now)
    return BrokerMarket.Flush(now)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. BOOTSTRAP & TEST INJECTION HOOKS
-- ─────────────────────────────────────────────────────────────────────────────

--- Carrega o snapshot persistido do banco de dados
--- Fail-closed: DB ausente ou falha no SELECT resulta em isReady = false
---@param clockFn function|nil
---@param dbOverride table|nil
---@param rngFn function|nil
---@return boolean isReady
function BrokerMarket.Init(clockFn, dbOverride, rngFn)
    _clockFn = clockFn
    _rngFn = rngFn
    _dbInstance = dbOverride
    _marketState = {}
    _isReady = false

    if Config.Broker and Config.Broker.Enable == false then
        logDebug('BrokerMarket disabled by config.')
        return false
    end

    local db = _dbInstance or _G.MySQL
    if not db or not db.query or not db.query.await then
        logDebug('BrokerMarket DB absent/invalid. Running in DEGRADED/UNAVAILABLE state.')
        _isReady = false
        return false
    end

    local t = getNow()

    if Config.Broker and Config.Broker.Commodities then
        for k, _ in pairs(Config.Broker.Commodities) do
            _marketState[k] = {
                demand = 1.0000,
                recentVolume = 0,
                lastRecovery = t,
                dirty = false,
            }
        end
    end

    local ok, rows = pcall(function()
        return db.query.await('SELECT `commodity`, `demand_index`, `recent_volume`, UNIX_TIMESTAMP(`last_recovery`) AS last_rec FROM `vp_chop_broker_market`')
    end)

    if ok and type(rows) == 'table' then
        for _, row in ipairs(rows) do
            if _marketState[row.commodity] then
                _marketState[row.commodity].demand = tonumber(row.demand_index) or 1.0000
                _marketState[row.commodity].recentVolume = tonumber(row.recent_volume) or 0
                _marketState[row.commodity].lastRecovery = tonumber(row.last_rec) or t
                _marketState[row.commodity].dirty = false
            end
        end
        _isReady = true
    else
        logDebug('BrokerMarket DB Init SELECT query failed. Running in DEGRADED/UNAVAILABLE state.')
        _isReady = false
        return false
    end

    logDebug('BrokerMarket initialized successfully.')
    return true
end

--- Hooks para testes determinísticos
function BrokerMarket.SetClock(fn) _clockFn = fn end
function BrokerMarket.SetRng(fn) _rngFn = fn end
function BrokerMarket.SetDemand(commodity, demand, now)
    local state = ensureState(commodity, now)
    local mCfg = getMarketConfig()
    state.demand = math.max(mCfg.DemandFloor, math.min(mCfg.DemandCeiling, demand))
    state.lastRecovery = now or getNow()
    state.dirty = true
end

-- Thread de flush periódico em background (registrada no carregamento do módulo)
if _G.CreateThread then
    CreateThread(function()
        while true do
            local intervalSec = (Config.Broker and Config.Broker.Market and Config.Broker.Market.FlushIntervalSec) or 300
            Wait(intervalSec * 1000)
            if Config.Broker and Config.Broker.Enable and BrokerMarket.IsReady() then
                BrokerMarket.Flush()
            end
        end
    end)
end

-- Inicialização automática no servidor FiveM quando o DB estiver pronto
if _G.AddEventHandler then
    AddEventHandler('vp_chopshop:server:dbReady', function()
        BrokerMarket.Init()
    end)

    AddEventHandler('onResourceStop', function(resName)
        if _G.GetCurrentResourceName and resName == GetCurrentResourceName() and BrokerMarket.IsReady() then
            BrokerMarket.Flush()
        end
    end)
end
