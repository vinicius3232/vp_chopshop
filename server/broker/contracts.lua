-- server/broker/contracts.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-3 / BROKER-3.1] CONTRACTS & HIGH-DEMAND LISTS DOMAIN
--  Gerencia contratos pessoais, janelas globais de alta demanda, matching
--  server-authoritative de peças/modelos/classes e liquidação at-most-once.
-- ═══════════════════════════════════════════════════════════════════════════════

BrokerContracts = {}

local _clock = os.time
local _db = nil
local _rng = math.random
local _ready = false

local GlobalGenerationBusy = false
local PersonalGenerationBusy = {} ---@type table<string, boolean>
local ContractFulfillmentBusy = {} ---@type table<number, boolean>
local _hookBeforeConsume = nil

local function dbg(...)
    if Config.Broker and Config.Broker.Debug then
        print('[vp_chopshop:contracts]', ...)
    end
end

-- ─── Normalização de Hash 32-bit (Unsigned / Signed) ─────────────────────────

local function normHash32(value)
    local n = math.floor(tonumber(value) or 0)
    if n < 0 then n = n + 4294967296 end
    return n % 4294967296
end

-- ─── RNG Helper Seam ─────────────────────────────────────────────────────────

local function randInt(minVal, maxVal)
    local low = tonumber(minVal) or 1
    local high = tonumber(maxVal) or low
    if low >= high then return low end
    local r = _rng()
    if type(r) == 'number' then
        if r >= 0.0 and r <= 1.0 then
            local res = low + math.floor(r * (high - low + 1))
            if res > high then res = high end
            return res
        elseif r >= low and r <= high then
            return math.floor(r)
        end
    end
    return low
end

local function pickIndex(size)
    local s = tonumber(size) or 1
    if s <= 1 then return 1 end
    local r = _rng()
    if type(r) == 'number' and r >= 0.0 and r <= 1.0 then
        local idx = math.floor(r * s) + 1
        if idx > s then idx = s end
        return idx
    end
    return 1
end

-- ─── Inicialização & Seams ─────────────────────────────────────────────────────

local function checkDbValid(db)
    return db ~= nil
        and db ~= false
        and type(db) == 'table'
        and type(db.query) == 'table'
        and type(db.query.await) == 'function'
        and type(db.insert) == 'table'
        and type(db.insert.await) == 'function'
end

--- Inicializa a engine de contratos com seams injetáveis.
---@param db? table oxmysql wrapper ou mock
---@param clockFn? fun():number timestamp atual em segundos
---@param rngFn? fun():number gerador pseudo-aleatório 0..1
function BrokerContracts.Init(db, clockFn, rngFn)
    if db ~= nil then
        _db = db
    elseif _db == nil then
        _db = _G.MySQL
    end
    if clockFn ~= nil then _clock = clockFn end
    if rngFn ~= nil then _rng = rngFn end

    _ready = checkDbValid(_db)
    dbg('BrokerContracts inicializado, ready =', _ready)
end

--- Indica se a persistência de contratos está pronta para operações.
---@return boolean
function BrokerContracts.IsReady()
    return _ready == true and checkDbValid(_db or _G.MySQL)
end

--- Retorna o timestamp canônico da engine de contratos.
---@return number
function BrokerContracts.GetNow()
    return _clock and _clock() or os.time()
end

local function getNow()
    return BrokerContracts.GetNow()
end

local function getDb()
    return _db or _G.MySQL
end

-- Boot handler automático acionado pelo db.lua após migrations
if AddEventHandler or _G.AddEventHandler then
    local registerEvt = AddEventHandler or _G.AddEventHandler
    registerEvt('vp_chopshop:server:dbReady', function()
        BrokerContracts.Init()
    end)
end

-- ─── Mutex por Contract ID ───────────────────────────────────────────────────

