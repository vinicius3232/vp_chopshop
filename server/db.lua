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
            -- fake_plate é PK (colisão de falsas rejeitada).
            -- [F2 persist] real_plate é UNIQUE: cada placa REAL tem no MÁXIMO 1 disfarce ativo.
            -- A UNIQUE evita linhas stale (bug: reaplicar falsa sobre uma real já disfarçada
            -- deixava o mapeamento antigo órfão). O INSERT da aplicação agora deleta o antigo
            -- por real_plate antes de inserir (ver VPChopDbInsertFakePlate).
            -- SEM expires_at: a falsa dura até a polícia remover (persistência total).
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chop_fake_plates` (
                    `fake_plate` VARCHAR(12) NOT NULL,
                    `real_plate` VARCHAR(12) NOT NULL,
                    `applied_by` VARCHAR(60) DEFAULT NULL,
                    `applied_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (`fake_plate`),
                    UNIQUE KEY `uq_real_plate` (`real_plate`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            -- [F2 persist] Migração de bases existentes (v1.9.0): substituir o índice não-único
            -- idx_fake_real por UNIQUE em real_plate. Purga duplicatas stale antes (mantém a mais
            -- recente por real_plate) para a UNIQUE poder ser criada sem erro. Idempotente via pcall.
            pcall(function()
                MySQL.query.await([[
                    DELETE t1 FROM `vp_chop_fake_plates` t1
                    INNER JOIN `vp_chop_fake_plates` t2
                      ON t1.real_plate = t2.real_plate
                     AND t1.applied_at < t2.applied_at
                ]])
            end)
            pcall(function() MySQL.query.await('ALTER TABLE `vp_chop_fake_plates` DROP INDEX `idx_fake_real`') end)
            pcall(function() MySQL.query.await('ALTER TABLE `vp_chop_fake_plates` ADD UNIQUE KEY `uq_real_plate` (`real_plate`)') end)
            -- [SERIAL] Registro idempotente de números de série LEGÍTIMOS de car_parts.
            -- Só séries de procedência legal entram aqui; a perícia (forensic_kit) consulta
            -- "esta série consta?". Forjadas NÃO constam → caem só na perícia.
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chop_legit_serials` (
                    `serial`     VARCHAR(16) NOT NULL,
                    `source`     VARCHAR(40) DEFAULT NULL,
                    `created_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (`serial`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            -- [v1.16 P0.4] Ledger de carcaças processadas (discard / deliverCar).
            -- A ChopSession (tombstone de discard) e o statebag vpChopDeliveredMark
            -- são in-memory / server-local → não sobrevivem a `ensure vp_chopshop`
            -- se a entidade continua no mundo. Sem este ledger, um jogador re-chopa
            -- a MESMA carcaça pós-restart e descarta de novo (2º pagamento).
            -- PK (net_id, model): uma entidade é uma coisa só. TTL (lido no lookup)
            -- porque net_id é reciclável.
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chop_carcass` (
                    `net_id`          INT UNSIGNED NOT NULL,
                    `model`           BIGINT       NOT NULL,
                    `vsid`            VARCHAR(24)  DEFAULT NULL,
                    `op`              VARCHAR(12)  NOT NULL,
                    `paid_to`         VARCHAR(60)  DEFAULT NULL,
                    `cleanup_pending` TINYINT(1)   NOT NULL DEFAULT 1,
                    `processed_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (`net_id`, `model`),
                    INDEX `idx_carcass_pending` (`cleanup_pending`, `processed_at`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ]])
            -- [v1.17 BROKER] Snapshot dinâmico de mercado do Broker.
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `vp_chop_broker_market` (
                    `commodity`     VARCHAR(64)          NOT NULL,
                    `demand_index`  DECIMAL(5, 4)        NOT NULL DEFAULT 1.0000,
                    `recent_volume` INT UNSIGNED         NOT NULL DEFAULT 0,
                    `last_recovery` TIMESTAMP            NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (`commodity`)
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
    -- [F2 persist] CORREÇÃO DO BUG DE LINHA STALE: ao aplicar uma nova falsa sobre uma placa
    -- REAL que já tinha disfarce, removemos PRIMEIRO o mapeamento antigo dessa real. Sem isso,
    -- a tabela acumulava (real, falsaAntiga) órfã + (real, falsaNova) — agora a UNIQUE em
    -- real_plate impediria o INSERT, então o DELETE prévio é obrigatório, não só limpeza.
    -- A colisão por fake_plate (PK) continua sendo a verdade atômica: se a falsa já está em
    -- uso por OUTRA real, o INSERT falha e o pcall captura → devolve false (in_use).
    -- [AUDIT-FIX C1] O padrão antigo `pcall(MySQL.query.await, sql, params)` passava o
    -- .await como referência SEM um wrapper de função → o yield/await não executava no
    -- contexto correto e o resultado era descartado (colisão de placa falsa nunca detectada).
    -- Agora: cada query roda dentro de `pcall(function() ... end)`, await sequencial no mesmo
    -- contexto de coroutine (o DELETE termina ANTES do INSERT, evitando erro espúrio de UNIQUE),
    -- e o retorno reflete o SUCESSO REAL do INSERT (affectedRows), não só "não deu exceção".

    -- DELETE prévio do disfarce antigo dessa MESMA real (await completa antes de seguir).
    pcall(function()
        MySQL.query.await('DELETE FROM vp_chop_fake_plates WHERE real_plate = ?', { realPlate })
    end)

    -- INSERT puro (sem ON DUPLICATE): se a fake_plate (PK) já existe por OUTRA real, viola a
    -- PK → o INSERT falha (insertId nil / affectedRows 0) e capturamos a colisão como false.
    local insertId
    local ok = pcall(function()
        insertId = MySQL.insert.await(
            'INSERT INTO vp_chop_fake_plates (fake_plate, real_plate, applied_by) VALUES (?, ?, ?)',
            { fakePlate, realPlate, appliedBy }
        )
    end)
    -- Sucesso real = pcall sem exceção E o INSERT produziu uma linha (insertId numérico válido).
    -- Em colisão de PK o oxmysql lança/retorna nil → ok=false ou insertId=nil → devolve false.
    return ok == true and insertId ~= nil and insertId ~= false
end

--- [F2 persist] Remove o mapeamento a partir da placa REAL (revertendo o disfarce).
--- Usado pelo hook de garagem (Frente 3) NÃO apaga — só a polícia/remoção manual.
--- Mantido como helper utilitário para administração e limpeza por real.
---@param realPlate string
function VPChopDbDeleteFakeByReal(realPlate)
    if not realPlate or realPlate == '' then return end
    MySQL.query.await('DELETE FROM vp_chop_fake_plates WHERE real_plate = ?', { realPlate })
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

--- [F2 persist][PERF] Carrega TODOS os disfarces (para o cache em memória do server/plates.lua,
--- evitando 1 query por spawn de veículo). Retorna lista de { real_plate, fake_plate }.
---@return table[]
function VPChopDbLoadAllDisguises()
    return MySQL.query.await('SELECT real_plate, fake_plate FROM vp_chop_fake_plates') or {}
end

-- ─── [SERIAL] Números de série LEGÍTIMOS de car_parts ─────────────────────────
-- A perícia da polícia consulta "esta série consta como legítima?". Só fontes legais
-- registram aqui (IssueLegalParts / vendedor). Forjadas NÃO entram → caem na perícia.

--- [SERIAL] Registra uma série como LEGÍTIMA. INSERT IGNORE: colisão de PK é no-op
--- (a série já existe = já é legítima). Não usar concatenação — sempre `?`.
---@param serial string  número de série (A-Z0-9, ≤16)
---@param source string|nil  origem ('legal_supply', 'legal_vendor', ...)
function VPChopDbRegisterLegitSerial(serial, source)
    if type(serial) ~= 'string' or serial == '' or #serial > 16 then return end
    MySQL.query.await(
        'INSERT IGNORE INTO vp_chop_legit_serials (serial, source) VALUES (?, ?)',
        { serial, source or 'legal' }
    )
end

--- [SERIAL] true se a série consta no registro de legítimas (consulta da perícia).
---@param serial string
---@return boolean
function VPChopDbIsLegitSerial(serial)
    if type(serial) ~= 'string' or serial == '' or #serial > 16 then return false end
    local exists = MySQL.scalar.await(
        'SELECT EXISTS(SELECT 1 FROM vp_chop_legit_serials WHERE serial = ?)', { serial }
    )
    return exists == 1
end

--- [AUDIT-FIX H3] Versão em LOTE de VPChopDbIsLegitSerial: recebe uma lista de séries e
--- devolve um SET (serial→true) só das que constam como legítimas. Substitui o padrão de
--- 1 query por slot na inspeção da polícia por UMA query com placeholders dinâmicos.
--- Mantém `?` (nunca concatenação): os placeholders são gerados, mas os valores vão como params.
---@param serials string[]
---@return table<string, boolean> set
function VPChopDbWhichSerialsLegit(serials)
    local set = {}
    if type(serials) ~= 'table' or #serials == 0 then return set end

    -- Dedup + filtro de validade (mesma regra dos helpers single: string não-vazia, ≤16).
    local params, seen = {}, {}
    for i = 1, #serials do
        local s = serials[i]
        if type(s) == 'string' and s ~= '' and #s <= 16 and not seen[s] then
            seen[s] = true
            params[#params + 1] = s
        end
    end
    if #params == 0 then return set end

    -- Placeholders dinâmicos: '?,?,?...' — APENAS '?', valores sempre via params (anti-SQLi).
    local marks = string.rep('?,', #params - 1) .. '?'
    local rows = MySQL.query.await(
        'SELECT serial FROM vp_chop_legit_serials WHERE serial IN (' .. marks .. ')', params
    )
    if type(rows) == 'table' then
        for i = 1, #rows do
            local serial = rows[i] and rows[i].serial
            if serial then set[serial] = true end
        end
    end
    return set
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 P0.4] Ledger de carcaças processadas — vp_chop_carcass.
--  Wired em VPChopCarcassLedger._setDb (server/session/carcass_ledger.lua).
--  Todas as funções fazem pcall: erro de DB NÃO derruba o fluxo de discard/deliver.
--  Barreira fail-OPEN por design: um blip de MySQL não deve bloquear TODO discard;
--  a dupe que isto fecha (re-discard da MESMA carcaça pós-restart de resource) é rara.
-- ═══════════════════════════════════════════════════════════════════════════════

local function carcassTtl()
    return math.floor(tonumber((Config.RestartRecovery or {}).CarcassTtlSeconds) or 1800)
end

---@return boolean ok
function VPChopDbCarcassMark(netId, model, vsid, op, paidTo, cleanupPending)
    if not VPChopDBReady then return false end
    local ok = pcall(function()
        MySQL.query.await([[
            INSERT INTO `vp_chop_carcass` (net_id, model, vsid, op, paid_to, cleanup_pending)
            VALUES (?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE vsid = VALUES(vsid), op = VALUES(op), paid_to = VALUES(paid_to),
                cleanup_pending = VALUES(cleanup_pending), processed_at = CURRENT_TIMESTAMP
        ]], { math.floor(netId), math.floor(model), vsid, op, paidTo, cleanupPending == 1 and 1 or 0 })
    end)
    return ok
end

--- Linha dentro do TTL? Fora do TTL ⇒ nil (e limpa a linha stale). Erro ⇒ nil (fail-open).
---@return { op:string, vsid:string|nil, cleanup_pending:integer, age:integer }|nil
function VPChopDbCarcassLookup(netId, model)
    if not VPChopDBReady then return nil end
    local ttl, rows = carcassTtl(), nil
    local ok = pcall(function()
        rows = MySQL.query.await([[
            SELECT vsid, op, cleanup_pending,
                   TIMESTAMPDIFF(SECOND, processed_at, CURRENT_TIMESTAMP) AS age
            FROM `vp_chop_carcass` WHERE net_id = ? AND model = ? LIMIT 1
        ]], { math.floor(netId), math.floor(model) })
    end)
    if not ok or type(rows) ~= 'table' or not rows[1] then return nil end
    local r = rows[1]
    local age = tonumber(r.age) or 0
    if age > ttl then
        pcall(function()
            MySQL.query.await('DELETE FROM `vp_chop_carcass` WHERE net_id = ? AND model = ?',
                { math.floor(netId), math.floor(model) })
        end)
        return nil
    end
    return { op = r.op, vsid = r.vsid, cleanup_pending = tonumber(r.cleanup_pending) or 0, age = age }
end

--- Remove a linha. `model` nil ⇒ remove todas as linhas do net_id (uso no entityRemoved).
---@return boolean ok
function VPChopDbCarcassClear(netId, model)
    if not VPChopDBReady then return false end
    local ok = pcall(function()
        if model == nil then
            MySQL.query.await('DELETE FROM `vp_chop_carcass` WHERE net_id = ?', { math.floor(netId) })
        else
            MySQL.query.await('DELETE FROM `vp_chop_carcass` WHERE net_id = ? AND model = ?',
                { math.floor(netId), math.floor(model) })
        end
    end)
    return ok
end

--- Carcaças com cleanup_pending=1 dentro do TTL — para o sweep de boot.
---@return table[]
function VPChopDbCarcassLoadPending()
    if not VPChopDBReady then return {} end
    local rows
    local ok = pcall(function()
        rows = MySQL.query.await([[
            SELECT net_id, model, vsid, op FROM `vp_chop_carcass`
            WHERE cleanup_pending = 1 AND TIMESTAMPDIFF(SECOND, processed_at, CURRENT_TIMESTAMP) <= ?
        ]], { carcassTtl() })
    end)
    if not ok or type(rows) ~= 'table' then return {} end
    return rows
end
