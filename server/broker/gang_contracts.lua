-- server/broker/gang_contracts.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.20 P6.4] GANG COOPERATIVE CONTRACTS DOMAIN
--  Gerencia contratos cooperativos de alto escalão para facções criminosas.
--  Exige cooperação de esquadrão, validação de peças físicas duráveis (P5.4)
--  e rateio de lucros 100% server-authoritative entre os participantes.
-- ═══════════════════════════════════════════════════════════════════════════════

GangContracts = {}

local _db = nil
local _clock = os.time
local _ready = false
local _mock = nil

local ContractBusy = {} ---@type table<number, boolean>

local function dbg(...)
    if Config and Config.Gangs and Config.Gangs.Debug then
        print('[vp_chopshop:gang_contracts]', ...)
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

local function toArray(tbl)
    if type(tbl) ~= 'table' then return {} end
    local arr = {}
    if tbl[1] ~= nil then
        for i = 1, #tbl do
            table.insert(arr, tbl[i])
        end
        return arr
    end
    local sortedKeys = {}
    for k, _ in pairs(tbl) do
        local n = tonumber(k)
        if n then
            table.insert(sortedKeys, { key = k, num = n })
        end
    end
    if #sortedKeys > 0 then
        table.sort(sortedKeys, function(a, b) return a.num < b.num end)
        for _, item in ipairs(sortedKeys) do
            table.insert(arr, tbl[item.key])
        end
        return arr
    end
    for _, v in pairs(tbl) do
        table.insert(arr, v)
    end
    return arr
end

function GangContracts.Init(db, clockFn)
    if db ~= nil then _db = db end
    if clockFn ~= nil then _clock = clockFn end
    _ready = checkDbValid(_db or _G.MySQL)
    dbg('GangContracts inicializado, ready =', _ready)
end

function GangContracts.IsReady()
    return _ready == true and checkDbValid(_db or _G.MySQL)
end

--- Divisão de lucros proporcional e matematicamente estrita (server-authoritative).
--- Garante que a soma das frações seja EXATAMENTE igual ao totalReward (zero centavos criados ou perdidos).
---@param totalReward number
---@param participants table[] { src: number, citizenid: string, contribution: number, name?: string }
---@return table<string, table> shares por citizenid { src: number, amount: number, contribution: number }
function GangContracts.DistributePayout(totalReward, participants)
    totalReward = math.floor(tonumber(totalReward) or 0)
    if totalReward <= 0 or type(participants) ~= 'table' or #participants == 0 then
        return {}
    end

    local totalContrib = 0
    for _, p in ipairs(participants) do
        totalContrib = totalContrib + math.max(0, tonumber(p.contribution) or 0)
    end

    local count = #participants
    local shares = {}
    local allocated = 0
    local maxContribIdx = 1
    local maxContribVal = -1

    for i, p in ipairs(participants) do
        local cid = p.citizenid or tostring(p.src)
        local contrib = math.max(0, tonumber(p.contribution) or 0)
        local share = 0

        if totalContrib > 0 then
            share = math.floor(totalReward * (contrib / totalContrib))
        else
            -- Divisão igualitária quando não há pontuação de contribuição
            share = math.floor(totalReward / count)
        end

        allocated = allocated + share
        shares[cid] = {
            src = p.src,
            citizenid = cid,
            name = p.name or ('Membro ' .. tostring(i)),
            contribution = contrib,
            amount = share,
        }

        if contrib > maxContribVal then
            maxContribVal = contrib
            maxContribIdx = i
        end
    end

    -- Distribui o resto do arredondamento para o maior contribuidor (ou primeiro membro)
    local remainder = totalReward - allocated
    if remainder > 0 and participants[maxContribIdx] then
        local topCid = participants[maxContribIdx].citizenid or tostring(participants[maxContribIdx].src)
        if shares[topCid] then
            shares[topCid].amount = shares[topCid].amount + remainder
        end
    end

    return shares
end