--- Adquire lock exclusivo em memória para o ciclo de fulfillment de um contrato.
---@param contractId number
---@return boolean acquired
function BrokerContracts.AcquireLock(contractId)
    local cId = tonumber(contractId)
    if not cId then return false end
    if ContractFulfillmentBusy[cId] then return false end
    ContractFulfillmentBusy[cId] = true
    return true
end

--- Libera lock exclusivo de fulfillment de um contrato.
---@param contractId number
function BrokerContracts.ReleaseLock(contractId)
    local cId = tonumber(contractId)
    if not cId then return end
    ContractFulfillmentBusy[cId] = nil
end

-- ─── Expiração Passiva / Ativa ─────────────────────────────────────────────────

--- Atualiza o estado de contratos vencidos para EXPIRED.
---@param now? number
---@return number expiredCount
function BrokerContracts.ExpireDue(now)
    if not BrokerContracts.IsReady() then return 0 end
    local curTime = now or getNow()
    local db = getDb()

    local sql = [[
        UPDATE `vp_chop_broker_contracts`
        SET `state` = 'EXPIRED'
        WHERE `state` IN ('AVAILABLE', 'ACCEPTED')
          AND `expires_at` <= FROM_UNIXTIME(?)
    ]]
    local ok, res = pcall(function()
        return db.query.await(sql, { curTime })
    end)
    if not ok or not res then return 0 end
    local affected = (type(res) == 'table' and res.affectedRows) or (type(res) == 'number' and res) or 0
    if affected > 0 then
        dbg('Contratos expirados purgados:', affected)
    end
    return affected
end

-- ─── Validação de Termos Econômicos Persistidos (Fail-Closed) ──────────────────

--- Valida se os termos econômicos de uma linha persistida de contrato são estritamente válidos e finitos.
---@param contract table
---@return boolean ok, string|nil err
function BrokerContracts.ValidateEconomicTerms(contract)
    if not contract or type(contract) ~= 'table' then
        return false, 'invalid_contract'
    end

    local cfgContracts = (Config.Broker and Config.Broker.Contracts) or {}
    local multMin = tonumber(cfgContracts.RewardMultMin) or 1.05
    local multMax = tonumber(cfgContracts.RewardMultMax) or 1.80
    local bonusMax = tonumber(cfgContracts.BonusCashMax) or 15000

    -- contractType allowlist
    local cType = contract.contractType or contract.contract_type
    if not cType or (cType ~= 'part_type' and cType ~= 'model' and cType ~= 'class' and cType ~= 'high_value') then
        return false, 'invalid_contract_terms'
    end

    -- rewardMult: finite number, not NaN, not +/-inf, within [multMin, multMax]
    local mult = tonumber(contract.rewardMult or contract.reward_mult)
    if not mult or mult ~= mult or mult == math.huge or mult == -math.huge then
        return false, 'invalid_contract_terms'
    end
    if mult < multMin or mult > multMax then
        return false, 'invalid_contract_terms'
    end

    -- bonusCash: finite non-negative integer <= bonusMax
    local bonus = tonumber(contract.bonusCash or contract.bonus_cash)
    if not bonus or bonus ~= bonus or bonus == math.huge or bonus == -math.huge or bonus < 0 or bonus ~= math.floor(bonus) then
        return false, 'invalid_contract_terms'
    end
    if bonus > bonusMax then
        return false, 'invalid_contract_terms'
    end

    -- Global contracts must have bonus_cash == 0
    local isGlobal = (contract.isGlobal == true or (contract.for_identifier == nil and contract.playerKey == nil))
    if isGlobal and bonus ~= 0 then
        return false, 'invalid_contract_terms'
    end

    -- quantity: integer >= 1
    local qty = tonumber(contract.quantity)
    if not qty or qty < 1 or qty ~= math.floor(qty) or qty == math.huge then
        return false, 'invalid_contract_terms'
    end

    -- remaining: integer, 0 <= remaining <= quantity
    local rem = tonumber(contract.remaining)
    if not rem or rem < 0 or rem > qty or rem ~= math.floor(rem) or rem == math.huge then
        return false, 'invalid_contract_terms'
    end

    -- minTrust: integer >= 0
    local minTrust = tonumber(contract.minTrust or contract.min_trust)
    if not minTrust or minTrust < 0 or minTrust ~= math.floor(minTrust) or minTrust == math.huge then
        return false, 'invalid_contract_terms'
    end

    return true
