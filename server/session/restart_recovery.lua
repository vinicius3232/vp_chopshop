-- server/session/restart_recovery.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.19 P5.5] SELECTIVE RESTART RECOVERY & BOOT RECONCILER
--  Reconciliação atômica no boot:
--    1) Carcaças abandonadas no mundo (CarcassLedger);
--    2) Transações financeiras SAGA pendentes (WorkshopBridge Journal);
--    3) Estorno de garantias de ordens B2B expiradas (B2BOrders);
--    4) Restauração e sanitização de peças físicas duráveis na bancada (PhysicalPart).
-- ═══════════════════════════════════════════════════════════════════════════════

RestartRecovery = {}

local _db = nil
local _clock = os.time
local _mock = nil

local function getNow()
    return _clock and _clock() or os.time()
end

local function getDb()
    if _db then return _db end
    return _G.MySQL
end

function RestartRecovery.Init(db, clockFn)
    if db ~= nil then _db = db end
    if clockFn ~= nil then _clock = clockFn end
end

--- Varredura de carcaças residuais no mundo
---@return { deleted: number, stuck: number, orphan: number, unmatched: number }
function RestartRecovery.SweepCarcasses()
    local res = { deleted = 0, stuck = 0, orphan = 0, unmatched = 0 }
    if not (VPChopCarcassLedger and VPChopCarcassLedger.ready()) then return res end

    local cfg = Config.RestartRecovery or {}
    local rows = VPChopCarcassLedger.loadPending()
    if #rows == 0 then return res end

    local nm = VPChopCarcassLedger.normModel
    for _, row in ipairs(rows) do
        local netId = math.floor(tonumber(row.net_id) or 0)
        local model = nm(row.model)
        local exists = netId ~= 0 and (not NetworkDoesEntityExistWithNetworkId or NetworkDoesEntityExistWithNetworkId(netId))
        local v = exists and NetworkGetEntityFromNetworkId(netId) or 0
        local alive = v ~= 0 and DoesEntityExist(v) and nm(GetEntityModel(v)) == model

        if not alive then
            VPChopCarcassLedger.clear(netId, model)
            res.orphan = res.orphan + 1
        else
            local okv, liveVsid = pcall(function() return Entity(v).state.vpChopVsid end)
            local match = row.vsid ~= nil and row.vsid ~= '' and okv and liveVsid == row.vsid

            if not match then
                res.unmatched = res.unmatched + 1
            elseif cfg.BootSweepDelete == false then
                res.stuck = res.stuck + 1
            elseif BridgeDeleteWorldVehicle then
                local d = BridgeDeleteWorldVehicle(v, {})
                if not d.existsAfter then
                    VPChopCarcassLedger.clear(netId, model)
                    res.deleted = res.deleted + 1
                else
                    res.stuck = res.stuck + 1
                end
            end
        end
    end
    return res
end

--- Reconcilia transações SAGA pendentes que ficaram órfãs no restart
---@param now? number
---@return number reconciledCount
function RestartRecovery.SweepSagaTransactions(now)
    local curTime = now or getNow()
    if _mock and _mock.SweepSagaTransactions then
        return _mock.SweepSagaTransactions(curTime)
    end

    if WorkshopBridge and type(WorkshopBridge.ReconcilePending) == 'function' then
        local count = WorkshopBridge.ReconcilePending(curTime)
        return tonumber(count) or 0
    end

    return 0
end

--- Estorna fundos de ordens B2B que expiraram durante o período de servidor offline
---@param now? number
---@return number expiredOrdersCount
function RestartRecovery.SweepB2BOrders(now)
    local curTime = now or getNow()
    if _mock and _mock.SweepB2BOrders then
        return _mock.SweepB2BOrders(curTime)
    end

    if B2BOrders and type(B2BOrders.SweepExpired) == 'function' then
        return B2BOrders.SweepExpired(curTime)
    end

    return 0
end

--- Restaura peças salvas sobre bancadas e limpa referências a bancadas inexistentes
---@return { restored: number, orphaned: number }
function RestartRecovery.SweepBenchParts()
    local res = { restored = 0, orphaned = 0 }
    if not (PhysicalPart and PhysicalPart.LoadBenchParts) then return res end

    local parts = PhysicalPart.LoadBenchParts()
    for _, sp in ipairs(parts) do
        local benchId = tonumber(sp.benchId)
        if benchId then
            -- Verificar se a bancada ainda existe
            local benchValid = false
            if _G.benchById then
                benchValid = (_G.benchById(benchId) ~= nil)
            elseif _G.VPChopDbLoadBenches then
                local allBenches = _G.VPChopDbLoadBenches()
                for _, b in ipairs(allBenches or {}) do
                    if tonumber(b.id) == benchId then benchValid = true; break end
                end
            else
                benchValid = true
            end

            if benchValid then
                res.restored = res.restored + 1
            else
                -- Bancada foi deletada offline; desvincular para não prender a peça
                if PhysicalPart.TakeFromBench then
                    PhysicalPart.TakeFromBench(benchId)
                end
                res.orphaned = res.orphaned + 1
            end
        end
    end
    return res
end

--- Executa a reconciliação completa de boot
---@param now? number
---@return table summary
function RestartRecovery.RunAll(now)
    local curTime = now or getNow()
    local carcasses = RestartRecovery.SweepCarcasses()
    local sagaCount = RestartRecovery.SweepSagaTransactions(curTime)
    local b2bCount = RestartRecovery.SweepB2BOrders(curTime)
    local benchParts = RestartRecovery.SweepBenchParts()

    local summary = {
        carcasses = carcasses,
        sagaReconciled = sagaCount,
        b2bExpired = b2bCount,
        benchParts = benchParts,
        timestamp = curTime,
    }

    print(('[vp_chopshop][restart-recovery] RECOVERY COMPLETO: SAGA=%d · B2B_Refunds=%d · BenchRestored=%d · CarcassesDeleted=%d')
        :format(sagaCount, b2bCount, benchParts.restored, carcasses.deleted))

    return summary
end

function RestartRecovery.__setMock(mock)
    _mock = mock
end

-- ─── Evento de Inicialização ──────────────────────────────────────────────────

AddEventHandler('vp_chopshop:server:dbReady', function()
    local cfg = Config.RestartRecovery or {}
    if cfg.Enable == false then return end

    CreateThread(function()
        local delay = math.floor(tonumber(cfg.BootSweepDelayMs) or 5000)
        if delay > 0 then Wait(delay) end
        RestartRecovery.RunAll()
    end)
end)

return RestartRecovery
