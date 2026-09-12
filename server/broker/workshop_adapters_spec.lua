-- server/broker/workshop_adapters_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.19 P5.1 / P5.2] WORKSHOP ADAPTERS SPEC SUITE
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[adapters/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[adapters/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local WB = WorkshopBridge
    local QBX = dofile('bridge/workshop_qbx.lua')
    local Comm = dofile('bridge/workshop_community.lua')

    -- ─── 1. Provider Registration in WorkshopBridge ─────────────────────────────
    check('ADAPTER-REG-01 qbx_mechanics registered in WorkshopBridge', WB.GetProvider('qbx_mechanics') ~= nil)
    check('ADAPTER-REG-02 qs-mechanics registered in WorkshopBridge', WB.GetProvider('qs-mechanics') ~= nil)
    check('ADAPTER-REG-03 renzu_customs registered in WorkshopBridge', WB.GetProvider('renzu_customs') ~= nil)
    check('ADAPTER-REG-04 none provider registered in WorkshopBridge', WB.GetProvider('none') ~= nil)

    -- ─── 2. QBX Mechanics Adapter Lifecycle ────────────────────────────────────
    -- A. Availability
    QBX.__setMock({
        GetResourceState = function(r) return (r == 'qbx_mechanics') and 'started' or 'missing' end,
        GetSocietyBalance = function(acc) return 20000 end,
        RemoveSocietyMoney = function(acc, amt) return true end,
        DepositPartToStash = function(stash, part, cnt, meta) return true end,
    })
    check('QBX-AVAIL-01 IsAvailable true when qbx_mechanics started', QBX.IsAvailable() == true)

    QBX.__setMock({
        GetResourceState = function(r) return 'missing' end,
    })
    check('QBX-AVAIL-02 IsAvailable false when qbx_mechanics missing', QBX.IsAvailable() == false)

    -- B. PreparePurchase with Sufficient Balance
    local societyBalance = 15000
    local debitCalls = 0
    local stashDeposits = 0
    QBX.__setMock({
        IsAvailable = function() return true end,
        GetSocietyBalance = function(acc) return societyBalance end,
        RemoveSocietyMoney = function(acc, amt)
            if amt <= societyBalance then
                societyBalance = societyBalance - amt
                debitCalls = debitCalls + 1
                return true
            end
            return false
        end,
        DepositPartToStash = function(stash, part, cnt, meta)
            stashDeposits = stashDeposits + 1
            return true
        end,
    })

    local txn1 = 'ws:qbx_mechanics:test:1001:1'
    local ctx1 = {
        workshopId = 'bennys',
        partKey = 'adv_engine',
        commodity = 'adv_engine',
        price = 5000,
        metadata = { sourceNetId = 12 },
    }

    local prepRes = QBX.PreparePurchase(txn1, ctx1)
    check('QBX-PREP-01 PreparePurchase ok with sufficient funds', prepRes.ok == true)
    check('QBX-PREP-02 Agreed price matches request', prepRes.price == 5000)
    check('QBX-PREP-03 Status is PREPARED', QBX.GetTransactionStatus(txn1) == 'PREPARED')

    -- C. CommitPurchase & Idempotency
    local commitRes1 = QBX.CommitPurchase(txn1)
    check('QBX-COMMIT-01 CommitPurchase returns ok and paid', commitRes1.ok == true and commitRes1.paid == true)
    check('QBX-COMMIT-02 Society balance debited', societyBalance == 10000 and debitCalls == 1)
    check('QBX-COMMIT-03 Part deposited into stash', stashDeposits == 1)
    check('QBX-COMMIT-04 Status is COMMITTED', QBX.GetTransactionStatus(txn1) == 'COMMITTED')

    -- Idempotency check: 2nd commit with same txnId must NOT debit again
    local commitRes2 = QBX.CommitPurchase(txn1)
    check('QBX-COMMIT-05 Second commit is idempotent', commitRes2.ok == true and commitRes2.paid == true)
    check('QBX-COMMIT-06 Balance not debited twice', societyBalance == 10000 and debitCalls == 1)

    -- Cannot abort already committed transaction
    local abortCommitted = QBX.AbortPurchase(txn1, 'test_abort')
    check('QBX-ABORT-01 Cannot abort committed transaction', abortCommitted == false)

    -- D. Insufficient Balance
    local txn2 = 'ws:qbx_mechanics:test:1002:2'
    local ctx2 = {
        workshopId = 'bennys',
        partKey = 'adv_engine',
        price = 25000, -- exceeds 10000 balance
    }
    local prepFail = QBX.PreparePurchase(txn2, ctx2)
    check('QBX-PREP-04 PreparePurchase fails on insufficient funds', prepFail.ok == false and prepFail.err == 'insufficient_society_funds')

    -- E. AbortPurchase
    local txn3 = 'ws:qbx_mechanics:test:1003:3'
    local ctx3 = { workshopId = 'bennys', partKey = 'door', price = 2000 }
    local prep3 = QBX.PreparePurchase(txn3, ctx3)
    check('QBX-PREP-05 Txn3 prepared', prep3.ok == true)
    check('QBX-PREP-06 Status is PREPARED', QBX.GetTransactionStatus(txn3) == 'PREPARED')

    local abort3 = QBX.AbortPurchase(txn3, 'customer_cancelled')
    check('QBX-ABORT-02 Abort returns true for prepared transaction', abort3 == true)
    check('QBX-ABORT-03 Status is ABORTED', QBX.GetTransactionStatus(txn3) == 'ABORTED')

    local commitAborted = QBX.CommitPurchase(txn3)
    check('QBX-COMMIT-07 Cannot commit aborted transaction', commitAborted.ok == false)

    -- ─── 3. QS-Mechanic Adapter Lifecycle ──────────────────────────────────────
    local QS = Comm.QSMechanic
    Comm.__setMock('qs-mechanics', {
        IsAvailable = function() return true end,
        GetBalance = function() return 8000 end,
        Commit = function(txn, price, part) return true end,
    })

    check('QS-AVAIL-01 IsAvailable true when started', QS.IsAvailable() == true)
    local txnQs = 'ws:qs-mechanics:test:2001:1'
    local prepQs = QS.PreparePurchase(txnQs, { partKey = 'wheel_lf', price = 2500 })
    check('QS-PREP-01 PreparePurchase ok', prepQs.ok == true and prepQs.price == 2500)
    check('QS-STATUS-01 Status PREPARED', QS.GetTransactionStatus(txnQs) == 'PREPARED')

    local commitQs = QS.CommitPurchase(txnQs)
    check('QS-COMMIT-01 CommitPurchase ok', commitQs.ok == true and commitQs.paid == true)
    check('QS-STATUS-02 Status COMMITTED', QS.GetTransactionStatus(txnQs) == 'COMMITTED')

    -- Idempotent second commit
    local commitQs2 = QS.CommitPurchase(txnQs)
    check('QS-COMMIT-02 Second commit idempotent', commitQs2.ok == true)

    -- ─── 4. Renzu Customs Adapter Lifecycle ────────────────────────────────────
    local Renzu = Comm.Renzu
    Comm.__setMock('renzu_customs', {
        IsAvailable = function() return true end,
        GetBalance = function() return 12000 end,
        Commit = function(txn, price, part) return true end,
    })

    check('RENZU-AVAIL-01 IsAvailable true when started', Renzu.IsAvailable() == true)
    local txnRz = 'ws:renzu_customs:test:3001:1'
    local prepRz = Renzu.PreparePurchase(txnRz, { partKey = 'catalytic_converter', price = 4200 })
    check('RENZU-PREP-01 PreparePurchase ok', prepRz.ok == true and prepRz.price == 4200)
    check('RENZU-STATUS-01 Status PREPARED', Renzu.GetTransactionStatus(txnRz) == 'PREPARED')

    local commitRz = Renzu.CommitPurchase(txnRz)
    check('RENZU-COMMIT-01 CommitPurchase ok', commitRz.ok == true and commitRz.paid == true)
    check('RENZU-STATUS-02 Status COMMITTED', Renzu.GetTransactionStatus(txnRz) == 'COMMITTED')

    -- Cleanup mocks
    QBX.__setMock(nil)
    Comm.__setMock('qs-mechanics', nil)
    Comm.__setMock('renzu_customs', nil)

    print(('─── RESUMO WORKSHOP ADAPTERS: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('workshop_adapters_spec failed: %d assertions failed'):format(fail))
end

run()