--- Cria um novo contrato cooperativo para uma gangue
---@param gangId string
---@param contractType string
---@param requirements table[] { part_type: string, required: number, min_condition?: number }
---@param totalReward number
---@param durationSeconds number
---@return table { ok: boolean, contractId?: number, err?: string }
function GangContracts.CreateContract(gangId, contractType, requirements, totalReward, durationSeconds)
    if not gangId or type(gangId) ~= 'string' or gangId == '' then
        return { ok = false, err = 'invalid_gang_id' }
    end
    if not requirements or type(requirements) ~= 'table' or #requirements == 0 then
        return { ok = false, err = 'invalid_requirements' }
    end
    totalReward = math.floor(tonumber(totalReward) or 0)
    if totalReward <= 0 then
        return { ok = false, err = 'invalid_reward' }
    end

    durationSeconds = tonumber(durationSeconds) or 86400
    local now = getNow()
    local expiresAt = now + durationSeconds

    -- Sanitiza os requisitos com delivered = 0
    local sanitizedReqs = {}
    for _, req in ipairs(requirements) do
        table.insert(sanitizedReqs, {
            part_type     = req.part_type or 'car_parts',
            required      = math.max(1, tonumber(req.required) or 1),
            delivered     = 0,
            min_condition = tonumber(req.min_condition) or 0,
        })
    end

    if _mock and _mock.CreateContract then
        return _mock.CreateContract(gangId, contractType, sanitizedReqs, totalReward, durationSeconds)
    end

    if not GangContracts.IsReady() then
        return { ok = false, err = 'db_not_ready' }
    end

    local db = getDb()
    local reqJson = json.encode(sanitizedReqs)
    local partJson = json.encode({})

    local insertId = db.insert.await(
        'INSERT INTO vp_chop_gang_contracts (gang_id, contract_type, status, requirements, total_reward, participants, expires_at) ' ..
        'VALUES (?, ?, "active", ?, ?, ?, FROM_UNIXTIME(?))',
        { gangId, contractType or 'cooperative', reqJson, totalReward, partJson, expiresAt }
    )

    if not insertId or insertId == 0 then
        return { ok = false, err = 'insert_failed' }
    end

    return {
        ok         = true,
        contractId = insertId,
        gangId     = gangId,
        totalReward = totalReward,
        expiresAt  = expiresAt,
    }
end

--- Busca o contrato cooperativo ativo de uma facção
---@param gangId string
---@return table|nil contract, string? err
function GangContracts.GetActiveContract(gangId)
    if not gangId or gangId == '' then return nil, 'invalid_gang' end

    if _mock and _mock.GetActiveContract then
        return _mock.GetActiveContract(gangId)
    end

    if not GangContracts.IsReady() then return nil, 'db_not_ready' end
    local db = getDb()

    local row = db.single.await(
        'SELECT id, gang_id, contract_type, status, requirements, total_reward, participants, ' ..
        'UNIX_TIMESTAMP(expires_at) AS expires_at_ts, UNIX_TIMESTAMP(created_at) AS created_at_ts ' ..
        'FROM vp_chop_gang_contracts WHERE gang_id = ? AND status = "active" ORDER BY id DESC LIMIT 1',
        { gangId }
    )

    if not row then return nil end

    local now = getNow()
    if row.expires_at_ts and now >= tonumber(row.expires_at_ts) then
        -- Expirado: marcar status
        db.update.await('UPDATE vp_chop_gang_contracts SET status = "expired" WHERE id = ?', { row.id })
        return nil, 'contract_expired'
    end

    local okReq, reqs = pcall(json.decode, row.requirements)
    local okPart, parts = pcall(json.decode, row.participants)

    return {
        id           = row.id,
        gangId       = row.gang_id,
        contractType = row.contract_type,
        status       = row.status,
        requirements = (okReq and type(reqs) == 'table') and toArray(reqs) or {},
        totalReward  = tonumber(row.total_reward) or 0,
        participants = (okPart and type(parts) == 'table') and toArray(parts) or {},
        expiresAt    = tonumber(row.expires_at_ts) or 0,
        createdAt    = tonumber(row.created_at_ts) or 0,
    }
end