end

-- ─── Matching Server-Authoritative ─────────────────────────────────────────────

--- Valida se uma peça com entitlement atende aos requisitos do contrato.
---@param contract table Registro do contrato do DB
---@param entitlement table Dados do entitlement ou resultado de PartEntitlement.Validate
---@return boolean matched, string|nil commodityOrErr
function BrokerContracts.Match(contract, entitlement)
    if not contract or type(contract) ~= 'table' then
        return false, 'invalid_contract'
    end
    if not entitlement or type(entitlement) ~= 'table' then
        return false, 'invalid_entitlement'
    end

    local partKey = entitlement.partKey
    if not partKey or type(partKey) ~= 'string' then
        return false, 'invalid_part'
    end

    local cfgIntegration = (Config.Broker and Config.Broker.Integration) or {}
    local p2c = cfgIntegration.PhysicalPartToCommodity or {}
    local resolvedCommodity = p2c[partKey] or partKey
    local provenance = entitlement.provenance

    local cType = contract.contractType or contract.contract_type or 'part_type'
    local targetKey = tostring(contract.targetKey or contract.target_key or ''):lower()

    if cType == 'part_type' then
        if resolvedCommodity:lower() == targetKey or partKey:lower() == targetKey then
            return true, resolvedCommodity
        end
        return false, 'wrong_part'

    elseif cType == 'model' then
        if not provenance or not provenance.model or provenance.model == 0 then
            return false, 'provenance_missing'
        end

        local expectedHash = normHash32(GetHashKey(targetKey))
        local provModel = normHash32(provenance.model)

        if provModel == expectedHash then
            return true, resolvedCommodity
        end
        return false, 'wrong_part'

    elseif cType == 'class' then
        if not provenance or (provenance.className == nil and provenance.vehicleClass == nil) then
            return false, 'provenance_class_missing'
        end

        local provClassName = provenance.className and tostring(provenance.className):lower() or nil
        local provClassNum = provenance.vehicleClass ~= nil and tostring(provenance.vehicleClass) or nil

        if (provClassName and provClassName == targetKey) or (provClassNum and provClassNum == targetKey) then
            return true, resolvedCommodity
        end
        return false, 'wrong_part'

    elseif cType == 'high_value' then
        local highValTargets = (Config.Broker and Config.Broker.Contracts and Config.Broker.Contracts.HighValueTargets) or {}
        if not highValTargets[targetKey] then
            return false, 'invalid_high_value_target'
        end

        if resolvedCommodity:lower() == targetKey or partKey:lower() == targetKey then
            return true, resolvedCommodity
        end
        return false, 'wrong_part'

    else
        return false, 'unknown_contract_type'
    end
end

-- ─── Geração Procedural de Contratos ───────────────────────────────────────────

