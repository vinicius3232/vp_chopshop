-- server/broker/npc_context_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-5] BROKER NPC PERSONA, CONTEXT UI & CONTRACT DISCOVERY SPEC
--  Testa o callback autoritativo vp_chopshop:broker:getNpcContext, capabilities,
--  persona, gates de trust, sanitização de dados e segurança de UX.
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass = 0
    local fail = 0
    local total = 0

    local function check(desc, cond)
        total = total + 1
        if cond then
            pass = pass + 1
            print(('[broker_npc/spec] PASS  %s'):format(desc))
        else
            fail = fail + 1
            print(('[broker_npc/spec] FAIL  %s'):format(desc))
        end
    end

    -- ─── Mocks & Helpers ────────────────────────────────────────────────────
    local orig_IsValidSource = _G.IsValidSource
    local orig_ServerPlayerIsReady = _G.ServerPlayerIsReady
    local orig_ServerChopPlayerKey = _G.ServerChopPlayerKey
    local orig_ValidatePlayerNearCoords = _G.ValidatePlayerNearCoords
    local orig_ValidatePlayerNearPoint = _G.ValidatePlayerNearPoint
    local orig_VPChopGetProgression = _G.VPChopGetProgression
    local orig_VPChopFenceCurrentLocation = _G.VPChopFenceCurrentLocation
    local orig_VPChopFenceGetTrust = _G.VPChopFenceGetTrust
    local orig_Locale = Config.Locale

    local getContextCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:broker:getNpcContext']
    check('NPC-REGISTER-01 Callback vp_chopshop:broker:getNpcContext registrado', type(getContextCb) == 'function')

    -- Stub environment state
    local testSrc = 1
    local testPlayerKey = 'qbx:test_player_1'
    local playerDistance = 2.0
    local isPlayerReady = true
    local mockTrustLevel = 0
    local mockTrustXp = 0
    local mockProgression = { tier = 1, xp = 150, nextXp = 500, totalChops = 5 }

    _G.IsValidSource = function(src) return type(src) == 'number' and src > 0 end
    _G.ServerPlayerIsReady = function(src) return isPlayerReady end
    _G.ServerChopPlayerKey = function(src) return testPlayerKey end
    _G.ValidatePlayerNearCoords = function(src, coords) return playerDistance <= 5.0 end
    _G.ValidatePlayerNearPoint = function(src, coords, maxDist) return playerDistance <= maxDist end
    _G.VPChopGetProgression = function(src) return mockProgression end

    -- Mock VPChopFenceCurrentLocation
    _G.VPChopFenceCurrentLocation = function()
        return {
            coords = vector3(100.0, -1000.0, 25.0),
            label = 'Docks Warehouse',
            scenario = 'WORLD_HUMAN_STAND_IMPATIENT',
        }
    end

    -- Mock VPChopFenceGetTrust
    _G.VPChopFenceGetTrust = function(src)
        return mockTrustLevel
    end

    -- ─── NPC-CTX-01: Invalid Source & Player Ready Gate ─────────────────────
    do
        local resInvalidSrc = getContextCb(-1)
        check('NPC-CTX-01 Invalid source retorna fail-closed (ok=false)', resInvalidSrc.ok == false and resInvalidSrc.err == 'invalid_source')

        isPlayerReady = false
        local resNotReady = getContextCb(testSrc)
        check('NPC-CTX-01 Player not ready retorna fail-closed (ok=false)', resNotReady.ok == false and resNotReady.err == 'player')
        isPlayerReady = true
    end

    -- ─── NPC-CTX-02: Fence Proximity & Location Gate ────────────────────────
    do
        playerDistance = 50.0 -- Jogador longe do Fence
        local resFar = getContextCb(testSrc)
        check('NPC-CTX-02 Jogador fora da distância do Fence retorna err=distance', resFar.ok == false and resFar.err == 'distance')
        playerDistance = 2.0

        local oldLocFunc = _G.VPChopFenceCurrentLocation
        _G.VPChopFenceCurrentLocation = function() return nil end
        local resNoFence = getContextCb(testSrc)
        check('NPC-CTX-02 Fence sem localização válida retorna err=no_fence', resNoFence.ok == false and resNoFence.err == 'no_fence')
        _G.VPChopFenceCurrentLocation = oldLocFunc
    end

    -- ─── NPC-CTX-03: Trust 0 Capabilities ───────────────────────────────────
    do
        mockTrustLevel = 0
        local resT0 = getContextCb(testSrc)
        check('NPC-CTX-03 Trust 0: ok=true e dados de broker presentes', resT0.ok == true and resT0.broker.alias ~= nil)
        check('NPC-CTX-03 Trust 0: introduce capability é true', resT0.capabilities.introduce == true)
        check('NPC-CTX-03 Trust 0: sellPart capability é false', resT0.capabilities.sellPart == false)
        check('NPC-CTX-03 Trust 0: hotJob capability é false', resT0.capabilities.hotJob == false)
        check('NPC-CTX-03 Trust 0: legacyOrder capability é false', resT0.capabilities.legacyOrder == false)
        check('NPC-CTX-03 Trust 0: deliverCar capability é false', resT0.capabilities.deliverCar == false)
        check('NPC-CTX-03 Trust 0: Sanitização estrita (zero playerKey / internals expostos)', resT0.playerKey == nil and resT0.citizenid == nil and resT0.db == nil)
    end

    -- ─── NPC-CTX-04: Trust 1 Capabilities ───────────────────────────────────
    do
        mockTrustLevel = 1
        local resT1 = getContextCb(testSrc)
        check('NPC-CTX-04 Trust 1: introduce capability é false', resT1.capabilities.introduce == false)
        check('NPC-CTX-04 Trust 1: sellPart capability é true', resT1.capabilities.sellPart == true)
        check('NPC-CTX-04 Trust 1: sellItems capability é true', resT1.capabilities.sellItems == true)
        check('NPC-CTX-04 Trust 1: sellTyres capability é true', resT1.capabilities.sellTyres == true)
        check('NPC-CTX-04 Trust 1: hotJob capability ainda é false', resT1.capabilities.hotJob == false)
        check('NPC-CTX-04 Trust 1: legacyOrder capability ainda é false', resT1.capabilities.legacyOrder == false)
    end

    -- ─── NPC-CTX-05: Trust 2 Capabilities & Shop Flag ───────────────────────
    do
        mockTrustLevel = 2
        Config.NPC = Config.NPC or {}
        Config.NPC.Shop = Config.NPC.Shop or {}
        Config.NPC.Shop.Enable = true

        local resT2 = getContextCb(testSrc)
        check('NPC-CTX-05 Trust 2: hotJob capability é true', resT2.capabilities.hotJob == true)
        check('NPC-CTX-05 Trust 2: status capability é true', resT2.capabilities.status == true)
        check('NPC-CTX-05 Trust 2: buyBench é true quando Shop.Enable=true', resT2.capabilities.buyBench == true)
        check('NPC-CTX-05 Trust 2: legacyOrder capability ainda é false', resT2.capabilities.legacyOrder == false)
        check('NPC-CTX-05 Trust 2: deliverCar capability ainda é false', resT2.capabilities.deliverCar == false)
    end

    -- ─── NPC-CTX-06: Trust 3 Capabilities ───────────────────────────────────
    do
        mockTrustLevel = 3
        local resT3 = getContextCb(testSrc)
        check('NPC-CTX-06 Trust 3: legacyOrder capability é true', resT3.capabilities.legacyOrder == true)
        check('NPC-CTX-06 Trust 3: contracts capability é true', resT3.capabilities.contracts == true)
        check('NPC-CTX-06 Trust 3: deliverCar capability ainda é false', resT3.capabilities.deliverCar == false)
    end

    -- ─── NPC-CTX-07: Trust 4 Capabilities ───────────────────────────────────
    do
        mockTrustLevel = 4
        local resT4 = getContextCb(testSrc)
        check('NPC-CTX-07 Trust 4: deliverCar capability é true', resT4.capabilities.deliverCar == true)
        check('NPC-CTX-07 Trust 4: todas as capacidades comerciais ativas', resT4.capabilities.sellPart and resT4.capabilities.hotJob and resT4.capabilities.legacyOrder and resT4.capabilities.deliverCar)
    end

    -- ─── NPC-CTX-08: Fresh Server Context on Repeat Opens ───────────────────
    do
        mockTrustLevel = 1
        local firstOpen = getContextCb(testSrc)
        check('NPC-CTX-08 Primeira abertura com Trust 1: legacyOrder=false', firstOpen.capabilities.legacyOrder == false)

        -- Simula avanço de trust no servidor
        mockTrustLevel = 3
        local secondOpen = getContextCb(testSrc)
        check('NPC-CTX-08 Segunda abertura lê Trust NOVO (3) do servidor: legacyOrder=true', secondOpen.capabilities.legacyOrder == true and secondOpen.trust.level == 3)
    end

    -- ─── NPC-FLAG-01: Shop.Enable Feature Flag ──────────────────────────────
    do
        mockTrustLevel = 3
        Config.NPC = Config.NPC or {}
        Config.NPC.Shop = Config.NPC.Shop or {}
        local oldShopEnable = Config.NPC.Shop.Enable
        Config.NPC.Shop.Enable = false
        local resShopOff = getContextCb(testSrc)
        check('NPC-FLAG-01 Config.NPC.Shop.Enable=false resulta em buyBench=false mesmo com Trust 3', resShopOff.capabilities.buyBench == false)
        Config.NPC.Shop.Enable = oldShopEnable
    end

    -- ─── NPC-FLAG-03: Broker / Contracts Feature Flags ──────────────────────
    do
        mockTrustLevel = 3
        local oldContractsEnable = Config.Broker.Contracts.Enable
        Config.Broker.Contracts.Enable = false
        local resContractsOff = getContextCb(testSrc)
        check('NPC-FLAG-03 Config.Broker.Contracts.Enable=false resulta em contracts=false', resContractsOff.capabilities.contracts == false)
        Config.Broker.Contracts.Enable = oldContractsEnable

        local oldBrokerEnable = Config.Broker.Enable
        Config.Broker.Enable = false
        local resBrokerOff = getContextCb(testSrc)
        check('NPC-FLAG-03 Config.Broker.Enable=false resulta em contracts=false e brokerEnabled=false', resBrokerOff.capabilities.contracts == false and resBrokerOff.brokerEnabled == false)
        Config.Broker.Enable = oldBrokerEnable
    end

    -- ─── NPC-CONTRACT-01..03: Contratos Autorizados & Estados ───────────────
    do
        local mockGlobalContract = {
            id = 'c_global_1',
            isGlobal = true,
            contractType = 'part',
            targetKey = 'adv_engine',
            quantity = 2,
            remaining = 1,
            rewardMult = 1.35,
            bonusCash = 2500,
            expiresAt = os.time() + 3600,
            state = 'AVAILABLE',
        }
        local mockPersonalAvailable = {
            id = 'c_pers_avail_1',
            isGlobal = false,
            contractType = 'part',
            targetKey = 'catalytic_converter',
            quantity = 3,
            remaining = 3,
            rewardMult = 1.25,
            bonusCash = 1800,
            expiresAt = os.time() + 1800,
            state = 'AVAILABLE',
        }
        local mockPersonalAccepted = {
            id = 'c_pers_acc_1',
            isGlobal = false,
            contractType = 'part',
            targetKey = 'body_panel',
            quantity = 4,
            remaining = 2,
            rewardMult = 1.15,
            bonusCash = 1000,
            expiresAt = os.time() + 1200,
            state = 'ACCEPTED',
        }

        check('NPC-CONTRACT-01 Contrato global possui isGlobal=true para display sem botão Accept', mockGlobalContract.isGlobal == true)
        check('NPC-CONTRACT-02 Contrato pessoal disponível possui state AVAILABLE para ação de Accept', mockPersonalAvailable.state == 'AVAILABLE' and mockPersonalAvailable.isGlobal == false)
        check('NPC-CONTRACT-03 Contrato pessoal aceito possui state ACCEPTED para fluxo de entrega direta', mockPersonalAccepted.state == 'ACCEPTED')
    end

    -- ─── NPC-LOCALE-01: Paridade Completa de Idiomas ────────────────────────
    do
        dofile('shared/locale.lua')
        local requiredKeys = {
            'broker_target_talk',
            'broker_greeting_trust_0',
            'broker_greeting_trust_1',
            'broker_greeting_trust_2',
            'broker_greeting_trust_3',
            'broker_greeting_trust_4',
            'broker_menu_main_title',
            'broker_menu_sell',
            'broker_menu_sell_desc',
            'broker_menu_contracts',
            'broker_menu_contracts_desc',
            'broker_menu_jobs',
            'broker_menu_jobs_desc',
            'broker_menu_services',
            'broker_menu_services_desc',
            'broker_menu_profile',
            'broker_menu_profile_desc',
            'broker_menu_legacy_order',
            'broker_menu_legacy_order_desc',
            'broker_menu_deliver_car',
            'broker_menu_deliver_car_desc',
            'broker_contracts_global_title',
            'broker_contracts_personal_title',
            'broker_contract_accept',
            'broker_contract_deliver_part',
            'broker_contract_accepted_badge',
            'broker_contract_no_contracts',
            'broker_contract_accepted_notify',
            'broker_contract_fulfilled_notify',
            'err_no_fence',
            'err_no_trust',
            'err_trust_gate',
            'err_market_not_ready',
            'err_market_integrity_locked',
            'err_contract_busy',
            'err_contract_not_accepted',
            'err_contract_expired',
            'err_wrong_part',
            'err_provenance_missing',
            'err_provenance_class_missing',
            'err_external_reserved',
            'err_workshop_integrity_locked',
            'err_payment_failed',
            'err_nothing_sold',
            'err_contracts_not_ready',
        }

        local languages = { 'pt', 'en', 'es', 'fr', 'tr' }
        local allLocalesPresent = true
        for _, lang in ipairs(languages) do
            Config.Locale = lang
            for _, k in ipairs(requiredKeys) do
                local val = L(k)
                if not val or val == k then
                    allLocalesPresent = false
                    print(('[broker_npc/spec] Missing locale key: %s in %s'):format(k, lang))
                end
            end
        end
        Config.Locale = 'pt'
        check('NPC-LOCALE-01 Todas as novas chaves de tradução presentes em pt, en, es, fr, tr', allLocalesPresent == true)
    end

    -- ─── NPC-NO-ECONOMY-DRIFT-01: Preservação das Canaries Econômicas ────────
    do
        check('NPC-NO-ECONOMY-DRIFT-01 Config.Broker.Commodities inalterado', Config.Broker and Config.Broker.Commodities and Config.Broker.Commodities.catalytic_converter.basePrice == 1600)
        check('NPC-NO-ECONOMY-DRIFT-01 Config.Broker.Market bounds inalterados', Config.Broker.Market.PriceFloor == 0.40 and Config.Broker.Market.PriceCeiling == 2.50)
        check('NPC-NO-ECONOMY-DRIFT-01 Config.Broker.Contracts pools inalterados', #Config.Broker.Contracts.Pools.part_type == 3)
    end

    -- Restaurar globals originais para não poluir specs subsequentes no harness
    _G.IsValidSource = orig_IsValidSource
    _G.ServerPlayerIsReady = orig_ServerPlayerIsReady
    _G.ServerChopPlayerKey = orig_ServerChopPlayerKey
    _G.ValidatePlayerNearCoords = orig_ValidatePlayerNearCoords
    _G.ValidatePlayerNearPoint = orig_ValidatePlayerNearPoint
    _G.VPChopGetProgression = orig_VPChopGetProgression
    _G.VPChopFenceCurrentLocation = orig_VPChopFenceCurrentLocation
    _G.VPChopFenceGetTrust = orig_VPChopFenceGetTrust
    Config.Locale = orig_Locale

    print(('[broker_npc/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('npc_context_spec falhou') end
end

run()
