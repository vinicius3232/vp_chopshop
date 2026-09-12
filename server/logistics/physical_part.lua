-- server/logistics/physical_part.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.19 P5.4] PERSISTENT PHYSICAL PART & PROVENANCE V2
--  Gerencia o ciclo de vida, persistência e proveniência de peças físicas duráveis
--  (motores, painéis, catalisadores) no banco de dados.
-- ═══════════════════════════════════════════════════════════════════════════════

PhysicalPart = {}

local _db = nil
local _clock = os.time
local _ready = false

local VALID_LEGAL_STATES = {
    stolen      = true,
    scratched   = true,
    forged      = true,
    refurbished = true,
    legal       = true,
}

local function dbg(...)
    if Config and Config.Broker and Config.Broker.Workshop and Config.Broker.Workshop.Debug then
        print('[vp_chopshop:physical_part]', ...)
    end
end

local function getNow()
    return _clock and _clock() or os.time()
end

local function getDb()
    if _db then return _db end
    return _G.MySQL
end

local function checkDbValid(db)
    return db ~= nil
        and db ~= false
        and type(db) == 'table'
        and type(db.query) == 'table'
        and type(db.query.await) == 'function'
end

function PhysicalPart.Init(db, clockFn)
    if db ~= nil then _db = db end
    if clockFn ~= nil then _clock = clockFn end
    _ready = checkDbValid(_db or _G.MySQL)
    dbg('PhysicalPart inicializado, ready =', _ready)
end

function PhysicalPart.IsReady()
    return _ready == true and checkDbValid(_db or _G.MySQL)
end

local function generatePartId()
    local t = getNow()
    local r1 = math.random(100000, 999999)
    local r2 = math.random(100000, 999999)
    return ('part_%x_%x_%x'):format(t, r1, r2)
end