local function pickPoolItem(poolName, trustLevel)
    local pools = Config.Broker and Config.Broker.Contracts and Config.Broker.Contracts.Pools
    if not pools or not pools[poolName] or #pools[poolName] == 0 then return nil end

    local eligible = {}
    for _, item in ipairs(pools[poolName]) do
        if not item.minTrust or trustLevel >= item.minTrust then
            eligible[#eligible + 1] = item
        end
    end
    if #eligible == 0 then return nil end

    local idx = pickIndex(#eligible)
    return eligible[idx]
end

--- Garante a existência de janelas públicas de alta demanda (contratos globais).
---@param now? number
---@return number generatedCount
function BrokerContracts.EnsureGlobalContracts(now)
    if not BrokerContracts.IsReady() then return 0 end
    if GlobalGenerationBusy then return 0 end
    GlobalGenerationBusy = true

    local curTime = now or getNow()
    BrokerContracts.ExpireDue(curTime)

    local cfgContracts = (Config.Broker and Config.Broker.Contracts) or {}
    if cfgContracts.Enable == false then
        GlobalGenerationBusy = false
        return 0
    end

    local maxSlots = tonumber(cfgContracts.GlobalSlots) or 3
    local ttl = tonumber(cfgContracts.GlobalTTL) or 7200
    local multMin = tonumber(cfgContracts.RewardMultMin) or 1.05
    local multMax = tonumber(cfgContracts.RewardMultMax) or 1.80

    local db = getDb()
    local countSql = [[
        SELECT COUNT(*) AS cnt
        FROM `vp_chop_broker_contracts`
        WHERE `for_identifier` IS NULL
          AND `state` = 'AVAILABLE'
          AND `expires_at` > FROM_UNIXTIME(?)
    ]]
    local okCnt, rowsCnt = pcall(function()
        return db.query.await(countSql, { curTime })
    end)
    if not okCnt or not rowsCnt or not rowsCnt[1] then
        GlobalGenerationBusy = false
        return 0
    end
    local currentCount = tonumber(rowsCnt[1].cnt) or 0
    local needed = maxSlots - currentCount
    if needed <= 0 then
        GlobalGenerationBusy = false
        return 0
    end

    local poolTypes = { 'part_type', 'model', 'class', 'high_value' }
    local generated = 0

    for _ = 1, needed do
        local pTypeIdx = pickIndex(#poolTypes)
        local pType = poolTypes[pTypeIdx]

        local item = pickPoolItem(pType, 4) -- global pool usa trust full
        if item then
            local qty = randInt(item.minQty or 1, item.maxQty or 3)
            local mult = math.max(multMin, math.min(multMax, tonumber(item.mult) or 1.20))
            local bonus = 0 -- contratos globais têm 0 bonus_cash para evitar disputas de conclusão multi-player
            local minTrust = tonumber(item.minTrust) or 1
            local expiresAt = curTime + ttl

            local insertSql = [[
                INSERT INTO `vp_chop_broker_contracts`
                (`for_identifier`, `contract_type`, `target_key`, `quantity`, `remaining`, `reward_mult`, `bonus_cash`, `min_trust`, `created_at`, `expires_at`, `state`)
                VALUES (NULL, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), 'AVAILABLE')
            ]]
            local okIns, insertId = pcall(function()
                return db.insert.await(insertSql, {
                    pType,
                    item.key,
                    qty,
                    qty,
                    mult,
                    bonus,
                    minTrust,
                    curTime,
                    expiresAt,
                })
            end)
            if okIns and insertId ~= nil and insertId ~= false and insertId ~= 0 then
                generated = generated + 1
            end
        end
    end

    GlobalGenerationBusy = false
    return generated
end

--- Garante a existência de contratos pessoais para um jogador elegível por Trust.
---@param playerKey string Identificador canônico (qbx:citizenid ou license:xxx)
---@param trustLevel number
---@param now? number
---@return number generatedCount
function BrokerContracts.EnsurePersonalContracts(playerKey, trustLevel, now)
    if not BrokerContracts.IsReady() or not playerKey or playerKey == '' then return 0 end
    if PersonalGenerationBusy[playerKey] then return 0 end
    PersonalGenerationBusy[playerKey] = true

    local curTime = now or getNow()
    BrokerContracts.ExpireDue(curTime)

    local cfgContracts = (Config.Broker and Config.Broker.Contracts) or {}
    if cfgContracts.Enable == false then
        PersonalGenerationBusy[playerKey] = nil
        return 0
    end

    local minTrustGate = tonumber(cfgContracts.MinTrust) or 3
    if (tonumber(trustLevel) or 0) < minTrustGate then
        PersonalGenerationBusy[playerKey] = nil
        return 0
    end

    local maxSlots = tonumber(cfgContracts.PersonalSlots) or 3
    local ttl = tonumber(cfgContracts.PersonalTTL) or 3600
    local multMin = tonumber(cfgContracts.RewardMultMin) or 1.05
    local multMax = tonumber(cfgContracts.RewardMultMax) or 1.80
    local bonusMax = tonumber(cfgContracts.BonusCashMax) or 15000

    local db = getDb()
    local countSql = [[
        SELECT COUNT(*) AS cnt
        FROM `vp_chop_broker_contracts`
        WHERE `for_identifier` = ?
          AND `state` IN ('AVAILABLE', 'ACCEPTED')
          AND `expires_at` > FROM_UNIXTIME(?)
    ]]
    local okCnt, rowsCnt = pcall(function()
        return db.query.await(countSql, { playerKey, curTime })
    end)
    if not okCnt or not rowsCnt or not rowsCnt[1] then
        PersonalGenerationBusy[playerKey] = nil
        return 0
    end
    local currentCount = tonumber(rowsCnt[1].cnt) or 0
    local needed = maxSlots - currentCount
    if needed <= 0 then
        PersonalGenerationBusy[playerKey] = nil
        return 0
    end

    local poolTypes = { 'part_type', 'model', 'class', 'high_value' }
    local generated = 0

    for _ = 1, needed do
        local pTypeIdx = pickIndex(#poolTypes)
        local pType = poolTypes[pTypeIdx]

        local item = pickPoolItem(pType, trustLevel)
        if item then
            local qty = randInt(item.minQty or 1, item.maxQty or 2)
            local mult = math.max(multMin, math.min(multMax, tonumber(item.mult) or 1.25))
            local bonus = math.max(0, math.min(bonusMax, tonumber(item.bonus) or 2000))
            local minTrust = math.max(minTrustGate, tonumber(item.minTrust) or minTrustGate)
            local expiresAt = curTime + ttl

            local insertSql = [[
                INSERT INTO `vp_chop_broker_contracts`
                (`for_identifier`, `contract_type`, `target_key`, `quantity`, `remaining`, `reward_mult`, `bonus_cash`, `min_trust`, `created_at`, `expires_at`, `state`)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), 'AVAILABLE')
            ]]
            local okIns, insertId = pcall(function()
                return db.insert.await(insertSql, {
                    playerKey,
                    pType,
                    item.key,
                    qty,
                    qty,
                    mult,
                    bonus,
                    minTrust,
                    curTime,
                    expiresAt,
                })
            end)
            if okIns and insertId ~= nil and insertId ~= false and insertId ~= 0 then
                generated = generated + 1
            end
        end
    end

    PersonalGenerationBusy[playerKey] = nil
    return generated
end

-- ─── Consultas de Contratos ────────────────────────────────────────────────────

--- Retorna a lista de contratos visíveis para um jogador (globais + pessoais).
---@param playerKey string
---@param trustLevel number
---@param now? number
---@return table[] contracts
function BrokerContracts.GetAvailable(playerKey, trustLevel, now)
    if not BrokerContracts.IsReady() then return {} end
    local curTime = now or getNow()
    local tLevel = tonumber(trustLevel) or 0

    BrokerContracts.EnsureGlobalContracts(curTime)
    if playerKey and playerKey ~= '' then
        BrokerContracts.EnsurePersonalContracts(playerKey, tLevel, curTime)
    end

    local db = getDb()
    local sql = [[
        SELECT `id`, `for_identifier`, `contract_type`, `target_key`, `quantity`, `remaining`,
               `reward_mult`, `bonus_cash`, `min_trust`,
               UNIX_TIMESTAMP(`expires_at`) AS `expires_at`,
               UNIX_TIMESTAMP(`created_at`) AS `created_at`,
               `state`
        FROM `vp_chop_broker_contracts`
        WHERE ((`for_identifier` IS NULL AND `state` = 'AVAILABLE')
           OR (`for_identifier` = ? AND `state` IN ('AVAILABLE', 'ACCEPTED')))
          AND `expires_at` > FROM_UNIXTIME(?)
          AND `min_trust` <= ?
        ORDER BY `for_identifier` DESC, `id` ASC
    ]]

    local ok, rows = pcall(function()
        return db.query.await(sql, { playerKey or '', curTime, tLevel })
    end)
    if not ok or not rows then return {} end

    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            id           = tonumber(r.id),
            isGlobal     = (r.for_identifier == nil),
            playerKey    = r.for_identifier,
            contractType = r.contract_type,
            targetKey    = r.target_key,
            quantity     = tonumber(r.quantity),
            remaining    = tonumber(r.remaining),
            rewardMult   = tonumber(r.reward_mult) or 1.0,
            bonusCash    = tonumber(r.bonus_cash) or 0,
            minTrust     = tonumber(r.min_trust) or 1,
            expiresAt    = tonumber(r.expires_at),
            createdAt    = tonumber(r.created_at),
            state        = r.state,
        }
    end

    return out
