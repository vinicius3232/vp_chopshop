-- server/assembly/rebuild.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.21 P7.5 / P7.6] VEHICLE REBUILD PROJECTS & ASSEMBLY ENGINE
--  Gerenciamento de montagem de veículos sobre chassis salvage/leilão.
--  Valida compatibilidade sequencial, travas anti-dupe nas peças instaladas
--  e destruição terminal das peças físicas na homologação do veículo.
-- ═══════════════════════════════════════════════════════════════════════════════

Rebuild = Rebuild or {}

local _db = nil
local _clock = os.time
local _ready = false
local _mock = nil

local ProjectBusy = {} ---@type table<number, boolean>

local DEFAULT_REQUIRED_SLOTS = {
    'adv_engine',
    'catalytic_converter',
    'door_dside_f',
    'door_pside_f',
    'bonnet',
    'boot',
    'tyre_lf',
    'tyre_rf',
    'tyre_lr',
    'tyre_rr',
}

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

local function getPlayerKey(src)
    if type(ServerChopPlayerKey) == 'function' then
        return ServerChopPlayerKey(src)
    end
    return tostring(src)
end

local function getRequiredSlots()
    local cfg = Config and Config.Rebuild
    if cfg and type(cfg.RequiredSlots) == 'table' and #cfg.RequiredSlots > 0 then
        return cfg.RequiredSlots
    end
    return DEFAULT_REQUIRED_SLOTS
end

function Rebuild.Init(db, clockFn)
    _db = db
    if clockFn ~= nil then _clock = clockFn end
    if db == false then
        _ready = false
    else
        _ready = checkDbValid(_db or _G.MySQL)
    end
end

function Rebuild.IsReady()
    if _db == false then return false end
    return _ready == true and checkDbValid(_db or _G.MySQL)
end

--- Inicia um novo projeto de reconstrução veicular sobre um chassi salvage
---@param src number
---@param chassisModel string
---@param chassisSerial string
---@return table { ok: boolean, projectId?: number, err?: string }
function Rebuild.StartProject(src, chassisModel, chassisSerial)
    if not src or type(src) ~= 'number' or src <= 0 then
        return { ok = false, err = 'invalid_source' }
    end
    if not chassisModel or type(chassisModel) ~= 'string' or chassisModel == '' then
        return { ok = false, err = 'invalid_chassis_model' }
    end
    if not chassisSerial or type(chassisSerial) ~= 'string' or chassisSerial == '' then
        return { ok = false, err = 'invalid_chassis_serial' }
    end

    if _mock and _mock.StartProject then
        return _mock.StartProject(src, chassisModel, chassisSerial)
    end

    if not Rebuild.IsReady() then return { ok = false, err = 'db_not_ready' } end
    local db = getDb()
    local pKey = getPlayerKey(src)

    -- Verifica se já possui projeto ativo
    local active = Rebuild.GetActiveProject(src)
    if active then
        return { ok = false, err = 'project_already_in_progress', projectId = active.projectId }
    end

    local cleanModel = chassisModel:gsub('%s+', ''):lower()
    local cleanSerial = chassisSerial:gsub('%s+', ''):upper()

    local insertId = db.insert.await([[
        INSERT INTO `vp_chop_rebuild_projects` (
            `owner_key`, `chassis_model`, `chassis_serial`, `status`, `installed_parts`
        ) VALUES (?, ?, ?, 'in_progress', '{}')
    ]], { pKey, cleanModel, cleanSerial })

    if not insertId or insertId == 0 then
        return { ok = false, err = 'insert_failed' }
    end

    return {
        ok            = true,
        projectId     = insertId,
        ownerKey      = pKey,
        chassisModel  = cleanModel,
        chassisSerial = cleanSerial,
    }
end