--- Cria e persiste uma nova peça física durável no banco de dados
---@param params table { partType:string, serial?:string, sourceVsid?:string, sourceModel:string, vehicleClass?:number, conditionPct?:number, qualityTier?:number, legalState?:string, ownerKey?:string, benchId?:number }
---@return { ok: boolean, part?: table, err?: string }
function PhysicalPart.Create(params)
    if not PhysicalPart.IsReady() then return { ok = false, err = 'db_not_ready' } end
    if type(params) ~= 'table' then return { ok = false, err = 'invalid_params' } end

    local partType = params.partType or params.partKey
    if not partType or type(partType) ~= 'string' or partType == '' then
        return { ok = false, err = 'invalid_part_type' }
    end

    local sourceModel = params.sourceModel or 'unknown'
    local vehicleClass = math.max(0, math.min(22, math.floor(tonumber(params.vehicleClass) or 0)))
    local conditionPct = math.max(0.0, math.min(100.0, tonumber(params.conditionPct) or 100.0))
    local qualityTier = math.max(1, math.min(5, math.floor(tonumber(params.qualityTier) or 1)))
    local legalState = params.legalState or 'stolen'
    if not VALID_LEGAL_STATES[legalState] then
        legalState = 'stolen'
    end

    local partId = generatePartId()
    local serial = params.serial and tostring(params.serial) or nil
    local sourceVsid = params.sourceVsid and tostring(params.sourceVsid) or nil
    local ownerKey = params.ownerKey and tostring(params.ownerKey) or nil
    local benchId = tonumber(params.benchId) or nil

    local db = getDb()
    local insertSql = [[
        INSERT INTO `vp_chop_physical_parts` (
            `part_id`, `part_type`, `serial`, `source_vsid`, `source_model`,
            `vehicle_class`, `condition_pct`, `quality_tier`, `legal_state`,
            `owner_key`, `bench_id`
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]

    local okIns, resIns = pcall(function()
        return db.query.await(insertSql, {
            partId, partType, serial, sourceVsid, sourceModel,
            vehicleClass, conditionPct, qualityTier, legalState,
            ownerKey, benchId
        })
    end)

    if not okIns or not resIns then
        return { ok = false, err = 'db_insert_failed' }
    end

    local record = {
        partId       = partId,
        partType     = partType,
        serial       = serial,
        sourceVsid   = sourceVsid,
        sourceModel  = sourceModel,
        vehicleClass = vehicleClass,
        conditionPct = conditionPct,
        qualityTier  = qualityTier,
        legalState   = legalState,
        ownerKey     = ownerKey,
        benchId      = benchId,
    }

    dbg('Peça física criada com sucesso:', partId, 'tipo:', partType, 'serial:', serial)
    return { ok = true, part = record }
end

--- Carrega os dados de uma peça física durável pelo ID
---@param partId string
---@return table|nil
function PhysicalPart.Get(partId)
    if not PhysicalPart.IsReady() or not partId or partId == '' then return nil end
    local db = getDb()
    local sql = "SELECT * FROM `vp_chop_physical_parts` WHERE `part_id` = ?"
    local ok, rows = pcall(function() return db.query.await(sql, { partId }) end)
    if not ok or not rows or not rows[1] then return nil end
    local r = rows[1]
    return {
        partId       = r.part_id,
        partType     = r.part_type,
        serial       = r.serial,
        sourceVsid   = r.source_vsid,
        sourceModel  = r.source_model,
        vehicleClass = tonumber(r.vehicle_class) or 0,
        conditionPct = tonumber(r.condition_pct) or 100.0,
        qualityTier  = tonumber(r.quality_tier) or 1,
        legalState   = r.legal_state,
        ownerKey     = r.owner_key,
        benchId      = tonumber(r.bench_id),
    }
end

--- Vincula uma peça física a uma bancada
---@param partId string
---@param benchId number
---@param ownerKey? string
---@return boolean ok, string? err
function PhysicalPart.PlaceOnBench(partId, benchId, ownerKey)
    if not PhysicalPart.IsReady() or not partId or not benchId then return false, 'invalid_args' end
    local db = getDb()
    local sql = "UPDATE `vp_chop_physical_parts` SET `bench_id` = ?, `owner_key` = ? WHERE `part_id` = ?"
    local ok, res = pcall(function() return db.query.await(sql, { benchId, ownerKey, partId }) end)
    local aff = (type(res) == 'table' and res.affectedRows) or (type(res) == 'number' and res) or 0
    return (ok and aff == 1), (not ok and 'db_error' or nil)
end

--- Desvincula a peça de uma bancada (jogador recolheu)
---@param benchId number
---@param ownerKey? string
---@return boolean ok, string? err
function PhysicalPart.TakeFromBench(benchId, ownerKey)
    if not PhysicalPart.IsReady() or not benchId then return false, 'invalid_args' end
    local db = getDb()
    local sql = "UPDATE `vp_chop_physical_parts` SET `bench_id` = NULL WHERE `bench_id` = ?"
    local params = { benchId }
    if ownerKey and ownerKey ~= '' then
        sql = sql .. " AND (`owner_key` IS NULL OR `owner_key` = ?)"
        params[#params + 1] = ownerKey
    end
    local ok, res = pcall(function() return db.query.await(sql, params) end)
    local aff = (type(res) == 'table' and res.affectedRows) or (type(res) == 'number' and res) or 0
    return (ok and aff >= 1), (not ok and 'db_error' or nil)
end

--- Atualiza estado e integridade de uma peça
---@param partId string
---@param updates table { conditionPct?:number, legalState?:string, serial?:string, installedVehicleId?:number }
---@return boolean ok, string? err
function PhysicalPart.UpdateState(partId, updates)
    if not PhysicalPart.IsReady() or not partId or type(updates) ~= 'table' then return false, 'invalid_args' end
    local db = getDb()
    local sets = {}
    local params = {}

    if updates.conditionPct ~= nil then
        sets[#sets + 1] = "`condition_pct` = ?"
        params[#params + 1] = math.max(0.0, math.min(100.0, tonumber(updates.conditionPct) or 100.0))
    end
    if updates.legalState ~= nil and VALID_LEGAL_STATES[updates.legalState] then
        sets[#sets + 1] = "`legal_state` = ?"
        params[#params + 1] = updates.legalState
    end
    if updates.serial ~= nil then
        sets[#sets + 1] = "`serial` = ?"
        params[#params + 1] = updates.serial
    end
    if updates.installedVehicleId ~= nil then
        sets[#sets + 1] = "`installed_vehicle_id` = ?"
        params[#params + 1] = tonumber(updates.installedVehicleId)
    end

    if #sets == 0 then return true end

    local sql = "UPDATE `vp_chop_physical_parts` SET " .. table.concat(sets, ", ") .. " WHERE `part_id` = ?"
    params[#params + 1] = partId

    local ok, res = pcall(function() return db.query.await(sql, params) end)
    local aff = (type(res) == 'table' and res.affectedRows) or (type(res) == 'number' and res) or 0
    return (ok and aff == 1), (not ok and 'db_error' or nil)
end

--- Consome terminalmente a peça (venda definitiva ou destruição)
---@param partId string
---@param reason? string
---@return boolean ok, string? err
function PhysicalPart.Consume(partId, reason)
    if not PhysicalPart.IsReady() or not partId or partId == '' then return false, 'invalid_args' end
    local db = getDb()
    local sql = "DELETE FROM `vp_chop_physical_parts` WHERE `part_id` = ?"
    local ok, res = pcall(function() return db.query.await(sql, { partId }) end)
    local aff = (type(res) == 'table' and res.affectedRows) or (type(res) == 'number' and res) or 0
    dbg('Peça física consumida/destruída:', partId, 'motivo:', reason, 'affected:', aff)
    return (ok and aff == 1), (not ok and 'db_error' or nil)
end

--- Carrega todas as peças que estão salvas descansando sobre bancadas
---@return table[]
function PhysicalPart.LoadBenchParts()
    if not PhysicalPart.IsReady() then return {} end
    local db = getDb()
    local sql = "SELECT * FROM `vp_chop_physical_parts` WHERE `bench_id` IS NOT NULL"
    local ok, rows = pcall(function() return db.query.await(sql, {}) end)
    if not ok or not rows or type(rows) ~= 'table' then return {} end

    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            partId       = r.part_id,
            partType     = r.part_type,
            serial       = r.serial,
            sourceVsid   = r.source_vsid,
            sourceModel  = r.source_model,
            vehicleClass = tonumber(r.vehicle_class) or 0,
            conditionPct = tonumber(r.condition_pct) or 100.0,
            qualityTier  = tonumber(r.quality_tier) or 1,
            legalState   = r.legal_state,
            ownerKey     = r.owner_key,
            benchId      = tonumber(r.bench_id),
        }
    end
    return out
end

return PhysicalPart