end

--- Carrega um contrato individual pelo ID.
---@param contractId number
---@return table|nil contract
function BrokerContracts.Get(contractId)
    if not BrokerContracts.IsReady() or not contractId then return nil end
    local db = getDb()
    local sql = [[
        SELECT `id`, `for_identifier`, `contract_type`, `target_key`, `quantity`, `remaining`,
               `reward_mult`, `bonus_cash`, `min_trust`,
               UNIX_TIMESTAMP(`expires_at`) AS `expires_at`,
               UNIX_TIMESTAMP(`created_at`) AS `created_at`,
               UNIX_TIMESTAMP(`fulfilled_at`) AS `fulfilled_at`,
               `state`
        FROM `vp_chop_broker_contracts`
        WHERE `id` = ?
    ]]
    local ok, rows = pcall(function()
        return db.query.await(sql, { tonumber(contractId) })
    end)
    if not ok or not rows or not rows[1] then return nil end
    local r = rows[1]
    return {
        id           = tonumber(r.id),
        isGlobal     = (r.for_identifier == nil),
        playerKey    = r.for_identifier,
        contractType = r.contract_type,
        targetKey    = r.target_key,
        quantity     = tonumber(r.quantity),
        remaining    = tonumber(r.remaining),
        rewardMult   = tonumber(r.reward_mult) or 1.0,
        bonusCash    = tonumber(r.bonus_cash) or 0,
        minTrust     = tonumber(r.min_trust) or 1,
        expiresAt    = tonumber(r.expires_at),
        createdAt    = tonumber(r.created_at),
        fulfilledAt  = r.fulfilled_at and tonumber(r.fulfilled_at) or nil,
        state        = r.state,
    }