--- Busca o projeto ativo em andamento do jogador
---@param src number
---@return table? project
function Rebuild.GetActiveProject(src)
    if not src then return nil end

    if _mock and _mock.GetActiveProject then
        return _mock.GetActiveProject(src)
    end

    if not Rebuild.IsReady() then return nil end
    local db = getDb()
    local pKey = getPlayerKey(src)

    local row = db.single.await([[
        SELECT `project_id`, `owner_key`, `chassis_model`, `chassis_serial`, `status`, `installed_parts`,
               UNIX_TIMESTAMP(`created_at`) AS `created_at_ts`
        FROM `vp_chop_rebuild_projects`
        WHERE `owner_key` = ? AND `status` = 'in_progress'
        LIMIT 1
    ]], { pKey })

    if not row then return nil end

    local okParts, parts = pcall(json.decode, row.installed_parts)
    parts = (okParts and type(parts) == 'table') and parts or {}

    return {
        projectId      = row.project_id,
        ownerKey       = row.owner_key,
        chassisModel   = row.chassis_model,
        chassisSerial  = row.chassis_serial,
        status         = row.status,
        installedParts = parts,
        createdAt      = tonumber(row.created_at_ts) or 0,
    }
end

--- Instala e acopla uma peça física no projeto
---@param projectId number
---@param src number
---@param slot string
---@param partId string
---@return table { ok: boolean, err?: string, slot?: string, partId?: string }
function Rebuild.InstallPart(projectId, src, slot, partId)
    projectId = tonumber(projectId)
    if not projectId or not src or not slot or not partId then
        return { ok = false, err = 'invalid_params' }
    end

    if ProjectBusy[projectId] then
        return { ok = false, err = 'project_busy' }
    end
    ProjectBusy[projectId] = true
    local function release(res)
        ProjectBusy[projectId] = nil
        return res
    end

    if _mock and _mock.InstallPart then
        return release(_mock.InstallPart(projectId, src, slot, partId))
    end

    if not Rebuild.IsReady() then return release({ ok = false, err = 'db_not_ready' }) end
    local db = getDb()
    local pKey = getPlayerKey(src)

    -- Valida projeto
    local project = Rebuild.GetActiveProject(src)
    if not project or project.projectId ~= projectId then
        return release({ ok = false, err = 'project_not_found_or_not_owned' })
    end

    -- Valida slot
    if project.installedParts[slot] then
        return release({ ok = false, err = 'slot_already_occupied' })
    end

    -- Valida peça física
    local PP = rawget(_G, 'PhysicalPart')
    if not PP or not PP.Get then
        return release({ ok = false, err = 'physical_part_bridge_missing' })
    end

    local part = PP.Get(partId)
    if not part then
        return release({ ok = false, err = 'physical_part_not_found' })
    end

    -- Valida propriedade
    if part.ownerKey and part.ownerKey ~= '' and part.ownerKey ~= pKey then
        return release({ ok = false, err = 'not_part_owner' })
    end

    -- Valida se já não está presa em outro veículo/projeto
    if part.installedVehicleId and part.installedVehicleId ~= 0 and part.installedVehicleId ~= false then
        return release({ ok = false, err = 'part_already_installed_in_vehicle' })
    end

    -- Valida saúde mínima
    local cfg = Config and Config.Rebuild
    local minCond = (slot == 'adv_engine' or slot == 'engine')
        and (cfg and cfg.MinEngineCondition or 70.0)
        or (cfg and cfg.MinComponentCondition or 50.0)

    if (part.conditionPct or 0) < minCond then
        return release({ ok = false, err = 'insufficient_condition', minRequired = minCond, actual = part.conditionPct })
    end

    -- Valida compatibilidade mecânica (P7.2)
    local Compat = rawget(_G, 'PartCompatibility')
    if Compat and Compat.CanFit then
        local canFit, reason = Compat.CanFit(part.partType, part, project.chassisModel, nil)
        if not canFit then
            return release({ ok = false, err = 'incompatible_part', reason = reason })
        end
    end

    -- Trava física da peça com installed_vehicle_id
    local locked = PP.UpdateState(partId, { installedVehicleId = projectId })
    if not locked then
        return release({ ok = false, err = 'failed_to_lock_part' })
    end

    -- Registra peça no projeto
    project.installedParts[slot] = {
        partId       = partId,
        partType     = part.partType,
        serial       = part.serial,
        conditionPct = part.conditionPct,
        legalState   = part.legalState,
    }

    db.update.await('UPDATE `vp_chop_rebuild_projects` SET `installed_parts` = ? WHERE `project_id` = ?', {
        json.encode(project.installedParts), projectId
    })

    return release({
        ok     = true,
        slot   = slot,
        partId = partId,
    })
end

