-- bridge/phone_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.20 P6.3] PhoneBridge Spec Suite
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass, fail, total = 0, 0, 0
    local function check(name, ok, msg)
        total = total + 1
        if ok then
            pass = pass + 1
            print(('[phone/spec] PASS  %s'):format(name))
        else
            fail = fail + 1
            print(('[phone/spec] FAIL  %s: %s'):format(name, msg or 'assertion failed'))
        end
    end

    local PB = dofile('bridge/phone.lua')

    -- ─── 1. Provider Resolution & Fail-soft ──────────────────────────────────────
    PB.__setMock({ provider = 'none' })
    check('PHONE-PROV-01 Provider "none" returns IsAvailable == false', PB.IsAvailable() == false)
    check('PHONE-PROV-02 Provider "none" rejects notification safely', PB.SendNotification(1, 'Title', 'Msg') == false)

    -- ─── 2. Mock Provider Dispatch ──────────────────────────────────────────────
    local notifications = {}
    PB.__setMock({
        provider = 'lb-phone',
        SendNotification = function(src, title, message, opts)
            if src <= 0 then return false, 'invalid_source' end
            table.insert(notifications, { src = src, title = title, message = message, opts = opts })
            return true
        end
    })
    check('PHONE-MOCK-01 IsAvailable true for active provider', PB.IsAvailable() == true)

    local okSend, errSend = PB.SendNotification(12, 'Informante', 'Carro sendo desmanchado no beco!')
    check('PHONE-SEND-01 SendNotification succeeds for valid player', okSend == true and #notifications == 1)
    check('PHONE-SEND-02 Delivered content matches', notifications[1].src == 12 and notifications[1].message == 'Carro sendo desmanchado no beco!')

    -- ─── 3. Multi-player Notification Batch ─────────────────────────────────────
    local sentBatch = PB.SendNotificationToPlayers({ 10, 11, 12 }, 'Alerta Turf', 'Intrusos na área!')
    check('PHONE-BATCH-01 Batch notification delivers to all members', sentBatch == 3 and #notifications == 4)

    -- ─── 4. Custom Handler Registration ─────────────────────────────────────────
    PB.__setMock(nil)
    local customDelivered = false
    PB.RegisterCustomHandler(function(src, title, message, opts)
        if src == 99 then customDelivered = true end
    end)
    PB.__setMock({ provider = 'custom' })
    PB.SendNotification(99, 'Custom Title', 'Custom Message')
    check('PHONE-CUSTOM-01 Custom registered handler executes successfully', customDelivered == true)

    PB.__setMock(nil)

    print(('─── RESUMO PHONE BRIDGE: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    assert(fail == 0, ('phone_spec failed: %d assertions failed'):format(fail))
end

run()