end

-- ─── Aceite de Contrato Pessoal ────────────────────────────────────────────────

--- Aceita um contrato pessoal disponível (AVAILABLE -> ACCEPTED).
---@param contractId number
---@param playerKey string
---@param trustLevel number
---@param now? number
---@return { ok: boolean, err?: string }
function BrokerContracts.Accept(contractId, playerKey, trustLevel, now)
    if not BrokerContracts.IsReady() then
        return { ok = false, err = 'db_not_ready' }
    end
    if not contractId or not playerKey or playerKey == '' then
        return { ok = false, err = 'invalid_args' }
    end

    local curTime = now or getNow()
    local tLevel = tonumber(trustLevel) or 0
    local db = getDb()

    local updateSql = [[
        UPDATE `vp_chop_broker_contracts`
        SET `state` = 'ACCEPTED'
        WHERE `id` = ?
          AND `for_identifier` = ?
          AND `state` = 'AVAILABLE'
          AND `min_trust` <= ?
          AND `expires_at` > FROM_UNIXTIME(?)
    ]]

    local ok, res = pcall(function()
        return db.query.await(updateSql, { tonumber(contractId), playerKey, tLevel, curTime })
    end)
    if not ok or not res then
        return { ok = false, err = 'db_error' }
    end

    local affected = (type(res) == 'table' and res.affectedRows) or (type(res) == 'number' and res) or 0
    if affected > 0 then
        return { ok = true }
    end

    -- Diagnóstico do motivo da rejeição
    local c = BrokerContracts.Get(contractId)
    if not c then
        return { ok = false, err = 'not_found' }
    end
    if c.playerKey ~= playerKey then
        return { ok = false, err = 'owner_mismatch' }
    end
    if c.expiresAt and c.expiresAt <= curTime then
        return { ok = false, err = 'contract_expired' }
    end
    if c.minTrust > tLevel then
        return { ok = false, err = 'trust_gate' }
    end
    if c.state ~= 'AVAILABLE' then
        return { ok = false, err = 'not_available' }
    end

    return { ok = false, err = 'accept_failed' }
