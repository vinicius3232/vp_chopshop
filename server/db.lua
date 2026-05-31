VPChopDBReady = false

local function decodePos(raw)
    if not raw or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then return nil end
    local x, y, z = data.x, data.y, data.z
    if not x or not y or not z then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function encodePos(coords)
    return json.encode({ x = coords.x, y = coords.y, z = coords.z })
end

function VPChopDbInit()
    -- [FIX C-01] MySQL.ready() NÃO é uma coroutine — MySQL.query.await() dentro dela
    -- precisa de CreateThread para ter contexto de yield. Sem isso o await fica preso
    -- ou falha silenciosamente dependendo da versão do oxmysql.
    -- [REMOVED] vp_chopshop_lifts: elevador removido do sistema — apenas macaco (jackstand) é necessário.
    MySQL.ready(function()
        CreateThread(function()
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chopshop_benches` (
                    `id`        INT UNSIGNED      NOT NULL AUTO_INCREMENT,
                    `position`  TEXT              NOT NULL,
                    `heading`   SMALLINT UNSIGNED NOT NULL DEFAULT 0,
                    `placed_by` VARCHAR(60)       DEFAULT NULL,
                    PRIMARY KEY (`id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chopshop_welders` (
                    `id`        INT UNSIGNED      NOT NULL AUTO_INCREMENT,
                    `position`  TEXT              NOT NULL,
                    `heading`   SMALLINT UNSIGNED NOT NULL DEFAULT 0,
                    `placed_by` VARCHAR(60)       DEFAULT NULL,
                    PRIMARY KEY (`id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            -- Tabelas RP (heat, fence, progression)
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS vp_chop_vin_scratched (
                    plate        VARCHAR(12) PRIMARY KEY,
                    scratched_by VARCHAR(60),
                    scratched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chop_fence_trust` (
                    `identifier`  VARCHAR(60)        NOT NULL,
                    `trust_level` TINYINT UNSIGNED   NOT NULL DEFAULT 0,
                    `trust_xp`    MEDIUMINT UNSIGNED NOT NULL DEFAULT 0,
                    `last_seen`   TIMESTAMP          NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (`identifier`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chop_fence_orders` (
                    `id`             INT UNSIGNED NOT NULL AUTO_INCREMENT,
                    `for_identifier` VARCHAR(60)  NOT NULL,
                    `order_data`     TEXT         NOT NULL,
                    `created_at`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    `fulfilled_at`   TIMESTAMP    NULL     DEFAULT NULL,
                    PRIMARY KEY (`id`),
                    INDEX `idx_orders_active` (`for_identifier`, `fulfilled_at`, `created_at`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chop_progression` (
                    `identifier`        VARCHAR(60)        NOT NULL,
                    `tier`              TINYINT UNSIGNED   NOT NULL DEFAULT 1,
                    `xp`                MEDIUMINT UNSIGNED NOT NULL DEFAULT 0,
                    `total_chops`       MEDIUMINT UNSIGNED NOT NULL DEFAULT 0,
                    `last_car_delivery` TIMESTAMP          NULL     DEFAULT NULL,
                    `updated_at`        TIMESTAMP          NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                    PRIMARY KEY (`identifier`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            -- [FASE2 placas] Mapa placa FALSA → placa REAL (disfarce de consulta MDT).
            -- fake_plate é PK (colisão de falsas rejeitada); índice em real_plate p/ resolver inverso.
            -- SEM expires_at: a falsa dura até guardar o carro ou a polícia remover.
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chop_fake_plates` (
                    `fake_plate` VARCHAR(12) NOT NULL,
                    `real_plate` VARCHAR(12) NOT NULL,
                    `applied_by` VARCHAR(60) DEFAULT NULL,
                    `applied_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (`fake_plate`),
                    INDEX `idx_fake_real` (`real_plate`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            VPChopDBReady = true
            TriggerEvent('vp_chopshop:server:dbReady')
        end)
    end)
end

VPChopDbInit()

---@return table[]
function VPChopDbLoadBenches()
    local rows = MySQL.query.await('SELECT id, position, heading, placed_by FROM vp_chopshop_benches') or {}
    local out = {}
    for _, row in ipairs(rows) do
        local pos = decodePos(row.position)
        if pos then
            out[#out + 1] = {
                id = row.id,
                coords = pos,
                heading = tonumber(row.heading) or 0.0,
                placed_by = row.placed_by,
            }
        end
    end
    return out
end

---@param coords vector3
---@param heading number
---@param placedBy string|nil
---@return integer|nil id
function VPChopDbInsertBench(coords, heading, placedBy)
    local posJson = encodePos(coords)
    local id = MySQL.insert.await(
        'INSERT INTO vp_chopshop_benches (position, heading, placed_by) VALUES (?, ?, ?)',
        { posJson, math.floor(heading + 0.5), placedBy }
    )
    return id
end

---@param id integer
function VPChopDbDeleteBench(id)
    -- [FIX C-02] Mesmo motivo acima.
    MySQL.query.await('DELETE FROM vp_chopshop_benches WHERE id = ?', { id })
end

---@return table[]
function VPChopDbLoadWelders()
    local rows = MySQL.query.await('SELECT id, position, heading, placed_by FROM vp_chopshop_welders') or {}
    local out = {}
    for _, row in ipairs(rows) do
        local pos = decodePos(row.position)
        if pos then
            out[#out + 1] = {
                id = row.id,
                coords = pos,
                heading = tonumber(row.heading) or 0.0,
                placed_by = row.placed_by,
            }
        end
    end
    return out
end

---@param coords vector3
---@param heading number
---@param placedBy string|nil
---@return integer|nil id
function VPChopDbInsertWelder(coords, heading, placedBy)
    local posJson = encodePos(coords)
    local id = MySQL.insert.await(
        'INSERT INTO vp_chopshop_welders (position, heading, placed_by) VALUES (?, ?, ?)',
        { posJson, math.floor(heading + 0.5), placedBy }
    )
    return id
end

---@param id integer
function VPChopDbDeleteWelder(id)
    -- [FIX C-02] Mesmo motivo acima.
    MySQL.query.await('DELETE FROM vp_chopshop_welders WHERE id = ?', { id })
end

-- ─── [FASE2 placas] Mapa placa falsa → real ──────────────────────────────────

--- Insere o mapeamento falsa→real. Retorna false se a placa falsa já estiver em uso
--- (colisão de PK) ou em qualquer falha de DB. Atômico: o INSERT é a checagem de colisão.
---@param fakePlate string
---@param realPlate string
---@param appliedBy string|nil
---@return boolean ok
function VPChopDbInsertFakePlate(fakePlate, realPlate, appliedBy)
    -- INSERT puro (sem ON DUPLICATE): se a fake_plate já existe, a PK viola e o pcall captura.
    local ok = pcall(MySQL.query.await,
        'INSERT INTO vp_chop_fake_plates (fake_plate, real_plate, applied_by) VALUES (?, ?, ?)',
        { fakePlate, realPlate, appliedBy }
    )
    return ok == true
end

--- Resolve a placa REAL a partir de uma placa VISÍVEL (que pode ser falsa).
--- Se a visível não estiver mapeada, devolve a própria visível (era a real).
---@param visiblePlate string
---@return string realPlate
function VPChopDbResolveRealPlate(visiblePlate)
    if not visiblePlate or visiblePlate == '' then return visiblePlate end
    local real = MySQL.scalar.await(
        'SELECT real_plate FROM vp_chop_fake_plates WHERE fake_plate = ?', { visiblePlate }
    )
    return real or visiblePlate
end

--- Busca a placa real mapeada por uma falsa específica. nil se não houver mapeamento.
---@param fakePlate string
---@return string|nil realPlate
function VPChopDbGetRealByFake(fakePlate)
    if not fakePlate or fakePlate == '' then return nil end
    return MySQL.scalar.await(
        'SELECT real_plate FROM vp_chop_fake_plates WHERE fake_plate = ?', { fakePlate }
    )
end

--- Busca a placa FALSA exibida a partir da placa REAL (resolução inversa, para re-sync).
--- nil se não houver disfarce ativo para essa placa real.
---@param realPlate string
---@return string|nil fakePlate
function VPChopDbGetFakeByReal(realPlate)
    if not realPlate or realPlate == '' then return nil end
    return MySQL.scalar.await(
        'SELECT fake_plate FROM vp_chop_fake_plates WHERE real_plate = ? LIMIT 1', { realPlate }
    )
end

--- Remove o mapeamento de uma placa falsa (revertendo o disfarce).
---@param fakePlate string
function VPChopDbDeleteFakePlate(fakePlate)
    if not fakePlate or fakePlate == '' then return end
    MySQL.query.await('DELETE FROM vp_chop_fake_plates WHERE fake_plate = ?', { fakePlate })
end

--- true se a placa falsa já estiver em uso (colisão potencial antes do INSERT).
---@param fakePlate string
---@return boolean
function VPChopDbFakePlateInUse(fakePlate)
    if not fakePlate or fakePlate == '' then return false end
    local exists = MySQL.scalar.await(
        'SELECT EXISTS(SELECT 1 FROM vp_chop_fake_plates WHERE fake_plate = ?)', { fakePlate }
    )
    return exists == 1
end
