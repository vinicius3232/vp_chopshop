-- server/broker/gang_contracts_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.20 P6.4] GANG CONTRACTS SPEC SUITE
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[gang_contracts/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[gang_contracts/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local GC = dofile('server/broker/gang_contracts.lua')

    -- ─── 1. Payout Split Math (Server-Authoritative) ─────────────────────────────
    local pList = {
        { src = 1, citizenid = 'CID_1', contribution = 75 },
        { src = 2, citizenid = 'CID_2', contribution = 25 },
    }
    local shares = GC.DistributePayout(10000, pList)
    check('GC-SPLIT-01 Proportional split calculates correct shares', shares['CID_1'].amount == 7500 and shares['CID_2'].amount == 2500)

    -- Divisão com dízima periódica (ex: $10.000 para 3 membros)
    local pList3 = {
        { src = 1, citizenid = 'CID_1', contribution = 10 },
        { src = 2, citizenid = 'CID_2', contribution = 10 },
        { src = 3, citizenid = 'CID_3', contribution = 10 },
    }
    local shares3 = GC.DistributePayout(10000, pList3)
    local totalSplit = shares3['CID_1'].amount + shares3['CID_2'].amount + shares3['CID_3'].amount
    check('GC-SPLIT-02 Remainder preservation guarantees 100% exact sum', totalSplit == 10000)

    -- Divisão sem contribuição (igualitária)
    local pListZero = {
        { src = 1, citizenid = 'CID_A', contribution = 0 },
        { src = 2, citizenid = 'CID_B', contribution = 0 },
    }
    local sharesZero = GC.DistributePayout(5000, pListZero)
    check('GC-SPLIT-03 Zero contribution yields equal split', sharesZero['CID_A'].amount == 2500 and sharesZero['CID_B'].amount == 2500)

    -- ─── 2. Mock DB & Invariant Lifecycle ───────────────────────────────────────
    local mockStorage = {}
    local nextId = 1
    local mockDb = {
        insert = {
            await = function(query, params)
                local id = nextId
                nextId = nextId + 1
                mockStorage[id] = {
                    id = id,
                    gang_id = params[1],
                    contract_type = params[2],
                    status = 'active',
                    requirements = params[3],
                    total_reward = params[4],
                    participants = params[5],
                    expires_at_ts = params[6],
                    created_at_ts = 1000,
                }
                return id
            end
        },
        single = {
            await = function(query, params)
                local id = params[1]
                if type(id) == 'string' and query:find('gang_id = ?') then
                    for _, row in pairs(mockStorage) do
                        if row.gang_id == id and row.status == 'active' then
                            return row
                        end
                    end
                    return nil
                end
                return mockStorage[id]
            end
        },
        update = {
            await = function(query, params)
                if query:find('SET status = "completed"') then
                    local id = params[1]
                    if mockStorage[id] and mockStorage[id].status == 'active' then
                        mockStorage[id].status = 'completed'
                        return 1
                    end
                    return 0
                elseif query:find('SET requirements =') then
                    local id = params[3]
                    if mockStorage[id] then
                        mockStorage[id].requirements = params[1]
                        mockStorage[id].participants = params[2]
                        return 1
                    end
                elseif query:find('SET participants =') then
                    local id = params[2]
                    if mockStorage[id] then
                        mockStorage[id].participants = params[1]
                        return 1
                    end
                end
                return 0
            end
        },
        query = {
            await = function() return {} end
        }
    }

    GC.Init(mockDb, function() return 1000 end)
    check('GC-INIT-01 GangContracts is initialized and ready', GC.IsReady() == true)

    -- Criar contrato cooperativo
    local cRes = GC.CreateContract('ballas', 'convoy_heist', {
        { part_type = 'adv_engine', required = 2, min_condition = 80 },
        { part_type = 'catalytic_converter', required = 1 },
    }, 25000, 3600)
    check('GC-CREATE-01 CreateContract succeeds', cRes.ok == true and cRes.contractId ~= nil)

    local activeC = GC.GetActiveContract('ballas')
    check('GC-GET-01 GetActiveContract retrieves active contract', activeC ~= nil and activeC.gangId == 'ballas' and #activeC.requirements == 2)

    -- Registrar participantes
    GC.RegisterParticipant(cRes.contractId, 5, 'BALLA_01', 'Carl')
    GC.RegisterParticipant(cRes.contractId, 6, 'BALLA_02', 'Sweet')

    local updatedC = GC.GetActiveContract('ballas')
    check('GC-PART-01 Squad participants registered', #updatedC.participants == 2)

    -- ─── 3. Delivery & Physical Part Validation ──────────────────────────────────
    -- Mock de gangue para checagem de membro
    _G.VPChopGangs = {
        GetPlayerGang = function(src)
            if src == 5 or src == 6 then return 'ballas' end
            return 'vagos'
        end
    }

    -- Tentar entregar com membro rival (vagos em contrato ballas)
    local rivalDeliv = GC.DeliverItem(cRes.contractId, 99, { part_type = 'adv_engine' })
    check('GC-DELIV-01 Rejects delivery from rival gang member', rivalDeliv.ok == false and rivalDeliv.err == 'not_gang_member')

    -- Mock de Peça Física Durável (P5.4)
    local physicalStorage = {
        ['ENG-SERIAL-01'] = { partId = 'ENG-SERIAL-01', partType = 'adv_engine', conditionPct = 85.0 },
        ['ENG-SERIAL-LOW'] = { partId = 'ENG-SERIAL-LOW', partType = 'adv_engine', conditionPct = 50.0 },
    }
    local consumedSerials = {}
    _G.PhysicalPart = {
        Get = function(serial) return physicalStorage[serial] end,
        Consume = function(serial, reason)
            consumedSerials[serial] = reason
            return true
        end
    }

    -- Tentar entregar peça física com condição insuficiente (< 80)
    local lowCondDeliv = GC.DeliverItem(cRes.contractId, 5, {
        part_type = 'adv_engine',
        physicalSerial = 'ENG-SERIAL-LOW'
    })
    check('GC-DELIV-02 Rejects physical part with low condition', lowCondDeliv.ok == false and lowCondDeliv.err == 'insufficient_condition')

    -- Entregar primeira peça válida
    local okDeliv1 = GC.DeliverItem(cRes.contractId, 5, {
        part_type = 'adv_engine',
        physicalSerial = 'ENG-SERIAL-01'
    })
    check('GC-DELIV-03 Valid physical part delivered and consumed', okDeliv1.ok == true and consumedSerials['ENG-SERIAL-01'] ~= nil)

    -- Entregar segunda peça válida (completando o requisito 1)
    physicalStorage['ENG-SERIAL-02'] = { partId = 'ENG-SERIAL-02', partType = 'adv_engine', conditionPct = 90.0 }
    local okDeliv2 = GC.DeliverItem(cRes.contractId, 6, {
        part_type = 'adv_engine',
        physicalSerial = 'ENG-SERIAL-02'
    })
    check('GC-DELIV-04 Second engine delivered', okDeliv2.ok == true and okDeliv2.delivered == 2)

    -- ─── 4. Fulfillment & Smartphone Notification ────────────────────────────────
    local phoneNotifs = {}
    _G.PhoneBridge = {
        IsAvailable = function() return true end,
        SendNotification = function(src, title, msg, opts)
            table.insert(phoneNotifs, { src = src, title = title, msg = msg })
            return true
        end
    }

    local cashPaid = {}
    _G.BridgeAddCash = function(src, amount, reason)
        cashPaid[src] = (cashPaid[src] or 0) + amount
        return true
    end

    local origVPChopGangs = _G.VPChopGangs
    local origPhysicalPart = _G.PhysicalPart
    local origPhoneBridge = _G.PhoneBridge
    local origBridgeAddCash = _G.BridgeAddCash
    local origGetResourceState = _G.GetResourceState
    local origFakeOx = _G.FAKE_EXPORTS and _G.FAKE_EXPORTS['ox_inventory']

    -- Entregar último item (catalytic converter via inventário ox_inventory)
    _G.FAKE_EXPORTS = _G.FAKE_EXPORTS or {}
    _G.FAKE_EXPORTS['ox_inventory'] = {
        RemoveItem = function(self, src, item, count) return true end,
        GetItemCount = function(self, src, item) return 1 end,
    }

    _G.GetResourceState = function(res)
        if res == 'ox_inventory' then return 'started' end
        if origGetResourceState then return origGetResourceState(res) end
        return 'missing'
    end

    local finalDeliv = GC.DeliverItem(cRes.contractId, 5, {
        part_type = 'catalytic_converter',
        count = 1
    })
    check('GC-FULFILL-01 Contract automatically completes upon final delivery', finalDeliv.ok == true and finalDeliv.fulfilled == true and finalDeliv.completed == true)
    check('GC-PAYOUT-01 Cash distributed server-authoritatively to participants', cashPaid[5] ~= nil and cashPaid[6] ~= nil and (cashPaid[5] + cashPaid[6]) == 25000)
    check('GC-PHONE-01 Smartphone notifications sent to all participants', #phoneNotifs == 2)

    -- Teardown: restaurar ambiente global
    _G.VPChopGangs = origVPChopGangs
    _G.PhysicalPart = origPhysicalPart
    _G.PhoneBridge = origPhoneBridge
    _G.BridgeAddCash = origBridgeAddCash
    _G.GetResourceState = origGetResourceState
    if _G.FAKE_EXPORTS then
        _G.FAKE_EXPORTS['ox_inventory'] = origFakeOx
    end

    print(('─── RESUMO GANG CONTRACTS: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('gang_contracts_spec failed: %d assertions failed'):format(fail))
end

run()