end

-- ─── Reserva & Compensação Atômica de Quota ───────────────────────────────────

--- Reserva de forma atômica 1 unidade de quota no contrato via UPDATE condicional.
---@param contractId number
---@param playerKey string
---@param trustLevel number
---@param now? number
---@return { ok: boolean, completed?: boolean, remaining?: number, err?: string, contract?: table }
function BrokerContracts.ReserveFulfillment(contractId, playerKey, trustLevel, now)
    if not BrokerContracts.IsReady() then
        return { ok = false, err = 'db_not_ready' }
    end
    local cId = tonumber(contractId)
    if not cId or not playerKey or playerKey == '' then
        return { ok = false, err = 'invalid_args' }
    end

    local curTime = now or getNow()
    local tLevel = tonumber(trustLevel) or 0
    local db = getDb()

    -- 1. Tentar UPDATE FINAL atômico (remaining == 1 -> 0 / COMPLETED)
    local finalSql = [[
        UPDATE `vp_chop_broker_contracts`
        SET `remaining` = 0,
            `state` = 'COMPLETED',
            `fulfilled_at` = FROM_UNIXTIME(?)
        WHERE `id` = ?
          AND ((`for_identifier` IS NULL AND `state` = 'AVAILABLE') OR (`for_identifier` = ? AND `state` = 'ACCEPTED'))
          AND `remaining` = 1
          AND `min_trust` <= ?
          AND `expires_at` > FROM_UNIXTIME(?)
    ]]

    local okFinal, resFinal = pcall(function()
        return db.query.await(finalSql, { curTime, cId, playerKey, tLevel, curTime })
    end)
    if not okFinal or not resFinal then
        return { ok = false, err = 'db_error' }
    end

    local finalAffected = (type(resFinal) == 'table' and resFinal.affectedRows) or (type(resFinal) == 'number' and resFinal) or 0
    if finalAffected == 1 then
        local updated = BrokerContracts.Get(cId)
        return {
            ok        = true,
            completed = true,
            remaining = 0,
            contract  = updated,
        }
    end

    -- 2. Tentar UPDATE NÃO-FINAL atômico (remaining > 1 -> remaining - 1)
    local nonFinalSql = [[
        UPDATE `vp_chop_broker_contracts`
        SET `remaining` = `remaining` - 1
        WHERE `id` = ?
          AND ((`for_identifier` IS NULL AND `state` = 'AVAILABLE') OR (`for_identifier` = ? AND `state` = 'ACCEPTED'))
          AND `remaining` > 1
          AND `min_trust` <= ?
          AND `expires_at` > FROM_UNIXTIME(?)
    ]]

    local okNonFinal, resNonFinal = pcall(function()
        return db.query.await(nonFinalSql, { cId, playerKey, tLevel, curTime })
    end)
    if not okNonFinal or not resNonFinal then
        return { ok = false, err = 'db_error' }
    end

    local nonFinalAffected = (type(resNonFinal) == 'table' and resNonFinal.affectedRows) or (type(resNonFinal) == 'number' and resNonFinal) or 0
    if nonFinalAffected == 1 then
        local updated = BrokerContracts.Get(cId)
        return {
            ok        = true,
            completed = false,
            remaining = updated and updated.remaining or 1,
            contract  = updated,
        }
    end

    -- 3. Diagnóstico fail-closed caso nenhum dos dois UPDATEs tenha afetado linhas
    local c = BrokerContracts.Get(cId)
    if not c then
        return { ok = false, err = 'not_found' }
    end
    if c.expiresAt and c.expiresAt <= curTime then
        return { ok = false, err = 'contract_expired' }
    end
    if c.playerKey and c.playerKey ~= playerKey then
        return { ok = false, err = 'owner_mismatch' }
    end
    if c.playerKey and c.state == 'AVAILABLE' then
        return { ok = false, err = 'contract_not_accepted' }
    end
    if c.minTrust > tLevel then
        return { ok = false, err = 'trust_gate' }
    end
    if c.remaining <= 0 or c.state == 'COMPLETED' then
        return { ok = false, err = 'contract_fulfilled' }
    end
    return { ok = false, err = 'contract_unavailable' }