--- Registra um membro da facção no esquadrão do contrato cooperativo
---@param contractId number
---@param src number
---@param citizenid string
---@param name? string
---@return table { ok: boolean, err?: string }
function GangContracts.RegisterParticipant(contractId, src, citizenid, name)
    if not contractId or not src or not citizenid then
        return { ok = false, err = 'invalid_params' }
    end

    if _mock and _mock.RegisterParticipant then
        return _mock.RegisterParticipant(contractId, src, citizenid, name)
    end

    if not GangContracts.IsReady() then return { ok = false, err = 'db_not_ready' } end
    local db = getDb()

    local row = db.single.await('SELECT id, participants, status FROM vp_chop_gang_contracts WHERE id = ?', { contractId })
    if not row or row.status ~= 'active' then
        return { ok = false, err = 'contract_not_active' }
    end

    local okP, parts = pcall(json.decode, row.participants)
    parts = (okP and type(parts) == 'table') and toArray(parts) or {}

    local exists = false
    for _, p in ipairs(parts) do
        if p.citizenid == citizenid then
            p.src = src -- atualiza a fonte de rede atual
            exists = true
            break
        end
    end

    if not exists then
        table.insert(parts, {
            src = src,
            citizenid = citizenid,
            name = name or ('Membro ' .. tostring(#parts + 1)),
            contribution = 0,
        })
    end

    db.update.await('UPDATE vp_chop_gang_contracts SET participants = ? WHERE id = ?', {
        json.encode(parts), contractId
    })

    return { ok = true }
end

--- Entrega e consome uma peça em cumprimento de um requisito do contrato
---@param contractId number
---@param src number
---@param deliveryData table { part_type: string, physicalSerial?: string, count?: number }
---@return table { ok: boolean, err?: string, fulfilled?: boolean, completed?: boolean }
function GangContracts.DeliverItem(contractId, src, deliveryData)
    contractId = tonumber(contractId)
    if not contractId or not src or type(deliveryData) ~= 'table' then
        return { ok = false, err = 'invalid_params' }
    end

    if ContractBusy[contractId] then
        return { ok = false, err = 'contract_busy' }
    end
    ContractBusy[contractId] = true

    local function release(res)
        ContractBusy[contractId] = nil
        return res
    end

    if _mock and _mock.DeliverItem then
        return release(_mock.DeliverItem(contractId, src, deliveryData))
    end

    if not GangContracts.IsReady() then
        return release({ ok = false, err = 'db_not_ready' })
    end

    local db = getDb()
    local row = db.single.await(
        'SELECT id, gang_id, contract_type, status, requirements, total_reward, participants, ' ..
        'UNIX_TIMESTAMP(expires_at) AS expires_at_ts FROM vp_chop_gang_contracts WHERE id = ?',
        { contractId }
    )

    if not row or row.status ~= 'active' then
        return release({ ok = false, err = 'contract_not_active' })
    end

    -- Validar expiração
    local now = getNow()
    if row.expires_at_ts and now >= tonumber(row.expires_at_ts) then
        db.update.await('UPDATE vp_chop_gang_contracts SET status = "expired" WHERE id = ?', { contractId })
        return release({ ok = false, err = 'contract_expired' })
    end

    -- Validar se o jogador pertence à gangue do contrato
    local G = rawget(_G, 'VPChopGangs')
    if G and G.GetPlayerGang then
        local playerGang = G.GetPlayerGang(src)
        if not playerGang or playerGang ~= row.gang_id then
            return release({ ok = false, err = 'not_gang_member' })
        end
    end

    local okReq, reqs = pcall(json.decode, row.requirements)
    local okPart, parts = pcall(json.decode, row.participants)
    reqs = (okReq and type(reqs) == 'table') and toArray(reqs) or {}
    parts = (okPart and type(parts) == 'table') and toArray(parts) or {}

    -- Localizar requisito correspondente
    local targetReq = nil
    for _, r in ipairs(reqs) do
        if r.part_type == deliveryData.part_type and r.delivered < r.required then
            targetReq = r
            break
        end
    end

    if not targetReq then
        return release({ ok = false, err = 'requirement_already_met_or_invalid' })
    end

    local countToDeliver = math.max(1, tonumber(deliveryData.count) or 1)
    local needed = targetReq.required - targetReq.delivered
    if countToDeliver > needed then
        countToDeliver = needed
    end

    local contribScore = countToDeliver * 10

    -- Se for peça física durável (P5.4)
    if deliveryData.physicalSerial and deliveryData.physicalSerial ~= '' then
        local PP = rawget(_G, 'PhysicalPart')
        if not PP or not PP.Get then
            return release({ ok = false, err = 'physical_part_bridge_missing' })
        end

        local physPart = PP.Get(deliveryData.physicalSerial)
        if not physPart then
            return release({ ok = false, err = 'physical_part_not_found' })
        end

        if physPart.partType ~= deliveryData.part_type then
            return release({ ok = false, err = 'physical_part_type_mismatch' })
        end

        if (physPart.conditionPct or 100) < (targetReq.min_condition or 0) then
            return release({ ok = false, err = 'insufficient_condition' })
        end

        -- Consumir a peça física
        local consumed = PP.Consume(deliveryData.physicalSerial, 'gang_contract_' .. tostring(contractId))
        if not consumed then
            return release({ ok = false, err = 'physical_part_consumption_failed' })
        end

        -- Bônus de contribuição para peças de alta qualidade
        contribScore = math.floor(contribScore * (physPart.conditionPct / 50.0))
    else
        -- Item de inventário padrão
        if exports and exports.ox_inventory and GetResourceState and GetResourceState('ox_inventory') == 'started' then
            local removed = exports.ox_inventory:RemoveItem(src, deliveryData.part_type, countToDeliver)
            if not removed then
                return release({ ok = false, err = 'inventory_item_missing' })
            end
        end
    end

    -- Atualiza entrega no requisito
    targetReq.delivered = targetReq.delivered + countToDeliver

    -- Atualiza contribuição do participante
    local foundParticipant = false
    for _, p in ipairs(parts) do
        if p.src == src then
            p.contribution = (p.contribution or 0) + contribScore
            foundParticipant = true
            break
        end
    end

    if not foundParticipant then
        table.insert(parts, {
            src = src,
            citizenid = tostring(src),
            name = 'Membro Squad',
            contribution = contribScore,
        })
    end

    -- Checa se todos os requisitos foram cumpridos
    local allFulfilled = true
    for _, r in ipairs(reqs) do
        if r.delivered < r.required then
            allFulfilled = false
            break
        end
    end

    db.update.await('UPDATE vp_chop_gang_contracts SET requirements = ?, participants = ? WHERE id = ?', {
        json.encode(reqs), json.encode(parts), contractId
    })

    if allFulfilled then
        local fulfillRes = GangContracts.FulfillContract(contractId)
        return release({
            ok = true,
            fulfilled = true,
            completed = fulfillRes.ok,
            payouts = fulfillRes.payouts,
        })
    end

    return release({
        ok = true,
        fulfilled = false,
        completed = false,
        delivered = targetReq.delivered,
        required  = targetReq.required,
    })
end

--- Liquida o contrato cooperativo com rateio server-authoritative e notificação para o esquadrão
---@param contractId number
---@return table { ok: boolean, err?: string, payouts?: table }
function GangContracts.FulfillContract(contractId)
    contractId = tonumber(contractId)
    if not contractId then return { ok = false, err = 'invalid_id' } end

    if _mock and _mock.FulfillContract then
        return _mock.FulfillContract(contractId)
    end

    if not GangContracts.IsReady() then return { ok = false, err = 'db_not_ready' } end
    local db = getDb()

    local row = db.single.await(
        'SELECT id, gang_id, contract_type, status, total_reward, participants FROM vp_chop_gang_contracts WHERE id = ?',
        { contractId }
    )

    if not row or row.status ~= 'active' then
        return { ok = false, err = 'contract_not_active' }
    end

    -- Transição atômica
    local affected = db.update.await(
        'UPDATE vp_chop_gang_contracts SET status = "completed", completed_at = NOW() WHERE id = ? AND status = "active"',
        { contractId }
    )

    if affected ~= 1 then
        return { ok = false, err = 'contract_already_fulfilled_or_race' }
    end

    local okP, parts = pcall(json.decode, row.participants)
    parts = (okP and type(parts) == 'table') and toArray(parts) or {}

    local totalReward = tonumber(row.total_reward) or 0
    local shares = GangContracts.DistributePayout(totalReward, parts)

    local PB = rawget(_G, 'PhoneBridge')

    for _, share in pairs(shares) do
        if share.amount > 0 and share.src and share.src > 0 then
            -- Credita dinheiro server-side via BridgeAddCash
            if type(BridgeAddCash) == 'function' then
                BridgeAddCash(share.src, share.amount, 'chopshop_gang_contract')
            end

            -- Dispara notificação no smartphone via PhoneBridge
            if PB and PB.IsAvailable and PB.IsAvailable() then
                local msg = ('Seu esquadrão concluiu o contrato da facção! Sua fatia do payout foi de $%d.'):format(share.amount)
                PB.SendNotification(share.src, 'Contrato da Facção', msg, {
                    icon = 'sack-dollar',
                    duration = 9000,
                })
            end
        end
    end

    return { ok = true, payouts = shares }
end

--- Seam para injeção de mock em testes
---@param mock table|nil
function GangContracts.__setMock(mock)
    _mock = mock
end

return GangContracts