--- Remove uma peça instalada do projeto de volta ao inventário/mundo
---@param projectId number
---@param src number
---@param slot string
---@return table { ok: boolean, err?: string, removedPartId?: string }
function Rebuild.RemovePart(projectId, src, slot)
    projectId = tonumber(projectId)
    if not projectId or not src or not slot then
        return { ok = false, err = 'invalid_params' }
    end

    if ProjectBusy[projectId] then
        return { ok = false, err = 'project_busy' }
    end
    ProjectBusy[projectId] = true
    local function release(res)
        ProjectBusy[projectId] = nil
        return res
    end

    if _mock and _mock.RemovePart then
        return release(_mock.RemovePart(projectId, src, slot))
    end

    if not Rebuild.IsReady() then return release({ ok = false, err = 'db_not_ready' }) end
    local db = getDb()

    local project = Rebuild.GetActiveProject(src)
    if not project or project.projectId ~= projectId then
        return release({ ok = false, err = 'project_not_found_or_not_owned' })
    end

    local installed = project.installedParts[slot]
    if not installed or not installed.partId then
        return release({ ok = false, err = 'slot_is_empty' })
    end

    local partId = installed.partId

    -- Destrava a peça no PhysicalPart
    local PP = rawget(_G, 'PhysicalPart')
    if PP and PP.UpdateState then
        PP.UpdateState(partId, { installedVehicleId = false })
    end

    project.installedParts[slot] = nil

    db.update.await('UPDATE `vp_chop_rebuild_projects` SET `installed_parts` = ? WHERE `project_id` = ?', {
        json.encode(project.installedParts), projectId
    })

    return release({
        ok            = true,
        slot          = slot,
        removedPartId = partId,
    })
end

--- Finaliza a montagem sequencial completa com destruição terminal das peças físicas (Anti-Dupe)
---@param projectId number
---@param src number
---@return table { ok: boolean, completed?: boolean, err?: string, vehicle?: table }
function Rebuild.FinalizeAssembly(projectId, src)
    projectId = tonumber(projectId)
    if not projectId or not src then
        return { ok = false, err = 'invalid_params' }
    end

    if ProjectBusy[projectId] then
        return { ok = false, err = 'project_busy' }
    end
    ProjectBusy[projectId] = true
    local function release(res)
        ProjectBusy[projectId] = nil
        return res
    end

    if _mock and _mock.FinalizeAssembly then
        return release(_mock.FinalizeAssembly(projectId, src))
    end

    if not Rebuild.IsReady() then return release({ ok = false, err = 'db_not_ready' }) end
    local db = getDb()

    local project = Rebuild.GetActiveProject(src)
    if not project or project.projectId ~= projectId then
        return release({ ok = false, err = 'project_not_found_or_not_owned' })
    end

    -- Checklist obrigatório de componentes
    local requiredSlots = getRequiredSlots()
    local missing = {}
    for _, slot in ipairs(requiredSlots) do
        if not project.installedParts[slot] then
            table.insert(missing, slot)
        end
    end

    if #missing > 0 then
        return release({
            ok      = false,
            err     = 'missing_required_components',
            missing = missing,
        })
    end

    -- Transição atômica do projeto para 'completed'
    local affected = db.update.await([[
        UPDATE `vp_chop_rebuild_projects`
        SET `status` = 'completed', `completed_at` = NOW()
        WHERE `project_id` = ? AND `status` = 'in_progress'
    ]], { projectId })

    if affected ~= 1 then
        return release({ ok = false, err = 'project_already_completed_or_race' })
    end

    -- INVARIANTE ANTI-DUPE TERMINAL:
    -- Destruição atômica de todas as peças físicas vinculadas
    local PP = rawget(_G, 'PhysicalPart')
    if PP and PP.Consume then
        for slot, partInfo in pairs(project.installedParts) do
            if partInfo and partInfo.partId then
                PP.Consume(partInfo.partId, 'rebuild_assembly_' .. tostring(projectId))
            end
        end
    end

    -- Aciona o Renascimento Civil de VIN (P7.7)
    local Rebirth = rawget(_G, 'VINRebirth')
    local rebirthRes = nil
    if Rebirth and Rebirth.RegisterVehicle then
        rebirthRes = Rebirth.RegisterVehicle(src, project)
    end

    return release({
        ok        = true,
        completed = true,
        projectId = projectId,
        vehicle   = rebirthRes,
    })
end

function Rebuild.__setMock(mock)
    _mock = mock
end

return Rebuild