end

--- Reverte a reserva atômica de quota em caso de falha a jusante (Consume race).
---@param contractId number
---@param count? number
---@param wasCompleted? boolean
---@param playerKey? string
---@return boolean success
function BrokerContracts.CompensateReservation(contractId, count, wasCompleted, playerKey)
    if not BrokerContracts.IsReady() or not contractId then return false end
    local addCount = tonumber(count) or 1
    local cId = tonumber(contractId)
    local db = getDb()

    local sql
    local params
    if wasCompleted == true then
        local restoredState = (playerKey and playerKey ~= '') and 'ACCEPTED' or 'AVAILABLE'
        sql = [[
            UPDATE `vp_chop_broker_contracts`
            SET `remaining` = `remaining` + ?,
                `state` = ?,
                `fulfilled_at` = NULL
            WHERE `id` = ?
        ]]
        params = { addCount, restoredState, cId }
    else
        sql = [[
            UPDATE `vp_chop_broker_contracts`
            SET `remaining` = `remaining` + ?
            WHERE `id` = ?
        ]]
        params = { addCount, cId }
    end

    local ok, res = pcall(function()
        return db.query.await(sql, params)
    end)
    if not ok or not res then
        print(('[vp_chopshop:contracts] CRITICAL: falha ao compensar reserva do contrato %s'):format(tostring(contractId)))
        return false
    end

    local affected = (type(res) == 'table' and res.affectedRows) or (type(res) == 'number' and res) or 0
    if affected <= 0 then
        print(('[vp_chopshop:contracts] CRITICAL: compensação do contrato %s afetou 0 linhas'):format(tostring(contractId)))
        return false
    end
    return true
end

-- ─── Seam de Testes ────────────────────────────────────────────────────────────
if GetConvar('vp_chopshop_selftest', '0') == '1' then
    BrokerContracts._test = {
        setClock = function(fn) _clock = fn end,
        setRng   = function(fn) _rng = fn end,
        setDb    = function(db)
            _db = db
            _ready = checkDbValid(db)
        end,
        setReady = function(r) _ready = r end,
        setHookBeforeConsume = function(fn) _hookBeforeConsume = fn end,
        getHookBeforeConsume = function() return _hookBeforeConsume end,
        isLocked = function(contractId) return ContractFulfillmentBusy[tonumber(contractId)] == true end,
        pickPoolItem = pickPoolItem,
        normHash32 = normHash32,
        randInt = randInt,
    }
end

dbg('módulo BrokerContracts carregado')

